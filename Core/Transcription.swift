import Foundation

public enum SpeechProvider: String, CaseIterable, Identifiable, Sendable {
    case whisperKit = "whisperkit", appleSpeech = "apple-speech", openAI = "openai-asr", deepgram
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .whisperKit: "WhisperKit · On device"
        case .appleSpeech: "Apple · SFSpeechRecognizer"
        case .openAI: "OpenAI · Cloud audio chunks"
        case .deepgram: "Deepgram · Cloud streaming"
        }
    }
    public var sendsAudioToCloud: Bool { self == .openAI || self == .deepgram }
}

public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case base = "openai_whisper-base"
    // Argmax's actual Core ML name for OpenAI's large-v3-turbo.
    case turbo = "openai_whisper-large-v3-v20240930_turbo"
    public var id: String { rawValue }
    public var title: String { self == .base ? "Base · faster startup" : "Large v3 Turbo · more memory" }
}

public struct TranscriptEvent: Sendable, Equatable {
    public let id: Int
    public let text: String
    public let isFinal: Bool
    public init(id: Int, text: String, isFinal: Bool) { self.id = id; self.text = text; self.isFinal = isFinal }
}

public enum GlacierCoreError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor public protocol StreamingTranscriber: AnyObject {
    func start(status: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    func stop()
}

@MainActor public enum TranscriberFactory {
    public static func make(provider: SpeechProvider, model: WhisperModel = .base, key: String = "") -> any StreamingTranscriber {
        switch provider {
        case .whisperKit: WhisperTranscriber(model: model)
        case .appleSpeech: AppleTranscriber()
        case .openAI: CloudTranscriber(provider: .openAI, key: key)
        case .deepgram: CloudTranscriber(provider: .deepgram, key: key)
        }
    }
}

/// Bounded 16 kHz utterances with a short silent tail. No lecture-length PCM buffer.
/// RMS is a deliberately simple energy gate, not a learned voice detector.
public struct UtteranceBuffer {
    public private(set) var samples: [Float] = []
    public private(set) var hasSpeech = false
    private var silentSamples = 0
    private let limit: Int
    public init(maxSeconds: Double = 12) { limit = Int(min(20, max(1, maxSeconds.isFinite ? maxSeconds : 12)) * 16000) }
    public mutating func append(_ frame: [Float]) -> [Float]? {
        guard !frame.isEmpty else { return nil }
        let finite = frame.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        let power = finite.reduce(Float(0)) { $0 + $1 * $1 } / Float(finite.count)
        if power > 0.000025 { hasSpeech = true; silentSamples = 0 } else { silentSamples += finite.count }
        samples += finite
        if !hasSpeech { samples = Array(samples.suffix(3200)); return nil }
        if silentSamples >= 10400 || samples.count >= limit {
            let result = samples
            samples = []; hasSpeech = false; silentSamples = 0
            return result
        }
        return nil
    }
}
