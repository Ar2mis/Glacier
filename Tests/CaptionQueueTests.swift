import Foundation
struct TranslationPair { let english: String; let chinese: String }
@main enum CaptionQueueTests {
    static func main() {
        let t = Date(timeIntervalSince1970: 100)
        var buffer = LiveCaptionBuffer()
        _ = buffer.update([.init(id: 1, text: "The cell")], now: t)
        precondition(buffer.nextJob(now: t) == nil, "Debounce avoids a request per word")
        let inFlight = buffer.nextJob(now: t.addingTimeInterval(0.4))!
        let firstId = inFlight.id
        _ = buffer.update([.init(id: 1, text: "The cell membrane allows water through.")], now: t.addingTimeInterval(0.5))
        // After a revision, queuedAt for the old inFlight job must be pruned if the sentence is merged/removed.
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
        // Priming queuedAt for both 3:0 and 3:1 for test
        // Their punctuation merge should invalidate debounce timestamps for the removed id
        let beforeDebounce = Mirror(reflecting: buffer).children.first(where: { $0.label == "queuedAt" })?.value as? [String: Date]
        precondition(beforeDebounce?[("3:1")] != nil, "Debounce timestamp exists before punctuation merge")
        _ = buffer.update([.init(id: 3, text: "One sentence and another sentence.")], now: t.addingTimeInterval(13))
        precondition(!buffer.entries.contains { $0.id == "3:1" }, "Punctuation correction removes obsolete sentence")
        // Confirm the debounce is pruned when entry id is merged away
        let afterDebounce = Mirror(reflecting: buffer).children.first(where: { $0.label == "queuedAt" })?.value as? [String: Date]
        precondition(afterDebounce?[("3:1")] == nil, "Debounce timestamp is pruned after merge")
        precondition(buffer.recent(at: t.addingTimeInterval(35)).count == 1, "Lookback excludes sources older than thirty seconds")
        // Regression: Add a sentence, let it expire, confirm queuedAt is pruned
        let expireT = t.addingTimeInterval(300 + 10)
        _ = buffer.update([.init(id: 4, text: "Old sentence")], now: t.addingTimeInterval(300))
        let queuedAtKey = "4:0"
        let debounceAfterAdd = Mirror(reflecting: buffer).children.first(where: { $0.label == "queuedAt" })?.value as? [String: Date]
        precondition(debounceAfterAdd?[queuedAtKey] != nil, "Debounce timestamp for added sentence set")
        _ = buffer.update([.init(id: 5, text: "Final sentence")], now: expireT)
        let debounceAfterExpire = Mirror(reflecting: buffer).children.first(where: { $0.label == "queuedAt" })?.value as? [String: Date]
        precondition(debounceAfterExpire?[queuedAtKey] == nil, "Debounce is pruned after 5 minute expiry")
        print("PASS: queue debounce, order, overload, revisions, retry, punctuation merger, 30-second history, and debounce pruning on merge/expiry")
    }
}
