import Foundation
import NaturalLanguage

struct TranscriptSegment: Equatable, Sendable {
    let id: Int
    let text: String
}

// Ignore text present at attachment. Observe stable Wispr segments and emit only
// new complete sentences. Revisions of already displayed text are not replayed.
struct SentenceFeed {
    private var baseline = false
    private var consumed: [Int: String] = [:]
    private var previous: [Int: String] = [:]
    private var changedAt: [Int: Date] = [:]

    mutating func ingest(_ segments: [TranscriptSegment], now: Date = Date()) -> [String] {
        guard baseline else {
            baseline = true
            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var alreadyComplete = text
                if segment.id == segments.last?.id, let last = Self.sentences(text).last, !Self.endsSentence(last),
                   let range = text.range(of: last, options: .backwards) {
                    alreadyComplete = String(text[..<range.lowerBound])
                }
                consumed[segment.id] = alreadyComplete; previous[segment.id] = text; changedAt[segment.id] = now
            }
            return []
        }
        var output: [String] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if previous[segment.id] != text {
                previous[segment.id] = text; changedAt[segment.id] = now
                continue
            }
            let stableFor = now.timeIntervalSince(changedAt[segment.id] ?? now)
            guard stableFor >= 0.8 else { continue }
            let prior = consumed[segment.id] ?? ""
            guard text != prior else { continue }
            // Wispr may revise earlier words; align by completed sentence count
            // instead of appending revised words to an already delivered sentence.
            let pending: String
            if text.hasPrefix(prior) { pending = String(text.dropFirst(prior.count)) }
            else if !prior.isEmpty {
                let oldSentences = Self.sentences(prior)
                let newSentences = Self.sentences(text)
                pending = newSentences.dropFirst(oldSentences.count).joined(separator: " ")
            } else { pending = text }
            let pieces = Self.sentences(pending)
            var sent = [String]()
            for (index, piece) in pieces.enumerated() {
                let hasEnd = Self.endsSentence(piece)
                // The next Wispr segment confirms the previous segment's boundary.
                let segmentClosed = segment.id != segments.last?.id
                if index < pieces.count - 1 || hasEnd || segmentClosed {
                    sent.append(piece)
                }
            }
            guard !sent.isEmpty else { continue }
            output += sent
            if sent.count == pieces.count { consumed[segment.id] = text }
            else if let last = sent.last, let end = text.range(of: last, options: .backwards)?.upperBound {
                consumed[segment.id] = String(text[..<end])
            }
        }
        let floor = (segments.first?.id ?? 0) - 2
        consumed = consumed.filter { $0.key >= floor }
        previous = previous.filter { $0.key >= floor }
        changedAt = changedAt.filter { $0.key >= floor }
        return output
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.range(of: "[.!?。！？][\\\"'’”)]*$", options: .regularExpression) != nil
    }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english); tokenizer.string = text
        var result = [String]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }
}
