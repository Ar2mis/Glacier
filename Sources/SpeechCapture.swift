import AVFoundation
import Speech

enum CaptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

// AVAudioEngine invokes its tap serially. Conversion stays on that callback;
// only owned PCM buffers are handed to SpeechAnalyzer.
final class AudioBridge: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let failed: @Sendable (String) -> Void
    init(source: AVAudioFormat, target: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         failed: @escaping @Sendable (String) -> Void) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw CaptionError.message("无法转换麦克风音频格式。")
        }
        self.converter = converter; self.target = target
        self.continuation = continuation; self.failed = failed
    }
    func accept(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { failed(error?.localizedDescription ?? "音频转换失败"); return }
        if output.frameLength > 0 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                failed("处理速度跟不上收音，已停止。请关闭高负载应用后重试。")
            }
        }
    }
}

@MainActor
final class SpeechCapture {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var tapInstalled = false

    func start(status: @escaping (String) -> Void,
               result: @escaping (String, Bool) -> Void,
               failure: @escaping (String) -> Void) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard granted else { throw CaptionError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许「听课字幕」。") }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw CaptionError.message("当前系统不支持英语本地转录。")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        status("正在准备英语语音模型，首次使用可能需要下载…")
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CaptionError.message("找不到可用的语音格式。")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        self.continuation = continuation
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else { throw CaptionError.message("没有可用的麦克风。") }
        let bridge = try AudioBridge(source: source, target: format, continuation: continuation) { message in
            Task { @MainActor in failure(message) }
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in bridge.accept(buffer) }
        tapInstalled = true
        resultTask = Task {
            do {
                for try await update in transcriber.results {
                    guard !Task.isCancelled else { return }
                    result(String(update.text.characters), update.isFinal)
                }
            } catch { if !Task.isCancelled { failure(error.localizedDescription) } }
        }
        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { if !Task.isCancelled { failure(error.localizedDescription) } }
        }
        engine.prepare()
        try engine.start()
        status("正在听 · 英语 → 简体中文")
    }

    func stop() async {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        continuation?.finish(); continuation = nil
        resultTask?.cancel(); analysisTask?.cancel()
        resultTask = nil; analysisTask = nil
        let previous = analyzer; analyzer = nil
        await previous?.cancelAndFinishNow()
    }
}
