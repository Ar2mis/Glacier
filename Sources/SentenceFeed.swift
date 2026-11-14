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

    // Helper: Split a string into pieces no longer than maxLen, at whitespace.
    static func boundSplits(_ text: String, maxLen: Int) -> [String] {
        guard text.count > maxLen else { return [text] }
        var result = [String]()
        var start = text.startIndex
        let maxLen = max(20, maxLen)
        while start < text.endIndex {
            var end = start
            var i = 0
            var lastWhite: String.Index? = nil
            while end < text.endIndex && i < maxLen {
                if text[end].isWhitespace { lastWhite = end }
                i += 1
                end = text.index(after: end)
            }
            var split = end
            if end != text.endIndex, let ws = lastWhite, ws > start {
                split = text.index(after: ws)
            }
            result.append(String(text[start..<split]))
            start = split
        }
        return result
    }

    static func sentences(_ text: String) -> [String] {
        // First, try to use NLTokenizer for base tokens
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english); tokenizer.string = text
        var result = [String]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                if sentence.count > 240 {
                    result.append(contentsOf: boundSplits(sentence, maxLen: 240))
                } else {
                    result.append(sentence)
                }
            }
            return true
        }
        if result.count <= 1 {
            // fallback to custom splitting if only 1 found
            return customSentences(text)
        }
        // Merge tokens if the split occurs after abbreviations or decimals
        result = mergeSentenceSplits(result)
        return result
    }
    // Merge sentence splits broken by abbreviations and decimals
    private static func mergeSentenceSplits(_ candidate: [String]) -> [String] {
        let abbreviations: Set<String> = [
            "e.g.", "i.e.", "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Ph.D.", "Inc.", "Jr.", "Sr.", "vs.", "etc.", "Fig.", "Eq.", "St.", "No.", "Co.", "Ltd.", "Jan.", "Feb.", "Mar.", "Apr.", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec."
        ]
        var merged: [String] = []
        var i = 0
        while i < candidate.count {
            var current = candidate[i]
            var skipMerge = false
            // Only merge if not last
            if i + 1 < candidate.count {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastWord = trimmed.components(separatedBy: .whitespaces).last ?? ""
                let lower = lastWord.lowercased()
                if abbreviations.contains(lastWord) || abbreviations.contains(lower.capitalized) {
                    // Merge with next
                    current = current + " " + candidate[i+1]
                    skipMerge = true
                    i += 1
                } else if let match = lastWord.range(of: "^([0-9]+)\\.$", options: .regularExpression), i + 1 < candidate.count {
                    // Number followed by a period but it's not an end. Could be numbered list, keep as is.
                } else {
                    // Check decimal like 3.14, don't split after 3.
                    let decCheck = trimmed.components(separatedBy: .whitespaces)
                    if decCheck.count >= 2 {
                        let a = decCheck[decCheck.count-2]
                        let b = decCheck.last!
                        if let _ = Double(a), b.first == ".", b.count > 1, (Double(a + b) != nil) {
                            current = current + " " + candidate[i+1] // Merge
                            skipMerge = true
                            i += 1
                        }
                    }
                }
            }
            merged.append(current)
            i += 1
        }
        return merged
    }
    // Fallback for rare overly-long single-segment with periods -- will apply stricter split
    private static func customSentences(_ text: String) -> [String] {
        // Use regex to produce splits on .!? except when preceded by abbreviations or decimal numbers
        let abbreviations = "(?:e\\.g\\.|i\\.e\\.|Dr\\.|Mr\\.|Mrs\\.|Ms\\.|Prof\\.|Ph\\.D\\.|Inc\\.|Jr\\.|Sr\\.|vs\\.|etc\\.|Fig\\.|Eq\\.|St\\.|No\\.|Co\\.|Ltd\\.|Jan\\.|Feb\\.|Mar\\.|Apr\\.|Jun\\.|Jul\\.|Aug\\.|Sep\\.|Oct\\.|Nov\\.|Dec\\.)"
        let pattern = "(?<!\\b" + abbreviations + ")(?<![0-9])([.!?])[ \\n\t\r\f]+(?=[A-Z0-9\\"]|$)"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let ns = text as NSString
        var last = 0
        var result = [String]()
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let r = NSRange(location: last, length: m.range.location + 1 - last)
            let part = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { result.append(part) }
            last = m.range.location + 2 // skip space
        }
        let rest = ns.substring(from: last).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        if result.isEmpty { return [text] }
        return result
    }
}
