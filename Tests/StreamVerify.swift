import Foundation

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = request.value(forHTTPHeaderField: "X-Fixture") ?? "success"
        let status = ["quota", "limit"].contains(fixture) ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json", "Retry-After": "7"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture == "hang" { return }
        let payload: String
        switch fixture {
        case "quota": payload = #"{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"Private data must not be exposed"}}"#
        case "limit": payload = #"{"error":{"code":"rate_limit_exceeded"}}"#
        case "failed": payload = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"insufficient_quota\"}}}\n\n"
        case "truncated": payload = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"只有一半\"}\n\n"
        default:
            payload = ": heartbeat\r\nevent: ignored\r\ndata:{\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"细胞膜\"}\r\n\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"允许水通过。\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"
        }
        // Split even in the middle of UTF-8 characters, just like TCP packets.
        for byte in payload.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
actor Updates {
    var texts = [String]()
    func add(_ text: String) { texts.append(text) }
}
@main enum StreamVerify {
    static func main() async throws {
        var passed = [String]()
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); passed.append(name); print("PASS: \(name)") }
        for fixture in ["success", "quota", "limit", "failed", "truncated", "hang"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Fixture": fixture]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = GPTTranslator(key: "fake-key", model: "fixture", urlSession: session)
            let updates = Updates()
            let start = Date()
            do {
                let result = try await client.stream("Synthetic input only.", context: [], glossary: "") { await updates.add($0) }
                check(fixture == "success" && result == "细胞膜允许水通过。", "SSE supports fragmented UTF-8, CRLF, no-space, multiline and EOF")
                let texts = await updates.texts
                check(texts.first == "细胞膜", "partial Chinese is delivered before completion")
            } catch {
                guard let failure = error as? TranslationFailure else { fatalError("Unexpected failure: \(error)") }
                switch fixture {
                case "quota", "failed": check(failure.kind == .quota && !failure.retryable, "\(fixture): distinguish exhausted quota without exposing response text")
                case "limit": check(failure.kind == .rateLimit && failure.retryAfter == 7, "HTTP Retry-After is preserved")
                case "truncated": check(failure.kind == .incomplete, "unfinished stream cannot be mistaken for success")
                case "hang": check(failure.kind == .network && Date().timeIntervalSince(start) < 12, "total deadline cancels a silent connection")
                default: fatalError("Success fixture failed: \(failure)")
                }
            }
        }
        var finalOnly = TranslationStreamState()
        _ = try finalOnly.accept(#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"最终译文"}]}]}}"#, provider: .openai)
        let finalResult = try finalOnly.result()
        check(finalResult == "最终译文", "completion-only stream extracts final output")
        print("Stream simulations passed: \(passed.count). No real API requests.")
    }
}
