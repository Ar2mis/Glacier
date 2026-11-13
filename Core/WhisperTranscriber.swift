import Foundation
import WhisperKit

private actor WhisperDecoder {
    private var pipe: WhisperKit?
    func prepare(model: WhisperModel) async throws {
        pipe = try await WhisperKit(WhisperKitConfig(model: model.rawValue, verbose: false, prewarm: true, load: true))
        try Task.checkCancellation()
    }
    func decode(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw GlacierCoreError.message("Whisper model is not ready.") }
        let options = DecodingOptions(language: "en", temperatureFallbackCount: 1, skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor public final class WhisperTranscriber: StreamingTranscriber {
    private let model: WhisperModel
    private let decoder = WhisperDecoder()
    private let microphone = Microphone()
    private var task: Task<Void, Never>?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    public init(model: WhisperModel = .base) { self.model = model }
    public func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        stop()
        status("Preparing \(model.title). First use downloads the model; later runs use its cache.")
        try await decoder.prepare(model: model)
        try Task.checkCancellation()
        let audio = try await microphone.start()
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output = continuation
        task = Task { [weak self, decoder] in
            var window = UtteranceBuffer(maxSeconds: 6)
            var id = 0, lastDecodedCount = 0
            do {
                for try await frame in audio {
                    try Task.checkCancellation()
                    let final = window.append(frame)
                    let samples = final ?? window.samples
                    guard final != nil || (window.hasSpeech && samples.count - lastDecodedCount >= 24000) else { continue }
                    let text = try await decoder.decode(samples)
                    try Task.checkCancellation()
                    if !text.isEmpty {
                        if case .dropped = continuation.yield(.init(id: id, text: text, isFinal: final != nil)) {
                            throw GlacierCoreError.message("Caption consumer cannot keep up.")
                        }
                    }
                    if final != nil { id += 1; lastDecodedCount = 0 } else { lastDecodedCount = samples.count }
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish() }
            catch { continuation.finish(throwing: GlacierCoreError.message("Whisper transcription stopped. Check the model download/network or try Base.")) }
            self?.microphone.stop()
        }
        status("WhisperKit ready · audio stays on this device")
        return stream
    }
    public func stop() { task?.cancel(); task = nil; microphone.stop(); output?.finish(); output = nil }
}
