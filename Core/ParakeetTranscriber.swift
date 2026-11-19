import AVFoundation
import FluidAudio
import Foundation

public struct ParakeetSnapshot: Sendable {
    public let text: String
    public let ended: Bool
    public init(text: String, ended: Bool) { self.text = text; self.ended = ended }
}

/// Shared by microphone capture, paced file replay and model-free regression tests.
/// The SDK accumulates tokens and latches EOU until reset. Finalize/reset at each
/// boundary; never reset concurrently with inference or retain lecture-length tokens.
public enum ParakeetStreamProcessor {
    public static func run(audio: AsyncThrowingStream<[Float], Error>,
                           maximumSegmentSamples: Int = 60 * 16000,
                           push: @Sendable ([Float]) async throws -> ParakeetSnapshot,
                           finish: @Sendable () async throws -> String,
                           reset: @Sendable () async -> Void,
                           emit: @Sendable (TranscriptEvent) async throws -> Void) async throws {
        var id = 0, segmentSamples = 0, silentSamples = 0
        var previous = ""
        for try await frame in audio {
            // One 80ms model shift at a time: an EOU in a large microphone buffer
            // must not discard speech from the next utterance when the SDK resets.
            for offset in stride(from: 0, to: frame.count, by: 1280) {
                try Task.checkCancellation()
                let samples = frame[offset..<min(frame.count, offset + 1280)].map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
                let result = try await push(samples)
                try Task.checkCancellation()
                segmentSamples += samples.count
                let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
                silentSamples = power <= 0.000025 ? silentSamples + samples.count : 0
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // EOU is delayed relative to the input clock. It can arrive after
                // the next word has begun; resetting then truncates that word.
                // Require recent input silence as well as the model's EOU signal.
                if (result.ended && silentSamples >= 3840) || segmentSamples >= max(1280, maximumSegmentSamples) {
                    let final = try await finish().trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    // An empty final still closes an existing provisional journal entry.
                    if !final.isEmpty || !previous.isEmpty { try await emit(.init(id: id, text: final, isFinal: true)) }
                    await reset(); id += 1; segmentSamples = 0; silentSamples = 0; previous = ""
                } else if !text.isEmpty && text != previous {
                    try await emit(.init(id: id, text: text, isFinal: false)); previous = text
                }
            }
        }
        try Task.checkCancellation()
        if segmentSamples > 0 {
            let final = try await finish().trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            if !final.isEmpty || !previous.isEmpty { try await emit(.init(id: id, text: final, isFinal: true)) }
        }
        await reset()
    }
}

/// One model per adapter, serialized across canceled/restarted sessions. Preparation
/// runs off the UI actor and can be canceled without waiting for Core ML compilation.
public actor ParakeetEngine {
    public static let modelRevision = "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355"
    private static let pinModel: Void = {
        ModelRegistry.revisionOverrides["FluidInference/parakeet-realtime-eou-120m-coreml"] = modelRevision
    }()
    private let preparation = SharedPreparation<StreamingEouAsrManager>()
    private var active: (id: UUID, task: Task<Void, Error>)?
    private let mode: ParakeetMode
    public init(mode: ParakeetMode = .balanced320) { self.mode = mode }
    public static var modelDirectory: URL {
        AppDistribution.supportDirectory.appendingPathComponent("Models/ParakeetEOU/" + modelRevision, isDirectory: true)
    }
    private func manager() async throws -> StreamingEouAsrManager {
        _ = Self.pinModel
        return try await preparation.get { [mode] in
            let manager = StreamingEouAsrManager(chunkSize: mode == .fast160 ? .ms160 : .ms320, eouDebounceMs: 480)
            try await manager.loadModels(to: Self.modelDirectory)
            // Core ML may defer kernel compilation until the first prediction.
            // Warm with silence before opening the mic, then discard all state.
            await manager.injectSilence(0.8)
            try await manager.processBufferedAudio()
            _ = try await manager.finish()
            await manager.reset()
            return manager
        }
    }
    public func prepare() async throws { _ = try await manager() }
    public func run(audio: AsyncThrowingStream<[Float], Error>,
                    emit: @escaping @Sendable (TranscriptEvent) async throws -> Void) async throws {
        while let previous = active {
            _ = try? await previous.task.value
            if active?.id == previous.id { active = nil }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let id = UUID()
        let work = Task {
            let manager = try await manager()
            try Task.checkCancellation()
            await manager.reset()
            // Prime left context so a word at audio time zero is not clipped.
            await manager.injectSilence(0.16)
            do {
                try await ParakeetStreamProcessor.run(audio: audio, push: { samples in
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                          let channel = buffer.floatChannelData?[0] else { throw GlacierCoreError.message("Cannot allocate streaming audio buffer.") }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
                    _ = try await manager.process(audioBuffer: buffer)
                    return await ParakeetSnapshot(text: manager.getPartialTranscript(), ended: manager.eouDetected)
                }, finish: {
                    // Supply lookahead after Stop, then drain the SDK's partial chunk.
                    // This adds no wall-clock sleep and is also used in replay tests.
                    await manager.injectSilence(0.64)
                    try await manager.processBufferedAudio()
                    return try await manager.finish()
                }, reset: {
                    await manager.reset()
                    await manager.injectSilence(0.16)
                }, emit: emit)
            } catch {
                await manager.reset()
                throw error
            }
        }
        active = (id, work)
        defer { if active?.id == id { active = nil } }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

@MainActor public final class ParakeetTranscriber: StreamingTranscriber {
    private let engine: ParakeetEngine
    private let microphone = Microphone()
    private var task: Task<Void, Never>?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var generation = UUID()
    private var failure: Error?
    public init(mode: ParakeetMode = .balanced320) { engine = ParakeetEngine(mode: mode) }
    public func prepare() async throws { try await engine.prepare() }
    public func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        stop(); failure = nil
        let token = generation
        status("正在下载 / 准备 Parakeet 模型 · 就绪后开启麦克风")
        // Do not falsely claim recording while a first-use download fills a small
        // microphone queue. Settings can prepare the model before the lecture.
        try await prepare()
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let audio = try await microphone.start()
        try Task.checkCancellation()
        guard generation == token else { microphone.stop(); throw CancellationError() }
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        output = continuation
        task = Task { [weak self, engine] in
            do {
                try await engine.run(audio: audio) { event in
                    if case .dropped = continuation.yield(event) { throw GlacierCoreError.message("Caption consumer cannot keep up; saved text is retained.") }
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish() }
            catch {
                let failure = GlacierCoreError.message("Parakeet streaming failed; saved text is retained. Retry model preparation or select WhisperKit.")
                if self?.generation == token { self?.failure = failure }
                continuation.finish(throwing: failure)
            }
            if self?.generation == token { self?.microphone.stop() }
        }
        status("正在收音 · Parakeet EOU 英文流式识别")
        return stream
    }
    public func finish() async throws {
        microphone.stop()
        await task?.value
        if let failure { throw failure }
    }
    public func stop() {
        generation = UUID(); task?.cancel(); task = nil
        microphone.stop(); output?.finish(); output = nil
    }
}
