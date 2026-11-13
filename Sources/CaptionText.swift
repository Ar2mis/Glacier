import Foundation

enum CaptionText {
    // Keep the most recent words readable without growing the overlay indefinitely.
    static func tail(_ text: String, words: Int = 22) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).suffix(words).joined(separator: " ")
    }
}
