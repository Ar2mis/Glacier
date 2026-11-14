import Foundation
import GlacierCore

func verifyReadingPace() {
    let start = Date(timeIntervalSince1970: 100)
    func pair(_ id: String, _ source: String, complete: Bool = true) -> ReadingCaption {
        .init(id: id, source: source, english: source, chinese: "译文" + source, complete: complete)
    }
    var reader = CaptionReadingBuffer()
    precondition(reader.submit(pair("1", "First sentence"), now: start, hold: 5) != nil)
    precondition(reader.submit(pair("2", "Second sentence"), now: start.addingTimeInterval(0.2), hold: 5) == nil)
    precondition(reader.current?.id == "1")
    precondition(reader.advance(now: start.addingTimeInterval(4.99), hold: 5) == nil)
    precondition(reader.advance(now: start.addingTimeInterval(5), hold: 5)?.id == "2")
    precondition(reader.advance(now: start.addingTimeInterval(100), hold: 5) == nil)
    precondition(reader.current?.id == "2", "A finished pair must not expire into a blank")
    for i in 3...12 { _ = reader.submit(pair("\(i)", "Sentence \(i)"), now: start.addingTimeInterval(5.1), hold: 5) }
    precondition(reader.pending.count == 3)
    _ = reader.submit(pair("12", "Corrected sentence"), now: start.addingTimeInterval(5.2), hold: 5)
    precondition(reader.pending.count == 3 && reader.pending.last?.source == "Corrected sentence")
    var stable = StableCaptionPrefix()
    precondition(stable.observe(.init(id: 0, text: "The cell membrane lets water move", isFinal: false)) == nil)
    precondition(stable.observe(.init(id: 0, text: "The cell membrane lets water move through channels", isFinal: false)) == "The cell membrane lets water")
    precondition(stable.observe(.init(id: 0, text: "The membrane is selectively permeable.", isFinal: true)) == "The membrane is selectively permeable.")
    precondition(stable.observe(.init(id: 1, text: "A new utterance must earn stability again", isFinal: false)) == nil)
    print("PASS: minimum readable dwell, no blank expiry, bounded/coalesced presentation queue and early stable-prefix translation")
}
