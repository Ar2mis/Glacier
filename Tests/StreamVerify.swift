import Foundation

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = request.value(forHTTPHeaderField: "X-Fixture") ?? "success"
        let status = ["quota", "limit", "limit-date"].contains(fixture) ? 429 : 200
        let retryAfter = request.value(forHTTPHeaderField: "X-Retry-After") ?? "7"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json", "Retry-After": retryAfter])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture == "hang" { return }
        let payload: String
        switch fixture {
        case "quota": payload = #"{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"Private data must not be exposed"}}"#
        case "limit", "limit-date": payload = #"{"error":{"code":"rate_limit_exceeded"}}"#
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
        let reference = ISO8601DateFormatter().date(from: "1994-11-06T08:49:30Z")!
        check(TranslationFailure.retryDelay(" 120\t", now: reference) == 120 && TranslationFailure.retryDelay("0", now: reference) == 0, "Retry-After accepts nonnegative seconds and surrounding whitespace")
        for date in ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994"] {
            check(TranslationFailure.retryDelay(date, now: reference) == 7, "HTTP-date format produces a deterministic seven-second delay: \(date)")
        }
        check(TranslationFailure.retryDelay("Sun, 06 Nov 1994 08:49:29 GMT", now: reference) == 0, "past Retry-After dates never produce negative waits")
        for invalid: String? in [nil, "", "\t", "-1", "+7", "1.5", "1e3", "NaN", "inf", "tomorrow", "Sun, 31 Feb 1994 08:49:37 GMT", String(repeating: "9", count: 300)] {
            check(TranslationFailure.retryDelay(invalid, now: reference) == 0, "invalid Retry-After falls back safely: \(invalid?.prefix(30) ?? "nil")")
        }
        let futureWindow = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!
        check(TranslationFailure.retryDelay("Sunday, 06-Nov-94 08:49:37 GMT", now: futureWindow) == 0, "obsolete two-digit years beyond the fifty-year future window resolve into the past")
        let fiftyYears = ISO8601DateFormatter().date(from: "2076-11-17T12:00:00Z")!.timeIntervalSince(futureWindow)
        check(TranslationFailure.retryDelay("Tuesday, 17-Nov-76 12:00:00 GMT", now: futureWindow) == fiftyYears &&
              TranslationFailure.retryDelay("Tuesday, 17-Nov-76 12:00:01 GMT", now: futureWindow) == 0,
              "two-digit year interpretation includes exactly fifty future years but not one second beyond")
        for provider in AIProvider.allCases {
            for streaming in [false, true] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [FixtureProtocol.self]
                configuration.httpAdditionalHeaders = ["X-Fixture": "limit-date", "X-Retry-After": formatter.string(from: Date().addingTimeInterval(120))]
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let client = GPTTranslator(key: "fake-key", model: "fixture", urlSession: session, provider: provider)
                do {
                    if streaming { _ = try await client.stream("Synthetic input.", context: [], glossary: "") { _ in } }
                    else { _ = try await client.translate("Synthetic input.", context: [], glossary: "") }
                    fatalError("Rate-limit response was accepted")
                } catch let failure as TranslationFailure {
                    check(failure.kind == .rateLimit && failure.retryAfter > 110 && failure.retryAfter <= 120,
                          "\(provider.rawValue) \(streaming ? "stream" : "complete") preserves HTTP-date Retry-After")
                }
            }
        }
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
        // Regression: Oversized SSE stream is rejected with a sanitized, typed error
        // Use a synthetic URLSession that delivers a [DONE] after overflowing
        class LongLineURLProtocol: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                // Stream 3400 CJK chars in approx 400-byte packets, then send [DONE]
                let chunk = "汉".data(using: .utf8)!  // One char, but three bytes
                for _ in 0..<3400 {
                    client?.urlProtocol(self, didLoad: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"汉\"}\n".data(using: .utf8)!)
                }
                client?.urlProtocol(self, didLoad: "data: [DONE]\n\n".data(using: .utf8)!)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let longcfg = URLSessionConfiguration.ephemeral
        longcfg.protocolClasses = [LongLineURLProtocol.self]
        let session = URLSession(configuration: longcfg)
        defer { session.invalidateAndCancel() }
        let gpt = GPTTranslator(key: "fake-key", model: "ignore", urlSession: session)
        let collector = Updates()
        var gotError = false
        do {
            _ = try await gpt.stream("Test SSE oversized.", context: [], glossary: "") { await collector.add($0) }
        } catch let error as TranslationFailure {
            gotError = true
            // The error must be incomplete, sanitized, never echoing text content
            check(error.kind == .incomplete && error.message.contains("内容超出预期大小"), "Oversize SSE stream throws typed/sanitized size error")
        }
        check(gotError, "Oversize SSE stream forcibly failed")
        var finalOnly = TranslationStreamState()
        _ = try finalOnly.accept(#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"最终译文"}]}]}}"#, provider: .openai)
        let finalResult = try finalOnly.result()
        check(finalResult == "最终译文", "completion-only stream extracts final output")
        print("Stream simulations passed: \(passed.count). No real API requests.")
    }
}
