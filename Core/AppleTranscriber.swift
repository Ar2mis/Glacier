import AVFoundation
import Speech

@MainActor public final class AppleTranscriber: StreamingTranscriber {
    private let microphone = Microphone()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var audioTask: Task<Void, Never>?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var generation = UUID()
    private var utterance = 0
    public init() {}
    public func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        stop()
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        try Task.checkCancellation()
        guard permission, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw GlacierCoreError.message("Apple on-device English speech recognition is unavailable or not authorized.")
        }
        self.recognizer = recognizer; utterance = 0
        let audio = try await microphone.start()
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output = continuation
        beginRecognition()
        audioTask = Task { [weak self] in
            do {
                for try await frame in audio {
                    try Task.checkCancellation()
                    guard let self else { return }
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.count)),
                          let pointer = buffer.floatChannelData?[0] else { continue }
                    buffer.frameLength = AVAudioFrameCount(frame.count)
                    frame.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: frame.count) }
                    self.request?.append(buffer)
                }
            } catch is CancellationError {} catch {
                continuation.finish(throwing: GlacierCoreError.message("Apple microphone stream stopped.")); self?.stop()
            }
        }
        status("Apple on-device speech ready")
        return stream
    }
    private func beginRecognition() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request
        let token = UUID(); generation = token
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let text, !text.isEmpty {
                    if case .dropped = self.output?.yield(.init(id: self.utterance, text: text, isFinal: final)) {
                        self.output?.finish(throwing: GlacierCoreError.message("Caption consumer cannot keep up.")); self.stop(); return
                    }
                }
                if final { self.utterance += 1; self.beginRecognition() }
                else if failed { self.output?.finish(throwing: GlacierCoreError.message("Apple speech recognition stopped. Start again to reconnect.")); self.stop() }
            }
        }
    }
    public func stop() {
        generation = UUID(); audioTask?.cancel(); audioTask = nil
        request?.endAudio(); recognition?.cancel(); request = nil; recognition = nil
        microphone.stop(); output?.finish(); output = nil
    }
}
