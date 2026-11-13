import Foundation

public enum AudioEncoding {
    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for value in samples {
            var sample = Int16((value.isFinite ? min(1, max(-1, value)) : 0) * 32767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }
    public static func wav(_ samples: [Float]) -> Data {
        let pcm = pcm16(samples)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

public enum CloudASRParser {
    public static func deepgram(_ data: Data, id: Int) throws -> TranscriptEvent? {
        guard data.count <= 262144, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GlacierCoreError.message("Invalid Deepgram response.") }
        if object["type"] as? String == "Error" { throw GlacierCoreError.message("Deepgram could not transcribe this session.") }
        guard object["type"] as? String == "Results",
              let channel = object["channel"] as? [String: Any], let alternatives = channel["alternatives"] as? [[String: Any]],
              let text = alternatives.first?["transcript"] as? String, !text.isEmpty else { return nil }
        return .init(id: id, text: text, isFinal: object["is_final"] as? Bool ?? false)
    }
}

@MainActor public final class CloudTranscriber: StreamingTranscriber {
    private let provider: SpeechProvider
    private let key: String
    private let microphone = Microphone()
    private var tasks: [Task<Void, Never>] = []
    private var socket: URLSessionWebSocketTask?
    private var output: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    public init(provider: SpeechProvider, key: String) { self.provider = provider; self.key = key }
    public func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        stop()
        guard !key.isEmpty else { throw GlacierCoreError.message("Save this speech provider's API key first.") }
        let audio = try await microphone.start()
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output = continuation
        if provider == .deepgram {
            var request = URLRequest(url: URL(string: "wss://api.deepgram.com/v1/listen?model=nova-3&language=en&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&punctuate=true&endpointing=500")!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.maximumMessageSize = 262144
            self.socket = socket; socket.resume()
            tasks.append(Task { [weak self] in
                var id = 0
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                        if let event = try CloudASRParser.deepgram(data, id: id) {
                            if case .dropped = continuation.yield(event) { throw GlacierCoreError.message("Caption consumer cannot keep up.") }
                            if event.isFinal { id += 1 }
                        }
                    }
                } catch { if !Task.isCancelled { continuation.finish(throwing: GlacierCoreError.message("Deepgram disconnected. Check the key/network, then start again.")); self?.stop() } }
            })
            tasks.append(Task { [weak self] in
                do { for try await frame in audio { try Task.checkCancellation(); try await socket.send(.data(AudioEncoding.pcm16(frame))) } }
                catch { if !Task.isCancelled { continuation.finish(throwing: GlacierCoreError.message("Cloud audio stream stopped.")); self?.stop() } }
            })
        } else {
            let key = self.key
            tasks.append(Task { [weak self] in
                var window = UtteranceBuffer(maxSeconds: 3), id = 0
                do {
                    for try await frame in audio {
                        try Task.checkCancellation()
                        guard let samples = window.append(frame) else { continue }
                        let text = try await Self.openAI(samples: samples, key: key)
                        try Task.checkCancellation()
                        if !text.isEmpty {
                            if case .dropped = continuation.yield(.init(id: id, text: text, isFinal: true)) { throw GlacierCoreError.message("Caption consumer cannot keep up.") }
                        }
                        id += 1
                    }
                } catch { if !Task.isCancelled { continuation.finish(throwing: GlacierCoreError.message("OpenAI audio transcription failed. Check key/quota/network, then start again.")); self?.stop() } }
            })
        }
        status("\(provider.title) · microphone audio is sent to this provider")
        return stream
    }
    private nonisolated static func openAI(samples: [Float], key: String) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        for (name, value) in [("model", "gpt-transcribe"), ("language", "en"), ("response_format", "json")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(AudioEncoding.wav(samples)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 10; request.httpBody = body
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count < 262144,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String else {
            throw GlacierCoreError.message("OpenAI speech response failed validation.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        microphone.stop(); output?.finish(); output = nil
    }
}
