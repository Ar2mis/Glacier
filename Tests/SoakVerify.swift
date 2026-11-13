import Foundation
struct TranslationPair { let english: String; let chinese: String }
@main enum SoakVerify {
    static func main() throws {
        var buffer = LiveCaptionBuffer()
        let origin = Date(timeIntervalSince1970: 1_000_000)
        var inFlight: (job: CaptionJob, due: Double)?
        var segments = [TranscriptSegment]()
        var maxEntries = 0, maxJobs = 0, completed = 0, revisions = 0
        let words = "Water moves through a selectively permeable membrane toward higher solute concentration".split(separator: " ")
        for tick in 0..<20_572 { // Two simulated hours at 350 ms per Wispr poll.
            let seconds = Double(tick) * 0.35
            let time = origin.addingTimeInterval(seconds)
            let wordIndex = Int(seconds * 3) // 180 words per minute.
            let segment = wordIndex / words.count
            let count = wordIndex % words.count + 1
            let text = words.prefix(count).joined(separator: " ") + (count == words.count ? "." : "")
            if segments.last?.id == segment { segments[segments.count - 1] = .init(id: segment, text: text); revisions += 1 }
            else { segments.append(.init(id: segment, text: text)); segments = Array(segments.suffix(12)) }
            _ = buffer.update(segments, now: time)
            if let current = inFlight, current.due <= seconds {
                buffer.translated(current.job, text: "模拟译文", complete: true)
                inFlight = nil; completed += 1
            }
            if inFlight == nil, let next = buffer.nextJob(now: time) {
                let delay: Double = tick % 347 == 0 ? 10 : 0.65
                inFlight = (next, seconds + delay)
            }
            maxEntries = max(maxEntries, buffer.entries.count); maxJobs = max(maxJobs, buffer.jobs.count)
            precondition(buffer.entries.count < 100, "Five-minute buffer grows without bound")
            precondition(buffer.jobs.count < 6, "Translation work grows without bound")
            precondition(Set(buffer.entries.map(\.id)).count == buffer.entries.count, "Duplicate sentence IDs")
            precondition(buffer.entries.allSatisfy { $0.translatedSource.isEmpty || $0.translatedSource == $0.english }, "Mismatched bilingual history")
            precondition(buffer.recent(at: time).allSatisfy { time.timeIntervalSince($0.lastSeen) <= 30 }, "History exceeds 30 seconds")
        }
        let report: [String: Any] = ["simulated_minutes": 120, "words_per_minute": 180, "polls": 20_572,
            "asr_revisions": revisions, "completed_requests": completed, "max_history_entries": maxEntries, "max_pending_jobs": maxJobs,
            "real_api_calls": 0, "microphone_used": false, "result": "passed"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: ".build/soak-report.json"))
        print("PASS: two-hour simulated lecture; \(revisions) revisions; bounded history \(maxEntries), queue \(maxJobs); no mismatched source/translation pairs")
    }
}
