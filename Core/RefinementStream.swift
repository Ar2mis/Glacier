import Foundation

/// Bounded Responses SSE decoder. Provisional pairs are display-only; only a
/// validated response.completed may be saved as a completed translation.
public struct RefinementStream {
    private var fields: [String] = []
    private var fieldBytes = 0
    private var text = ""
    private var completed: BilingualCaption?
    private let source: String
    public init(source: String = "") { self.source = source }
    public var isComplete: Bool { completed != nil }
    public mutating func line(_ line: String) throws -> BilingualCaption? {
        if line.isEmpty { return try flush() }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        fieldBytes += value.utf8.count
        guard fieldBytes <= 65536 else { throw GlacierCoreError.message("Cleanup event exceeded the size limit.") }
        fields.append(value)
        return nil
    }
    public mutating func flush() throws -> BilingualCaption? {
        guard !fields.isEmpty else { return nil }
        let payload = fields.joined(separator: "\n")
        fields.removeAll(keepingCapacity: true); fieldBytes = 0
        if payload == "[DONE]" { return nil }
        guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw GlacierCoreError.message("Invalid cleanup event.")
        }
        switch event["type"] as? String {
        case "response.output_text.delta":
            guard completed == nil else { return nil }
            text += event["delta"] as? String ?? ""
            guard text.utf8.count <= 32768 else { throw GlacierCoreError.message("Cleanup text exceeded the size limit.") }
            return Self.partial(text, source: source)
        case "response.completed":
            guard let response = event["response"] as? [String: Any] else { throw GlacierCoreError.message("Missing completed cleanup response.") }
            completed = try TranscriptRefiner.parse(JSONSerialization.data(withJSONObject: response), status: 200)
            return completed
        case "error", "response.failed", "response.incomplete", "response.refusal.delta":
            throw GlacierCoreError.message("Cleanup stream did not complete; raw English is retained.")
        default: return nil
        }
    }
    public func result() throws -> BilingualCaption {
        guard let completed else { throw GlacierCoreError.message("Cleanup stream ended early; raw English is retained.") }
        return completed
    }
    /// Decode only string values, honoring quotes/escapes. Never display raw JSON
    /// or guess half of a Unicode escape. If Chinese arrives first, use the raw
    /// ASR source until the complete cleaned English field becomes available.
    public static func partial(_ json: String, source: String = "") -> BilingualCaption? {
        let chars = Array(json)
        var index = 0, values: [String: String] = [:]
        func whitespace() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
        func string(allowOpen: Bool) -> (String, Bool)? {
            guard index < chars.count, chars[index] == "\"" else { return nil }
            let start = index; index += 1
            while index < chars.count {
                if chars[index] == "\\" { index += 2; continue }
                if chars[index] == "\"" {
                    index += 1
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(String(chars[start..<index]).utf8)) else { return nil }
                    return (value, true)
                }
                index += 1
            }
            guard allowOpen, let value = try? JSONDecoder().decode(String.self, from: Data((String(chars[start...]) + "\"").utf8)) else { return nil }
            return (value, false)
        }
        whitespace()
        guard index < chars.count, chars[index] == "{" else { return nil }; index += 1
        for _ in 0..<2 {
            whitespace()
            guard let (key, _) = string(allowOpen: false), ["english", "chinese"].contains(key), values[key] == nil else { break }
            whitespace(); guard index < chars.count, chars[index] == ":" else { break }; index += 1; whitespace()
            guard let (value, closed) = string(allowOpen: key == "chinese") else { break }
            values[key] = value
            if !closed { break }
            whitespace(); guard index < chars.count, chars[index] == "," else { break }; index += 1
        }
        let english = values["english"] ?? source
        guard !english.isEmpty, let chinese = values["chinese"], !chinese.isEmpty,
              english.count <= 4000, chinese.count <= 4000 else { return nil }
        return .init(english: english, chinese: chinese)
    }
}
