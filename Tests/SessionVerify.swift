import Foundation
import AppKit

actor Calls {
    var values: [String] = []
    func record(_ value: String) -> Int { values.append(value); return values.count }
    func count() -> Int { values.count }
    func contains(_ value: String) -> Bool { values.contains(value) }
}

@main enum SessionVerify {
    @MainActor static func main() async throws {
        var passed = [String]()
        func check(_ condition: Bool, _ name: String) {
            // Optimized preconditions may omit their message; preserve it in CI logs.
            if !condition { FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)) }
            precondition(condition, name)
            passed.append(name)
            FileHandle.standardOutput.write(Data("PASS: \(name)\n".utf8))
        }
        func snapshot(_ text: String, active: Bool? = true, id: Int = 1) -> WisprSnapshot {
            .init(meeting: "Simulated Biology Lecture", segments: text.isEmpty ? [] : [.init(id: id, text: text)], recording: active)
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func waitUntil(_ name: String, condition: () async -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(6)
            while !(await condition()) {
                if ContinuousClock.now >= deadline { check(false, "Timed out: \(name)"); return }
                await wait(0.02)
            }
        }
        let model = CaptionModel(simulation: true) { source, _, _, update in
            await update("模拟译文：" + source)
            return "模拟译文：" + source
        }
        model.status = "API test error stays visible"
        model.receive(snapshot("", active: false))
        model.receive(snapshot("", active: nil))
        check(model.status == "API test error stays visible", "idle observations preserve diagnostic status")
        model.demo()
        model.receive(snapshot("", active: false))
        check(model.visible, "idle observation preserves intentional preview")
        model.receive(snapshot("Water moves across the membrane."))
        await waitUntil("first completed translation") {
            model.historyEntries.first?.translatedSource == "Water moves across the membrane."
        }
        check(model.running && model.visible && model.chinese == "模拟译文：Water moves across the membrane.", "real caption model displays translated simulated transcript")
        check(model.historyEntries.first?.translatedSource == "Water moves across the membrane.", "history contains verified source and completed translation")
        model.receive(snapshot("", active: false))
        check(!model.running && !model.visible && !model.wisprRecording, "external Wispr stop immediately hides captions")
        model.receive(snapshot("The next class starts."))
        check(model.historyEntries.count == 1 && model.english == "The next class starts.", "restart resets previous lecture and waiting text")
        await wait(0.5)
        model.receive(snapshot("", active: false))

        let slowCalls = Calls()
        let delayed = CaptionModel(simulation: true) { source, _, _, update in
            _ = await slowCalls.record(source)
            if source.contains("OLD") {
                // Deliberately ignore cancellation to emulate a queued callback
                // from a SDK that completed immediately before stop/restart.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
                }
            }
            await update("译文：" + source)
            if source.contains("OLD") { _ = await slowCalls.record("OLD callback delivered") }
            return "译文：" + source
        }
        delayed.receive(snapshot("OLD lecture."))
        await waitUntil("old request started before cancellation") { await slowCalls.count() > 0 }
        delayed.receive(snapshot("", active: false))
        delayed.receive(snapshot("NEW lecture."))
        await waitUntil("late callback delivered after restart") { await slowCalls.contains("OLD callback delivered") }
        check(delayed.english == "NEW lecture." && !delayed.chinese.contains("OLD"), "late callback from old recording cannot overwrite new session")
        delayed.receive(snapshot("", active: false))
        await wait(0.2)
        check(!delayed.visible, "late completion cannot reopen stopped overlay")

        let quotaCalls = Calls()
        let quota = CaptionModel(simulation: true) { source, _, _, _ in
            _ = await quotaCalls.record(source)
            throw TranslationFailure(kind: .quota, message: "API 额度已耗尽")
        }
        quota.receive(snapshot("First sentence."))
        await waitUntil("quota failure displayed") { quota.chinese.contains("额度") }
        for number in 2...15 { quota.receive(snapshot("Sentence \(number).", id: number)); await wait(0.03) }
        await wait(0.6)
        let quotaCount = await quotaCalls.count()
        check(quotaCount == 1, "exhausted quota suspends requests instead of retry storm")
        check(quota.english == "Sentence 15." && quota.chinese.contains("额度"), "English continues with persistent actionable API error")
        quota.receive(snapshot("", active: false))

        let retryCalls = Calls()
        let recovery = CaptionModel(simulation: true) { source, _, _, update in
            let attempt = await retryCalls.record(source)
            if attempt == 1 { throw TranslationFailure(kind: .rateLimit, message: "服务限流", retryAfter: 2) }
            await update("重试成功")
            return "重试成功"
        }
        recovery.receive(snapshot("Retry this final sentence."))
        await waitUntil("retry completed after backoff") { recovery.chinese == "重试成功" }
        let retryCount = await retryCalls.count()
        check(retryCount == 2 && recovery.chinese == "重试成功", "transient failure retries last sentence even without new speech")
        recovery.receive(snapshot("", active: false))

        let burstCalls = Calls()
        let burst = CaptionModel(simulation: true) { source, _, _, update in
            _ = await burstCalls.record(source)
            try await Task.sleep(for: .milliseconds(70))
            await update("模拟中文：" + source)
            try await Task.sleep(for: .milliseconds(70))
            return "模拟中文：" + source
        }
        let words = "The cell membrane selectively allows water molecules to pass while restricting larger particles and this movement continues until the concentration reaches equilibrium".split(separator: " ")
        var sawPartial = false
        for count in 1...words.count {
            burst.receive(snapshot(words.prefix(count).joined(separator: " ")))
            await wait(0.08)
            if burst.chinese.hasPrefix("模拟中文：") { sawPartial = true }
        }
        let finalSource = words.joined(separator: " ") + "."
        burst.receive(snapshot(finalSource))
        await waitUntil("final revision translated") {
            burst.english == finalSource && burst.historyEntries.first?.translatedSource == finalSource
        }
        check(sawPartial, "continuous ASR revisions produce Chinese before sentence end")
        check(burst.english == words.joined(separator: " ") + ".", "final ASR revision eventually replaces partial pair")
        check(burst.historyEntries.first?.translatedSource == burst.english, "revised history never attaches translation to wrong source")
        burst.receive(snapshot("", active: false))

        for index in 0..<30 {
            model.receive(snapshot("Restart \(index).")); model.receive(snapshot("", active: false))
        }
        await wait(0.6)
        check(!model.visible && !model.running && !model.quickBusy, "thirty rapid start-stop cycles leave no active captions")
        let report: [String: Any] = ["tested_at": ISO8601DateFormatter().string(from: Date()), "microphone_used": false,
            "real_wispr_recording_started": false, "translator": "deterministic simulated service", "checks": passed, "count": passed.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: ".build/session-report.json"))
        print("Session simulations passed: \(passed.count); no microphone, Wispr control, Keychain or real API calls.")
    }
}
