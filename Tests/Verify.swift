import Foundation
import Speech
import AVFoundation
import Translation

@main
struct Verify {
    static func main() async throws {
        precondition(CaptionText.tail("  one\n two   three ", words: 2) == "two three")
        precondition(CaptionText.tail("").isEmpty)
        precondition(CaptionText.tail((1...100).map(String.init).joined(separator: " ")).split(separator: " ").count == 22)
        let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        // AnalyzerInput requires signed 16-bit PCM on newer Speech frameworks.
        // Production asks SpeechAnalyzer for its preferred compatible format.
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let bridge = try AudioBridge(source: source, target: target, continuation: continuation) { message in
            fatalError(message)
        }
        for _ in 0..<4 {
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2048)!
            buffer.frameLength = 2048
            for channel in 0..<2 {
                for frame in 0..<2048 { buffer.floatChannelData![channel][frame] = 0.01 }
            }
            bridge.accept(buffer)
        }
        continuation.finish()
        var count = 0
        for await input in stream {
            precondition(input.buffer.format.commonFormat == .pcmFormatInt16)
            precondition(input.buffer.format.sampleRate == 16000)
            precondition(input.buffer.format.channelCount == 1)
            precondition(input.buffer.frameLength > 0)
            count += 1
        }
        precondition(count > 0)
        print("PASS: caption bounds; stereo 48 kHz to mono 16 kHz PCM conversion")
        // Headless CI does not query/download speech assets or request permissions.
        if ProcessInfo.processInfo.environment["CI"] == "true" { return }
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        print("Speech available: \(SpeechTranscriber.isAvailable)")
        print("Speech model: \(await AssetInventory.status(forModules: [transcriber]))")
        let availability = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
        print("Translation model: \(availability)")
        guard CommandLine.arguments.count > 1 else { return }
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () throws -> String in
            var finalText = ""
            for try await result in transcriber.results where result.isFinal {
                finalText += String(result.text.characters)
            }
            return finalText
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let recognized = try await results.value
        precondition(recognized.lowercased().contains("membrane"), "Unexpected recognition: \(recognized)")
        print("PASS: speech file recognized: \(recognized)")
        if availability == .installed {
            let translator = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
            let translated = try await translator.translate(recognized)
            precondition(!translated.targetText.isEmpty)
            print("PASS: English → Chinese: \(translated.targetText)")
        }
    }
}
