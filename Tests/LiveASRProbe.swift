import AppKit
import Foundation
import GlacierCore
import WhisperKit

/// Opt-in integration probe. Replaces only the microphone with paced fixture PCM;
/// the real Parakeet engine, CaptionModel scheduler, GPT refiner and journal run.
@MainActor private final class ReplayCapture: StreamingTranscriber {
    let engine: ParakeetEngine
    let samples: [Float]
    private var feed: Task<Void, Never>?, decode: Task<Void, Never>?
    private var input: AsyncThrowingStream<[Float], Error>.Continuation?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var failure: Error?
    init(engine: ParakeetEngine, samples: [Float]) { self.engine = engine; self.samples = samples }
    func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let (audio, input) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let (events, output) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.input = input; self.output = output
        let clock = ContinuousClock(), start = ContinuousClock.now
        feed = Task { [samples] in
            do {
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    let end = min(samples.count, offset + 1600)
                    try await clock.sleep(until: start + .seconds(Double(end) / 16000))
                    if case .dropped = input.yield(Array(samples[offset..<end])) { throw CaptionError.message("Replay audio overflow") }
                }
                input.finish()
            } catch { input.finish(throwing: error) }
        }
        decode = Task {
            do {
                try await engine.run(audio: audio) { event in
                    if case .dropped = output.yield(event) { throw CaptionError.message("Replay caption overflow") }
                }
                output.finish()
            } catch { failure = error; output.finish(throwing: error) }
        }
        status("Paced synthetic audio · no microphone")
        return events
    }
    func finish() async throws { input?.finish(); await decode?.value; if let failure { throw failure } }
    func stop() { feed?.cancel(); input?.finish(); decode?.cancel(); output?.finish() }
}

@main enum LiveASRProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { throw CaptionError.message("Supply an invented/test audio fixture; text is sent to OpenAI.") }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: CommandLine.arguments[1])
        guard !samples.isEmpty, samples.count <= 16000 * 60 else { throw CaptionError.message("Use at most 60 seconds of test audio") }
        let key = try CredentialStore.read("openai")
        let engine = ParakeetEngine(); try await engine.prepare()
        let capture = ReplayCapture(engine: engine, samples: samples)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlacierLiveProbe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LectureSessionStore(directory: root.appendingPathComponent("Lectures"))
        let archive = LectureArchive(pendingDirectory: root.appendingPathComponent("Pending"), outputDirectory: root.appendingPathComponent("Exports"), lectures: store)
        let model = CaptionModel(simulation: true, archive: archive, coreFactory: { _, _, _ in capture }, credential: { key })
        model.inputMode = SpeechProvider.parakeet.rawValue; model.translationMode = "gpt"
        model.provider = .openai; model.refineEnabled = true; model.refineModel = "gpt-4o-mini"
        model.autoArchive = false; model.readingPriority = false
        model.glossary = "aquaporins = 水通道蛋白\nosmosis = 渗透作用\nequilibrium = 平衡\nmitochondria = 线粒体"
        let start = Date()
        var snapshots = [[String: Any]](), lastChinese = "", usedApple = false
        model.layoutChanged = {
            usedApple = usedApple || model.activeTranslationEngine.contains("Apple")
            if model.chinese != lastChinese {
                lastChinese = model.chinese
                snapshots.append(["seconds": Date().timeIntervalSince(start), "english": model.english,
                                  "chinese": model.chinese, "engine": model.activeTranslationEngine])
            }
        }
        model.start()
        let deadline = Date().addingTimeInterval(Double(samples.count) / 16000 + 60)
        while model.running || model.busy {
            guard Date() < deadline else { model.stop(); throw CaptionError.message("Live caption replay timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
        model.layoutChanged = nil
        let pending = try await store.pending()
        guard let saved = pending.first else { throw CaptionError.message("Replay lecture was not saved") }
        let english = try await store.english(saved.id)
        let useful = snapshots.filter {
            let value = $0["chinese"] as? String ?? ""
            return !value.isEmpty && !["识别中…", "正在翻译…", "听得见，也跟得上。"].contains(value) && !value.hasPrefix("翻译暂不可用") && ($0["engine"] as? String ?? "").contains("OpenAI")
        }
        let report: [String: Any] = ["microphone_used": false, "audio_sent_to_cloud": false,
            "synthetic_text_sent_to_openai": true, "apple_used": usedApple, "saved_english": english,
            "finalization_warning": saved.warning as Any? ?? NSNull(), "caption_hidden_after_stop": !model.visible,
            "first_chinese_seconds": useful.first?["seconds"] ?? NSNull(), "caption_updates": snapshots]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: ".build/live-asr-probe.json"), options: .atomic)
        guard !useful.isEmpty, !usedApple, !english.isEmpty, saved.warning == nil, !model.visible else {
            throw CaptionError.message("Live probe did not complete all checks; inspect .build/live-asr-probe.json")
        }
        print("PASS: real Parakeet → CaptionModel → streamed GPT Chinese; full English journal, Stop drain and hidden overlay; no Apple fallback or microphone")
    }
}
