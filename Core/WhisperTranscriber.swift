import Foundation
import WhisperKit

private actor WhisperDecoder {
    private var pipe: WhisperKit?
    private var vocabulary = ""
    private var previousFinal = ""
    private var loading: (id: UUID, task: Task<Void, Error>)?
    func setVocabulary(_ text: String) { vocabulary = CourseVocabulary.normalize(text); previousFinal = "" }
    func remember(_ text: String) { previousFinal = String(text.suffix(500)) }
    func prepare(model: WhisperModel) async throws {
        if pipe != nil { try Task.checkCancellation(); return }
        // A canceled click must not launch a second compiler when retried. Keep
        // the one preparation task; it does not open or retain microphone audio.
        if loading == nil {
            loading = (UUID(), Task { self.pipe = try await WhisperKit(WhisperModelStorage.configuration(model)) })
        }
        let work = loading!
        do {
            try await work.task.value
            if loading?.id == work.id { loading = nil }
        } catch {
            if loading?.id == work.id { loading = nil }
            throw error
        }
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
    /// Warm model assets without requesting microphone access or recording audio.
    public func prepare() async throws { try await decoder.prepare(model: model) }
    public func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        stop()
        failure = nil
        let token = generation
        status("正在开启麦克风…")
        await decoder.setVocabulary(vocabulary)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let audio = try await microphone.start()
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output = continuation
        task = Task { [weak self, decoder, model] in
            do {
                // Capture/ingestion starts first. Cold model compilation must not
                // delay the microphone or discard the beginning of the lecture.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await decoder.prepare(model: model)
                        try Task.checkCancellation()
                        await status("正在收音 · WhisperKit 实时识别已就绪")
                    }
                    group.addTask {
                        try await WhisperStreamProcessor.run(audio: audio, decode: {
                            try await decoder.prepare(model: model)
                            return try await decoder.decode($0)
                        }, completed: { await decoder.remember($0) }) { event in
                            if case .dropped = continuation.yield(event) { throw GlacierCoreError.message("Caption consumer cannot keep up.") }
                        }
                    }
                    do { while let _ = try await group.next() {} }
                    catch { group.cancelAll(); throw error }
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish() }
            catch {
                let error = error as? GlacierCoreError ?? GlacierCoreError.message("Whisper transcription stopped before finalization. Check the model/network or try Base; available transcript is saved.")
                if self?.generation == token { self?.failure = error }
                continuation.finish(throwing: error)
            }
            if self?.generation == token { self?.microphone.stop() }
        }
        status("已开启收音 · 模型准备时会缓存音频并自动补识别")
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
private struct WhisperDecodeJob: Sendable {
    let id: Int
    let samples: [Float]
    let final: Bool
}

/// Ingest audio independently of inference. Coalesce superseded partials instead
/// of repeatedly decoding old prefixes while the microphone gets further ahead.
private actor WhisperDecodeQueue {
    private var window = UtteranceBuffer(maxSeconds: 8)
    private var id = 0, lastPartialCount = 0
    private var finals: [WhisperDecodeJob] = []
    private var partial: WhisperDecodeJob?
    private var failure: Error?
    func append(_ frame: [Float]) throws {
        if let samples = window.append(frame) {
            guard finals.count < 64 else { throw GlacierCoreError.message("Whisper audio backlog is full; try Base or close heavy apps. Available transcript is saved.") }
            finals.append(.init(id: id, samples: samples, final: true))
            partial = nil; id += 1; lastPartialCount = 0
        } else if window.hasSpeech && window.samples.count - lastPartialCount >= 12000 {
            partial = .init(id: id, samples: window.samples, final: false)
            lastPartialCount = window.samples.count
        }
    }
    func finish(_ error: Error? = nil) {
        failure = error
        if let tail = window.flush() { finals.append(.init(id: id, samples: tail, final: true)) }
        partial = nil
    }
    func next() throws -> WhisperDecodeJob? {
        if !finals.isEmpty { return finals.removeFirst() }
        if let partial { self.partial = nil; return partial }
        if let failure { throw failure }
        return nil
    }
}

public enum WhisperStreamProcessor {
    public static func run(audio: AsyncThrowingStream<[Float], Error>,
                           decode: @Sendable ([Float]) async throws -> String,
                           completed: @Sendable (String) async -> Void = { _ in },
                           emit: (TranscriptEvent) throws -> Void) async throws {
        let queue = WhisperDecodeQueue()
        let (signals, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let producer = Task {
            do {
                for try await frame in audio {
                    try Task.checkCancellation()
                    try await queue.append(frame); wake.yield(())
                }
                await queue.finish()
            } catch { await queue.finish(error) }
            wake.yield(()); wake.finish()
        }
        defer { producer.cancel() }
        for await _ in signals {
            while let job = try await queue.next() {
                try Task.checkCancellation()
                let text = try await decode(job.samples)
                try Task.checkCancellation()
                if !text.isEmpty || job.final { try emit(.init(id: job.id, text: text, isFinal: job.final)) }
                if job.final { await completed(text) }
            }
        }
        try Task.checkCancellation()
    }
}
