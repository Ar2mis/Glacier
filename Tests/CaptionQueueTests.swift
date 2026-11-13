import Foundation
struct TranslationPair { let english: String; let chinese: String }
@main enum CaptionQueueTests {
    // Fail closed if the private field is renamed; optional reflection could
    // otherwise make a "timestamp is absent" assertion pass without inspecting it.
    static func debounceTimes(_ buffer: LiveCaptionBuffer) -> [String: Date] {
        guard let times = Mirror(reflecting: buffer).children.first(where: { $0.label == "queuedAt" })?.value as? [String: Date] else {
            preconditionFailure("Cannot inspect caption debounce state")
        }
        return times
    }

    static func main() {
        let t = Date(timeIntervalSince1970: 100)
        var buffer = LiveCaptionBuffer()
        _ = buffer.update([.init(id: 1, text: "The cell")], now: t)
        precondition(buffer.nextJob(now: t) == nil, "Debounce avoids a request per word")
        let inFlight = buffer.nextJob(now: t.addingTimeInterval(0.4))!
        _ = buffer.update([.init(id: 1, text: "The cell membrane allows water through.")], now: t.addingTimeInterval(0.5))
        _ = buffer.update([.init(id: 1, text: "The cell membrane allows water through."), .init(id: 2, text: "This process is called osmosis.")], now: t.addingTimeInterval(0.6))
        let first = buffer.nextJob(now: t.addingTimeInterval(1))!
        let second = buffer.nextJob(now: t.addingTimeInterval(1))!
        precondition(first.id == "1:0" && second.id == "2:0", "Recent stable sentences stay in order")
        precondition(buffer.nextJob(now: t.addingTimeInterval(1)) == nil)
        precondition(buffer.entries.count == 2)
        buffer.translated(inFlight, text: "细胞", complete: true)
        precondition(buffer.entries[0].chinese.isEmpty, "Old translation must not attach to revised source")
        buffer.translated(second, text: "这个过程称为渗透。", complete: true)
        precondition(buffer.entries[1].chinese == "这个过程称为渗透。")
        buffer.retry(second, now: t.addingTimeInterval(2))
        precondition(buffer.nextJob(now: t.addingTimeInterval(10)) == nil, "Overload cannot accumulate a stale queue")
        precondition(buffer.entries.count == 2, "Expired work retains original history")
        _ = buffer.update([.init(id: 3, text: "One sentence. Another sentence.")], now: t.addingTimeInterval(12))
        precondition(buffer.entries.contains { $0.id == "3:1" })
        let beforeDebounce = debounceTimes(buffer)
        precondition(beforeDebounce["3:1"] != nil, "Debounce timestamp exists before punctuation merge")
        _ = buffer.update([.init(id: 3, text: "One sentence and another sentence.")], now: t.addingTimeInterval(13))
        precondition(!buffer.entries.contains { $0.id == "3:1" }, "Punctuation correction removes obsolete sentence")
        // Confirm the debounce is pruned when entry id is merged away
        let afterDebounce = debounceTimes(buffer)
        precondition(afterDebounce["3:1"] == nil, "Debounce timestamp is pruned after merge")
        precondition(buffer.recent(at: t.addingTimeInterval(35)).count == 1, "Lookback excludes sources older than thirty seconds")
        // Check expiry relative to insertion time, including the strict boundary.
        // update alone must prune timers; calling nextJob here would hide the bug.
        var expiring = LiveCaptionBuffer()
        _ = expiring.update([.init(id: 4, text: "Old sentence")], now: t)
        precondition(debounceTimes(expiring)["4:0"] == t)
        _ = expiring.update([.init(id: 4, text: "Old sentence")], now: t.addingTimeInterval(300))
        precondition(expiring.entries.contains { $0.id == "4:0" }, "Keep history at exactly five minutes")
        precondition(debounceTimes(expiring)["4:0"] == t, "Keep pending timer at the expiry boundary")
        _ = expiring.update([.init(id: 5, text: "Final sentence")], now: t.addingTimeInterval(300.01))
        precondition(!expiring.entries.contains { $0.id == "4:0" }, "Expire history after five minutes")
        precondition(!expiring.jobs.contains { $0.id == "4:0" })
        precondition(debounceTimes(expiring)["4:0"] == nil, "Prune expired debounce without dequeuing")
        precondition(debounceTimes(expiring)["5:0"] == t.addingTimeInterval(300.01))
        _ = expiring.update([], now: t.addingTimeInterval(601))
        precondition(expiring.entries.isEmpty && expiring.jobs.isEmpty && debounceTimes(expiring).isEmpty,
                     "Empty observations also prune expired state")

        // Continuous revisions must retain their first enqueue time, so the
        // maximum 1.2-second wait still applies even without a stable pause.
        var revising = LiveCaptionBuffer()
        _ = revising.update([.init(id: 10, text: "A")], now: t)
        for step in 1...5 {
            let now = t.addingTimeInterval(Double(step) * 0.2)
            _ = revising.update([.init(id: 10, text: "A revision \(step)")], now: now)
            precondition(debounceTimes(revising)["10:0"] == t, "Revisions retain initial debounce time")
            precondition(revising.nextJob(now: now) == nil, "Do not translate each revision immediately")
        }
        let deadline = t.addingTimeInterval(1.21)
        _ = revising.update([.init(id: 10, text: "A final revision")], now: deadline)
        precondition(revising.nextJob(now: deadline)?.english == "A final revision", "Continuous revisions cannot starve translation")
        precondition(debounceTimes(revising).isEmpty, "Dequeue clears its timer")

        // A removed suffix that reappears must get a fresh debounce deadline.
        var merging = LiveCaptionBuffer()
        _ = merging.update([.init(id: 20, text: "One sentence. Another sentence.")], now: t)
        _ = merging.update([.init(id: 20, text: "One sentence and another sentence.")], now: t.addingTimeInterval(1))
        precondition(debounceTimes(merging)["20:1"] == nil)
        let restored = t.addingTimeInterval(1.3)
        _ = merging.update([.init(id: 20, text: "One sentence. Another sentence.")], now: restored)
        precondition(debounceTimes(merging)["20:1"] == restored)
        precondition(merging.nextJob(now: restored)?.id == "20:0", "Surviving revision keeps its original deadline")
        precondition(merging.nextJob(now: restored) == nil, "Restored suffix must not inherit an expired deadline")
        precondition(merging.nextJob(now: restored.addingTimeInterval(0.36))?.id == "20:1")
        // ----- DI-02: Context includes only finished translations -----
        var ctx = LiveCaptionBuffer()
        _ = ctx.update([.init(id: 30, text: "First sentence.")], now: t)
        let jobA = ctx.nextJob(now: t.addingTimeInterval(1))!
        ctx.translated(jobA, text: "第一句。", complete: false) // Partial/unfinished
        _ = ctx.update([.init(id: 30, text: "First sentence. Second done.")], now: t.addingTimeInterval(2))
        let jobB = ctx.nextJob(now: t.addingTimeInterval(2))!
        var contextB = ctx.context(before: jobB.id)
        precondition(contextB.isEmpty, "Unfinished translation should not appear in context")
        ctx.translated(jobA, text: "第一句。", complete: true)
        var contextCAfterAComplete = ctx.context(before: jobB.id)
        precondition(contextCAfterAComplete.count == 1, "Completed translation should appear in context")
        precondition(contextCAfterAComplete[0].english == "First sentence.", "Context uses original sentence before revision if not revised")
        precondition(contextCAfterAComplete[0].chinese == "第一句。")
        ctx.translated(jobB, text: "第二句。", complete: true)
        let jobC = CaptionJob(id: "30:2", english: "Third sentence.")
        ctx.entries.append(.init(id: jobC.id, firstSeen: t.addingTimeInterval(3), lastSeen: t.addingTimeInterval(3), english: jobC.english))
        ctx.jobs.append(jobC)
        ctx.translated(jobC, text: "第三句。", complete: false)
        let contextC = ctx.context(before: jobC.id)
        precondition(contextC.count == 2 && contextC[0].english == "First sentence." && contextC[1].english == "Second done.", "Only completed, in-order context included")
        precondition(contextC[1].chinese == "第二句。", "Context shows completed translation")
        // Now revise second entry's translation, verify revision considered
        ctx.translated(jobB, text: "第二句，修正。", complete: true)
        let contextC2 = ctx.context(before: jobC.id)
        precondition(contextC2[1].chinese == "第二句，修正。", "Revision to completed translation appears in context")
        // Now make a fourth and fifth, confirm rolling window
        _ = ctx.update([.init(id: 31, text: "Four.")], now: t.addingTimeInterval(4))
        let jobD = ctx.nextJob(now: t.addingTimeInterval(4))!
        ctx.translated(jobD, text: "四。", complete: true)
        _ = ctx.update([.init(id: 32, text: "Five.")], now: t.addingTimeInterval(5))
        let jobE = ctx.nextJob(now: t.addingTimeInterval(5))!
        ctx.translated(jobE, text: "五。", complete: true)
        // Add sixth, then context should only show 4 most recent completed
        _ = ctx.update([.init(id: 33, text: "Six.")], now: t.addingTimeInterval(6))
        let jobF = ctx.nextJob(now: t.addingTimeInterval(6))!
        ctx.translated(jobF, text: "六。", complete: true)
        let ctxF = ctx.context(before: jobF.id)
        precondition(ctxF.count == 4, "Context limited to four most recent completed entries")
        precondition(ctxF.last?.english == "Five.", "Latest included in context")
        precondition(ctxF[0].english == "Second done.", "Rolling context window oldest is the fourth back")
        print("PASS: queue debounce, order, overload, revisions, retry, punctuation merger, 30-second history, debounce pruning, and context exclusion of unfinished translations")
    }
}
