import Foundation

struct CaptionHistoryEntry: Identifiable, Sendable {
    let id: String
    let firstSeen: Date
    var lastSeen: Date
    var english: String
    var chinese: String = ""
    var translatedSource: String = ""
}

struct CaptionJob: Equatable, Sendable {
    let id: String
    let english: String
}

struct LiveCaptionBuffer {
    private(set) var entries: [CaptionHistoryEntry] = []
    private(set) var jobs: [CaptionJob] = []
    private var seen: [Int: String] = [:]
    private var initialized = false
    private var queuedAt: [String: Date] = [:]

    mutating func update(_ segments: [TranscriptSegment], now: Date = Date()) -> CaptionHistoryEntry? {
        if !initialized {
            initialized = true
            for segment in segments.dropLast() { seen[segment.id] = segment.text }
        }
        for segment in segments where seen[segment.id] != segment.text {
            seen[segment.id] = segment.text
            let pieces = SentenceFeed.sentences(segment.text)
            let validIDs = Set(pieces.indices.map { "\(segment.id):\($0)" })
            // A punctuation correction can merge sentences. Remove the obsolete
            // suffix as well, otherwise its old translation remains in history.
            entries.removeAll { $0.id.hasPrefix("\(segment.id):") && !validIDs.contains($0.id) }
            jobs.removeAll { $0.id.hasPrefix("\(segment.id):") && !validIDs.contains($0.id) }
            for (index, text) in pieces.enumerated() {
                let id = "\(segment.id):\(index)"
                if let existing = entries.firstIndex(where: { $0.id == id }) {
                    guard entries[existing].english != text else { continue }
                    entries[existing].english = text; entries[existing].lastSeen = now
                    entries[existing].chinese = ""; entries[existing].translatedSource = ""
                } else { entries.append(.init(id: id, firstSeen: now, lastSeen: now, english: text)) }
                jobs.removeAll { $0.id == id }
                jobs.append(.init(id: id, english: text))
                if queuedAt[id] == nil { queuedAt[id] = now }
            }
        }
        // History contains every observed sentence in the lookback window, plus
        // a margin for translating late results. Old sentences are never written here.
        entries.removeAll { now.timeIntervalSince($0.lastSeen) > 300 }
        let ids = Set(entries.map(\.id))
        jobs.removeAll { !ids.contains($0.id) }
        // Merges and expiry can remove jobs without nextJob being called.
        // Preserve the original debounce start for every still-pending revision.
        let pendingIDs = Set(jobs.map(\.id))
        queuedAt = queuedAt.filter { pendingIDs.contains($0.key) }
        if let first = segments.first?.id { seen = seen.filter { $0.key >= first - 2 } }
        return entries.last
    }
    mutating func nextJob(now: Date = Date()) -> CaptionJob? {
        // Keep recent completed sentences in order. Under overload skip work
        // older than eight seconds, while retaining every source in history.
        jobs.removeAll { job in
            guard let entry = entries.first(where: { $0.id == job.id }) else { return true }
            return now.timeIntervalSince(entry.lastSeen) > 8
        }
        // Clean up debounce timestamps left for jobs that have left the job list.
        let jobIDs = Set(jobs.map { $0.id })
        queuedAt = queuedAt.filter { jobIDs.contains($0.key) }
        let ready = jobs.filter { job in
            guard let entry = entries.first(where: { $0.id == job.id }) else { return false }
            return now.timeIntervalSince(entry.lastSeen) >= 0.35 || now.timeIntervalSince(queuedAt[job.id] ?? now) >= 1.2
        }
        guard let job = ready.min(by: { left, right in
            (entries.firstIndex { $0.id == left.id } ?? 0) < (entries.firstIndex { $0.id == right.id } ?? 0)
        }) else { return nil }
        jobs.removeAll { $0.id == job.id }; queuedAt[job.id] = nil
        return job
    }
    mutating func retry(_ job: CaptionJob, now: Date = Date()) {
        guard entries.contains(where: { $0.id == job.id && $0.english == job.english }),
              !jobs.contains(where: { $0.id == job.id }) else { return }
        jobs.append(job); queuedAt[job.id] = now
    }
    func mayDisplay(_ job: CaptionJob, now: Date = Date()) -> Bool {
        guard let entry = entries.first(where: { $0.id == job.id }) else { return false }
        return now.timeIntervalSince(entry.lastSeen) <= 8
    }
    @discardableResult
    mutating func translated(_ job: CaptionJob, text: String, complete: Bool) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == job.id && $0.english == job.english }) else { return false }
        entries[index].chinese = text
        if complete { entries[index].translatedSource = job.english }
        return true
    }
    func recent(at date: Date = Date()) -> [CaptionHistoryEntry] {
        entries.filter { $0.lastSeen >= date.addingTimeInterval(-30) && $0.firstSeen <= date }
    }
    func context(before id: String) -> [TranslationPair] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return [] }
        return entries[..<index].filter { !$0.chinese.isEmpty }.suffix(4).map { .init(english: $0.translatedSource.isEmpty ? $0.english : $0.translatedSource, chinese: $0.chinese) }
    }
}
