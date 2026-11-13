import Foundation
import Translation

actor FirstToken {
    var time: Date?
    func record() { if time == nil { time = Date() } }
}
@main enum ServiceProbe {
    @MainActor static func main() async {
        var report = [String: Any]()
        let prefs = UserDefaults(suiteName: "local.ar2mis.lecturecaptions")!
        let provider = AIProvider(rawValue: prefs.string(forKey: "aiProvider") ?? "openai") ?? .openai
        let model = prefs.string(forKey: "gptModel") ?? provider.defaultModel
        let source = "The membrane is selectively permeable, not completely open."
        report["provider"] = provider.title; report["model"] = model
        report["synthetic_english"] = source; report["microphone_used"] = false
        do {
            let key = try await Task.detached { try APIKeyStore.read(provider: provider) }.value
            let start = Date()
            let first = FirstToken()
            let translated = try await GPTTranslator(key: key, model: model, provider: provider).stream(source, context: [], glossary: "") { _ in await first.record() }
            report["cloud_status"] = "success"; report["cloud_translation"] = translated
            report["cloud_complete_seconds"] = Date().timeIntervalSince(start)
            if let time = await first.time { report["cloud_first_token_seconds"] = time.timeIntervalSince(start) }
        } catch {
            let failure = TranslationFailure.classify(error)
            report["cloud_status"] = failure.kind.rawValue; report["cloud_message"] = failure.message
        }
        let installed = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans")) == .installed
        report["apple_translation_installed"] = installed
        if installed {
            do {
                let session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
                let start = Date()
                let translated = try await session.translate(source)
                report["apple_status"] = "success"; report["apple_translation"] = translated.targetText
                report["apple_complete_seconds"] = Date().timeIntervalSince(start)
            } catch { report["apple_status"] = "unavailable" }
        }
        if installed {
            let appModel = CaptionModel(simulation: true) { _, _, _, _ in
                throw TranslationFailure(kind: .quota, message: "模拟额度耗尽")
            }
            appModel.translationPrepared()
            let start = Date()
            appModel.receive(.init(meeting: "Synthetic fallback probe", segments: [.init(id: 1, text: source)], recording: true))
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(100))
                if appModel.historyEntries.first?.translatedSource == source { break }
            }
            report["caption_fallback_success"] = appModel.historyEntries.first?.translatedSource == source
            report["caption_fallback_translation"] = appModel.chinese
            report["caption_fallback_seconds"] = Date().timeIntervalSince(start)
            appModel.receive(.init(meeting: "Synthetic fallback probe", segments: [], recording: false))
            report["caption_hidden_after_stop"] = !appModel.visible
        }
        report["tested_at"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ".build/service-probe.json"))
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
