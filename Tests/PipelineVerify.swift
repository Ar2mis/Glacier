import Foundation

final class MockOpenAI: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "api.openai.com")
        precondition(request.url?.path == "/v1/responses")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-a-secret")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"该政策降低了失业率。"}]}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MockCompatible: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(["api.deepseek.com", "generativelanguage.googleapis.com"].contains(request.url!.host!))
        precondition(request.url!.path.hasSuffix("/chat/completions"))
        let streaming = request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        let json = #"{"choices":[{"finish_reason":"stop","message":{"content":"政策有效。"}}]}"#
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"政策\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"有效。\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((streaming ? sse : json).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct PipelineVerify {
    static func main() async throws {
        var feed = SentenceFeed()
        let start = Date(timeIntervalSince1970: 0)
        func segments(_ new: String) -> [TranscriptSegment] {
            [.init(id: 1, text: "Earlier lecture content."), .init(id: 2, text: new)]
        }
        precondition(feed.ingest([.init(id: 1, text: "Earlier lecture content.")], now: start).isEmpty)
        precondition(feed.ingest(segments("The policy reduced unemployment."), now: start.addingTimeInterval(1)).isEmpty)
        precondition(feed.ingest(segments("The policy reduced unemployment."), now: start.addingTimeInterval(2)) == ["The policy reduced unemployment."])
        precondition(feed.ingest(segments("The policy reduced unemployment."), now: start.addingTimeInterval(3)).isEmpty)
        precondition(feed.ingest(segments("The policy reduced unemployment. It took two years."), now: start.addingTimeInterval(4)).isEmpty)
        precondition(feed.ingest(segments("The policy reduced unemployment. It took two years."), now: start.addingTimeInterval(5)) == ["It took two years."])
        precondition(feed.ingest(segments("The policy increased unemployment. It took two years."), now: start.addingTimeInterval(6)).isEmpty)
        precondition(feed.ingest(segments("The policy increased unemployment. It took two years."), now: start.addingTimeInterval(7)).isEmpty)
        let next = segments("The policy increased unemployment. It took two years.") + [.init(id: 3, text: "Next unfinished phrase")]
        precondition(feed.ingest(next, now: start.addingTimeInterval(8)).isEmpty)
        precondition(feed.ingest(next, now: start.addingTimeInterval(9)).isEmpty)
        precondition(feed.ingest(next, now: start.addingTimeInterval(12)).isEmpty)
        precondition(feed.ingest(next, now: start.addingTimeInterval(13)).isEmpty)
        let closed = next + [.init(id: 4, text: "Another segment.")]
        precondition(feed.ingest(closed, now: start.addingTimeInterval(14)) == ["Next unfinished phrase"])
        var midSentence = SentenceFeed()
        precondition(midSentence.ingest([.init(id: 1, text: "The program")], now: start).isEmpty)
        precondition(midSentence.ingest([.init(id: 1, text: "The program works.")], now: start.addingTimeInterval(1)).isEmpty)
        precondition(midSentence.ingest([.init(id: 1, text: "The program works.")], now: start.addingTimeInterval(2)) == ["The program works."])

        // Test SentenceFeed.boundSplits directly.
        let longNoWS = String(repeating: "A", count: 500)
        let segs = SentenceFeed.boundSplits(longNoWS, maxLen: 200)
        precondition(segs.count == 3 && segs.joined() == longNoWS && segs.allSatisfy { $0.count <= 200 })

        let longWithSpaces = String((0..<10).map { _ in "长句だらけの テストです " }.joined())
        let splitSpaces = SentenceFeed.boundSplits(longWithSpaces, maxLen: 30)
        precondition(splitSpaces.allSatisfy { $0.count <= 30 })
        precondition(splitSpaces.joined() == longWithSpaces)
        // Should split at whitespace but never drop or change chars even with Unicode
        let longUnicode = "苹果🍏 和 香蕉🍌 之间并没有🍅这些符号的意义 "
        let repeated = String(repeating: longUnicode, count: 15)
        let unicodeSplit = SentenceFeed.boundSplits(repeated, maxLen: 80)
        precondition(unicodeSplit.joined() == repeated)
        precondition(unicodeSplit.allSatisfy { $0.count <= 80 })

        // Test sentences covers absurd length, Unicode, and whitespace grouping
        let crazy = String(repeating: "单词 word ", count: 100) + "noPunctuationSegmentJustUnicodeAndWhitespace " + String(repeating: "測試", count: 80)
        let many = SentenceFeed.sentences(crazy)
        precondition(many.joined() == crazy.trimmingCharacters(in: .whitespacesAndNewlines))
        precondition(many.allSatisfy { $0.count <= 240 })
        // Should split long unpunctuated segment at whitespace, not drop source

        // --- DI-04: Academic abbreviation and decimal regression cases ---
        let abbr1 = "This is an example, e.g. it is clear. That follows."
        let abbrSplit = SentenceFeed.sentences(abbr1)
        precondition(abbrSplit.count == 2, "Should keep e.g. together: \(abbrSplit)")
        precondition(abbrSplit[0].contains("e.g. it is clear."))
        precondition(abbrSplit[1] == "That follows.")

        let abbr2 = "He got his Ph.D. in 2010. Now he teaches."
        let abbrSplit2 = SentenceFeed.sentences(abbr2)
        precondition(abbrSplit2.count == 2)
        precondition(abbrSplit2[0].contains("Ph.D. in 2010."))

        let abbr3 = "Dr. Smith will present at 3 p.m. She will discuss the result."
        let abbrSplit3 = SentenceFeed.sentences(abbr3)
        precondition(abbrSplit3.count == 2)
        precondition(abbrSplit3[0].contains("3 p.m."))
        precondition(abbrSplit3[1].hasPrefix("She will"))

        let abbr4 = "A chemical, i.e. NaCl, dissolves easily. Next topic."
        let abbrSplit4 = SentenceFeed.sentences(abbr4)
        precondition(abbrSplit4.count == 2)
        precondition(abbrSplit4[0].contains("i.e. NaCl, dissolves easily."))

        let dec1 = "The average was 3.14. The next value was higher."
        let decSplit = SentenceFeed.sentences(dec1)
        precondition(decSplit.count == 2)
        precondition(decSplit[0].contains("3.14."))
        precondition(decSplit[1].hasPrefix("The next"))

        let dec2 = "The distance is 12.7 mm. Dr. A. B. Jones measured it."
        let decSplit2 = SentenceFeed.sentences(dec2)
        precondition(decSplit2.count == 2)
        precondition(decSplit2[0].contains("12.7 mm."))
        precondition(decSplit2[1].hasPrefix("Dr."))
        // Ensure that splitting does not occur on decimal points

        let dec3 = "This number is 1. He called it a test."
        let decSplit3 = SentenceFeed.sentences(dec3)
        precondition(decSplit3.count == 2)
        precondition(decSplit3[0].contains("is 1."))
        precondition(decSplit3[1].hasPrefix("He called"))

        let abbr5 = "We reference Eq. 2 in the text. It follows."
        let abbrSplit5 = SentenceFeed.sentences(abbr5)
        precondition(abbrSplit5.count == 2)
        precondition(abbrSplit5[0].contains("Eq. 2"))

        // Real-world complex abbreviation and decimal mix
        let complex = "Dr. Smith measured 1.23. Then, he compared it to 2.12 and 3.44. Next, see Fig. 2."
        let complexSplit = SentenceFeed.sentences(complex)
        precondition(complexSplit.count == 3)
        precondition(complexSplit[0].contains("1.23."))
        precondition(complexSplit[1].contains("2.12 and 3.44."))
        precondition(complexSplit[2].contains("Fig. 2."))

        print("PASS: completed history skipped; stable sentences delivered once; appends, revisions, partial attachment and segment boundaries handled; bounded and Unicode/whitespace splits tested. Academic abbreviation/decimal split regression passed.")

        let pairs = (0..<8).map { TranslationPair(english: "Sentence \($0)", chinese: "句子 \($0)") }
        let body = GPTTranslator.requestBody(sentence: "Current sentence.", context: pairs, glossary: "policy = 政策", model: "gpt-4.1")
        precondition(body["store"] as? Bool == false)
        let input = try JSONSerialization.jsonObject(with: Data((body["input"] as! String).utf8)) as! [String: Any]
        precondition((input["previous_sentences"] as! [[String: String]]).count == 4)
        precondition(input["current_sentence"] as? String == "Current sentence.")
        for code in [401, 403, 404, 429, 500] {
            do { _ = try GPTTranslator.parse(Data(), statusCode: code); fatalError("HTTP failure was accepted") }
            catch {}
        }
        for response in [#"{"status":"incomplete","output":[]}"#, #"{"status":"completed","output":[]}"#] {
            do { _ = try GPTTranslator.parse(Data(response.utf8), statusCode: 200); fatalError("Invalid response accepted") }
            catch {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOpenAI.self]
        let session = URLSession(configuration: configuration)
        let translated = try await GPTTranslator(key: "test-key-not-a-secret", model: "gpt-4.1", urlSession: session)
            .translate("The policy reduced unemployment.", context: [], glossary: "")
        precondition(translated == "该政策降低了失业率。")
        for provider in [AIProvider.gemini, .deepseek] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockCompatible.self]
            let mockSession = URLSession(configuration: config)
            let client = GPTTranslator(key: "test", model: provider.defaultModel, urlSession: mockSession, provider: provider)
            let httpResult = try await client.translate("It works.", context: [], glossary: "")
            precondition(httpResult == "政策有效。")
            let streamed = try await client.stream("It works.", context: [], glossary: "") { _ in }
            precondition(streamed == "政策有效。")
            mockSession.invalidateAndCancel()
            let adapted = client.adapt(body)
            precondition(adapted["store"] == nil)
            precondition((adapted["messages"] as? [[String: String]])?.count == 2)
            precondition(adapted["model"] as? String == provider.defaultModel)
            let response = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"政策有效。"}}]}"#.utf8)
            let result = try client.parseResult(response, statusCode: 200)
            precondition(result == "政策有效。")
            for reason in ["length", "content_filter"] {
                let invalid = Data("{\"choices\":[{\"finish_reason\":\"\(reason)\",\"message\":{\"content\":\"partial\"}}]}".utf8)
                do { _ = try client.parseResult(invalid, statusCode: 200); fatalError("Truncated content accepted") } catch {}
            }
        }
        session.invalidateAndCancel()
        print("PASS: bounded context, store=false, GPT response parsing, HTTP errors and mocked HTTP request")
        print("No live API requests were made.")
    }
}
