import Foundation
import WhisperKit

private actor WhisperDecoder {
    private var pipe: WhisperKit?
    private var vocabulary = ""
    private var previousFinal = ""
    func setVocabulary(_ text: String) { vocabulary = CourseVocabulary.normalize(text); previousFinal = "" }
    func remember(_ text: String) { previousFinal = String(text.suffix(500)) }
    func prepare(model: WhisperModel) async throws {
        pipe = try await WhisperKit(WhisperKitConfig(model: model.rawValue, verbose: false, prewarm: true, load: true))
        try Task.checkCancellation()
    }
    func decode(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw GlacierCoreError.message("Whisper model is not ready.") }
        // Token conditioning helps recognize course terms without sending audio away.
        let recent = Array((pipe.tokenizer?.encode(text: previousFinal) ?? []).suffix(48))
        let terms = Array((pipe.tokenizer?.encode(text: vocabulary) ?? []).prefix(48))
        let options = DecodingOptions(language: "en", temperatureFallbackCount: 1, skipSpecialTokens: true,
                                     withoutTimestamps: true, promptTokens: recent.isEmpty && terms.isEmpty ? nil : recent + terms, suppressBlank: true)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor public final class WhisperTranscriber: StreamingTranscriber {
    private let model: WhisperModel
    private let vocabulary: String
    private let decoder = WhisperDecoder()
    private let microphone = Microphone()
    private var task: Task<Void, Never>?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var generation = UUID()
    private var failure: Error?
    public init(model: WhisperModel = .base, vocabulary: String = "") { self.model = model; self.vocabulary = vocabulary }
    public func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        stop()
        failure = nil
        let token = generation
        status("Preparing \(model.title). First use downloads the model; later runs use its cache.")
        await decoder.setVocabulary(vocabulary)
        try await decoder.prepare(model: model)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let audio = try await microphone.start()
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output = continuation
        task = Task { [weak self, decoder] in
            do {
                try await WhisperStreamProcessor.run(audio: audio, decode: { try await decoder.decode($0) }, completed: { await decoder.remember($0) }) { event in
                    if case .dropped = continuation.yield(event) { throw GlacierCoreError.message("Caption consumer cannot keep up.") }
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish() }
            catch {
                let error = GlacierCoreError.message("Whisper transcription stopped before finalization. Check the model/network or try Base; available transcript is saved.")
                if self?.generation == token { self?.failure = error }
                continuation.finish(throwing: error)
            }
            if self?.generation == token { self?.microphone.stop() }
        }
        status("WhisperKit ready · audio stays on this device")
        return stream
    }
    public func finish() async throws {
        // Finish the microphone stream without cancelling its queued frames or decode.
        microphone.stop()
        await task?.value
        if let failure { throw failure }
    }
    public func stop() { generation = UUID(); task?.cancel(); task = nil; microphone.stop(); output?.finish(); output = nil }
}

/// Model-independent streaming loop, shared by live capture and deterministic tests.
/// Closing the audio stream drains its buffer, then finalizes residual speech once.
public enum WhisperStreamProcessor {
    public static func run(audio: AsyncThrowingStream<[Float], Error>,
                           decode: @Sendable ([Float]) async throws -> String,
                           completed: @Sendable (String) async -> Void = { _ in },
                           emit: (TranscriptEvent) throws -> Void) async throws {
        var window = UtteranceBuffer(maxSeconds: 8)
        var id = 0, lastDecodedCount = 0
        for try await frame in audio {
            try Task.checkCancellation()
            let final = window.append(frame)
            let samples = final ?? window.samples
            guard final != nil || (window.hasSpeech && samples.count - lastDecodedCount >= 24000) else { continue }
            let text = try await decode(samples)
            try Task.checkCancellation()
            // An empty final is meaningful: it removes an earlier partial hallucination.
            if !text.isEmpty || final != nil { try emit(.init(id: id, text: text, isFinal: final != nil)) }
            if final != nil { await completed(text); id += 1; lastDecodedCount = 0 } else { lastDecodedCount = samples.count }
        }
        if let tail = window.flush() {
            let text = try await decode(tail)
            try Task.checkCancellation()
            try emit(.init(id: id, text: text, isFinal: true))
            await completed(text)
        }
    }
}
