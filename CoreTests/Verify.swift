import Foundation
import GlacierCore
import WhisperKit

final class RefinerMock: URLProtocol, @unchecked Sendable {
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-not-a-key")
        precondition(request.httpMethod == "POST")
        let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let data = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"english\":\"Cells use osmosis.\",\"chinese\":\"细胞利用渗透作用。\"}"}]}]}"#.utf8)
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum CoreVerify {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--whisper-audio" {
            let pipe = try await WhisperKit(WhisperKitConfig(model: WhisperModel.base.rawValue, verbose: false, prewarm: true, load: true))
            let result = try await pipe.transcribe(audioPath: CommandLine.arguments[2], decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true))
            let text = result.map(\.text).joined(separator: " ")
            precondition(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            print("WhisperKit Base smoke transcript: \(text)")
            return
        }
        let glossary = CourseVocabulary.normalize("\nBIOG 1440\n  osmosis = 渗透  \nBIOG 1440\nOSMOSIS = 渗透\nProf. Levine\n")
        precondition(glossary == "BIOG 1440\nosmosis = 渗透\nProf. Levine")
        precondition(CourseVocabulary.normalize(String(repeating: "词", count: 4001)).isEmpty)
        let pairs = (0..<8).map { BilingualCaption(english: "E\($0)", chinese: "中\($0)") }
        let body = try TranscriptRefiner.requestBody(text: "um cells like these use os Moses", glossary: glossary, context: pairs, model: "gpt-4o-mini")
        precondition(body["store"] as? Bool == false)
        let input = try JSONSerialization.jsonObject(with: Data((body["input"] as! String).utf8)) as! [String: Any]
        precondition((input["previous_captions"] as! [[String: String]]).count == 4)
        precondition(input["transcript"] as? String == "um cells like these use os Moses", "Keep raw source intact; let the prompt distinguish meaningful like")
        precondition((body["instructions"] as! String).contains("negations"))
        let mini = try TranscriptRefiner.requestBody(text: "x", glossary: "", context: [], model: "gpt-5-mini")
        precondition((mini["reasoning"] as? [String: String])?["effort"] == "minimal")
        func response(_ english: String, _ chinese: String, status: String = "completed") throws -> Data {
            let caption = try JSONEncoder().encode(BilingualCaption(english: english, chinese: chinese))
            return try JSONSerialization.data(withJSONObject: ["status": status, "output": [["type": "message", "content": [["type": "output_text", "text": String(data: caption, encoding: .utf8)!]]]]])
        }
        let caption = try TranscriptRefiner.parse(response("Cells like these use osmosis.", "这些细胞利用渗透作用。"), status: 200)
        precondition(caption.english.contains("like") && caption.chinese.contains("渗透"))
        let filler = try TranscriptRefiner.parse(response("", ""), status: 200)
        precondition(filler.english.isEmpty && filler.chinese.isEmpty)
        for invalid in [try response("x", ""), try response("x", "中", status: "incomplete"), Data("{}".utf8)] {
            do { _ = try TranscriptRefiner.parse(invalid, status: 200); preconditionFailure("Invalid response accepted") } catch {}
        }
        do { _ = try TranscriptRefiner.parse(Data("secret provider message".utf8), status: 401); preconditionFailure("HTTP error accepted") }
        catch { precondition(!error.localizedDescription.contains("secret provider")) }
        var silence = UtteranceBuffer()
        for _ in 0..<72000 { precondition(silence.append(Array(repeating: 0, count: 1600)) == nil) }
        precondition(silence.samples.count <= 3200, "Two hours of silence must not accumulate PCM")
        var speech = UtteranceBuffer(maxSeconds: 3)
        var closed = [[Float]]()
        for _ in 0..<90 { if let chunk = speech.append(Array(repeating: 0.2, count: 1600)) { closed.append(chunk) } }
        precondition(closed.count == 3 && closed.allSatisfy { $0.count == 48000 })
        _ = speech.append(Array(repeating: 0.2, count: 1600))
        for _ in 0..<6 { precondition(speech.append(Array(repeating: 0, count: 1600)) == nil) }
        precondition(speech.append(Array(repeating: 0, count: 1600)) != nil, "Silence finalizes speech")
        let wav = AudioEncoding.wav([0, 1, -1, .nan])
        precondition(wav.count == 52 && String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        precondition(Array(wav.suffix(8)) == [0, 0, 255, 127, 1, 128, 0, 0])
        let interim = try CloudASRParser.deepgram(Data(#"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"Cells"}]}}"#.utf8), id: 8)
        let final = try CloudASRParser.deepgram(Data(#"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"Cells divide."}]}}"#.utf8), id: 8)
        precondition(interim?.id == final?.id && interim?.isFinal == false && final?.isFinal == true)
        precondition(WhisperModel.base.rawValue == "openai_whisper-base")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefinerMock.self]
        let session = URLSession(configuration: config)
        let refined = try await TranscriptRefiner(key: "test-not-a-key", session: session).refine("um cells use os Moses", glossary: "osmosis = 渗透")
        precondition(RefinerMock.requests == 1, "Both languages must come from a single HTTP request")
        precondition(refined == BilingualCaption(english: "Cells use osmosis.", chinese: "细胞利用渗透作用。"))
        session.invalidateAndCancel()
        print("PASS: glossary, bounded context, bilingual schema/errors, non-destructive prompt, bounded PCM, silence boundaries, WAV and cloud partial/final parsing")
        print("No microphone, model downloads, or live API calls were used.")
    }
}
