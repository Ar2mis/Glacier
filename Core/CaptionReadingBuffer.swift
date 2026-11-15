import Foundation

public struct ReadingCaption: Equatable, Sendable {
    public let id: String
    public let source: String
    public let english: String
    public let chinese: String
    public let complete: Bool
    public init(id: String, source: String, english: String, chinese: String, complete: Bool) {
        self.id = id; self.source = source; self.english = english; self.chinese = chinese; self.complete = complete
    }
}

/// Separate reading pace from recognition/translation pace. History retains all
/// results; the screen coalesces revisions and keeps a bounded, recent queue.
public struct CaptionReadingBuffer {
    public private(set) var current: ReadingCaption?
    public private(set) var pending: [ReadingCaption] = []
    private var holdUntil = Date.distantPast
    public init() {}
    @discardableResult
    public mutating func submit(_ caption: ReadingCaption, now: Date = Date(), hold: TimeInterval, live: Bool = false) -> ReadingCaption? {
        guard !caption.chinese.isEmpty else { return nil }
        if current == nil { return display(caption, now: now, hold: hold) }
        if let current, current.id == caption.id && current.source == caption.source {
            if current.complete && !caption.complete { return nil }
            self.current = caption
            if caption.complete && !current.complete { holdUntil = now.addingTimeInterval(max(2, hold)) }
            return caption
        }
        // Live mode follows ready translation deltas, never an artificial dwell
        // queue. Keep the old pair until a useful new Chinese fragment exists.
        if live {
            guard caption.complete || caption.chinese.count >= 4 else { return nil }
            pending.removeAll()
            return display(caption, now: now, hold: hold)
        }
        // A finished pair stays readable while the next pair streams in.
        // Keep only the newest source revision for each utterance/sentence.
        if let index = pending.firstIndex(where: { $0.id == caption.id }) { pending[index] = caption }
        else { pending.append(caption) }
        if pending.count > 3 { pending.removeFirst(pending.count - 3) }
        return advance(now: now, hold: hold)
    }
    public mutating func advance(now: Date = Date(), hold: TimeInterval) -> ReadingCaption? {
        guard now >= holdUntil, let index = pending.firstIndex(where: \.complete) else { return nil }
        let next = pending[index]
        pending.removeFirst(index + 1)
        return display(next, now: now, hold: hold)
    }
    private mutating func display(_ caption: ReadingCaption, now: Date, hold: TimeInterval) -> ReadingCaption {
        current = caption
        holdUntil = now.addingTimeInterval(max(2, min(12, hold)))
        return caption
    }
}

/// Translate a stable prefix before Whisper's final silence boundary. Unstable
/// last words stay out of translation; the raw full hypothesis is still journaled.
public struct StableCaptionPrefix {
    private var id: Int?
    private var previous: [String] = []
    private var emitted = ""
    public init() {}
    public mutating func observe(_ event: TranscriptEvent) -> String? {
        if id != event.id { id = event.id; previous = []; emitted = "" }
        let words = event.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        defer { previous = words }
        if event.isFinal { emitted = event.text; return event.text }
        let common = zip(previous, words).prefix(while: { $0.0 == $0.1 }).count
        let count = max(0, common - 1)
        guard count >= 3 else { return nil }
        let stable = words.prefix(count).joined(separator: " ")
        guard stable != emitted, stable.count >= emitted.count + 6 else { return nil }
        emitted = stable; return stable
    }
}
