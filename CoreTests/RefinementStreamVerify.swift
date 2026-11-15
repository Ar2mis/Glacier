import Foundation
import GlacierCore

func verifyRefinementStream() throws {
    var stream = RefinementStream()
    func payload(_ object: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    func delta(_ text: String) throws -> BilingualCaption? {
        _ = try stream.line("data: " + payload(["type": "response.output_text.delta", "delta": text]))
        return try stream.line("")
    }
    let first = try delta(#"{"english":"Cells divide.","chinese":"细胞"#)
    precondition(first == .init(english: "Cells divide.", chinese: "细胞"))
    let next = try delta(#"会分裂。"}"#)
    precondition(next?.chinese == "细胞会分裂。")
    do { _ = try stream.result(); preconditionFailure("A syntactically complete partial is not a completed response") } catch {}
    let response: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": #"{"english":"Cells divide.","chinese":"细胞会分裂。"}"#]]]]]
    _ = try stream.line("data:" + payload(["type": "response.completed", "response": response]))
    _ = try stream.flush()
    let final = try stream.result()
    precondition(final.chinese == "细胞会分裂。")
    precondition(RefinementStream.partial(#"{"english":"The \"cell\".","chinese":"细胞\n"#)?.english == "The \"cell\".")
    precondition(RefinementStream.partial(#"{"english":"Cell.","chinese":"\u7ec6\u80"#) == nil, "Half Unicode escapes must not appear on screen")
    precondition(RefinementStream.partial(#"{"english":"Cell.","chinese":"\u7ec6\u80de"#)?.chinese == "细胞")
    precondition(RefinementStream.partial(#"{"english":"unfinished"#) == nil)
    precondition(RefinementStream.partial(#"{"chinese":"先到的中文"#, source: "Original ASR").map(\.english) == "Original ASR", "JSON property order must not delay first Chinese")
    var failed = RefinementStream()
    _ = try failed.line("data: " + payload(["type": "response.failed"]))
    do { _ = try failed.flush(); preconditionFailure("Failed stream accepted") } catch {}
    var oversized = RefinementStream()
    do { _ = try oversized.line("data: " + String(repeating: "x", count: 65537)); preconditionFailure("Unbounded event accepted") } catch {}
    print("PASS: bilingual deltas before completion, escaped/Unicode JSON, incomplete/error rejection and bounded SSE")
}
