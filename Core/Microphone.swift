import AVFoundation

/// The tap serializes converter access. Only owned Float arrays cross the stream.
private final class PCMConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let output: AsyncThrowingStream<[Float], Error>.Continuation
    init(source: AVAudioFormat, output: AsyncThrowingStream<[Float], Error>.Continuation) throws {
        target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target) else { throw GlacierCoreError.message("Microphone audio conversion unavailable.") }
        self.converter = converter; self.output = output
    }
    func accept(_ input: AVAudioPCMBuffer) {
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: count) else { return }
        var supplied = false
        var error: NSError?
        let state = converter.convert(to: buffer, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard state != .error else { output.finish(throwing: GlacierCoreError.message("Microphone conversion failed.")); return }
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        if case .dropped = output.yield(samples) {
            output.finish(throwing: GlacierCoreError.message("Transcription cannot keep up. Try the Base model or close heavy apps."))
        }
    }
}

@MainActor final class Microphone {
    private var engine: AVAudioEngine?
    private var output: AsyncThrowingStream<[Float], Error>.Continuation?
    func start() async throws -> AsyncThrowingStream<[Float], Error> {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw GlacierCoreError.message("Allow Glacier microphone access in Settings.") }
        try Task.checkCancellation()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else { throw GlacierCoreError.message("No microphone input is available.") }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(96))
        let converter = try PCMConverter(source: source, output: continuation)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in converter.accept(buffer) }
        self.engine = engine; output = continuation
        do { engine.prepare(); try engine.start() } catch { stop(); throw GlacierCoreError.message("Unable to start microphone.") }
        return stream
    }
    func stop() {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        output?.finish(); output = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
