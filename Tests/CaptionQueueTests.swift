import Foundation
struct TranslationPair { let english: String; let chinese: String }
@main enum CaptionQueueTests {
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
        _ = buffer.update([.init(id: 3, text: "One sentence and another sentence.")], now: t.addingTimeInterval(13))
        precondition(!buffer.entries.contains { $0.id == "3:1" }, "Punctuation correction removes obsolete sentence")
        precondition(buffer.recent(at: t.addingTimeInterval(35)).count == 1, "Lookback excludes sources older than thirty seconds")
        print("PASS: queue debounce, order, overload, revisions, retry, punctuation merger and 30-second history")
    }
}
