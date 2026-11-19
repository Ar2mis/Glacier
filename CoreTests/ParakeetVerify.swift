import Foundation
import GlacierCore

private actor EouFixture {
    var frames: [[Float]] = [], results: [TranscriptEvent] = []
    var count = 0, finishes = 0, resets = 0
    let endpoint: Int
    init(endpoint: Int = 3) { self.endpoint = endpoint }
    func push(_ samples: [Float]) -> ParakeetSnapshot {
        frames.append(samples); count += 1
        return .init(text: "words \(count)", ended: count >= endpoint)
    }
    func finish() -> String { finishes += 1; return "final \(count)" }
    func reset() { resets += 1; count = 0 }
    func emit(_ event: TranscriptEvent) { results.append(event) }
}

func verifyParakeetStreaming() async throws {
    let fixture = EouFixture()
    let (audio, input) = AsyncThrowingStream<[Float], Error>.makeStream()
    let values: [Float] = Array(repeating: 0.1, count: 2 * 1280)
        + Array(repeating: 0, count: 3 * 1280) + Array(repeating: 0.2, count: 1280 + 7)
    input.yield(values); input.finish() // Stop with a partial final audio frame.
    try await ParakeetStreamProcessor.run(audio: audio, push: { await fixture.push($0) },
        finish: { await fixture.finish() }, reset: { await fixture.reset() }, emit: { await fixture.emit($0) })
    let frames = await fixture.frames, results = await fixture.results
    precondition(frames.flatMap { $0 } == values, "EOU in a large input frame must not drop or duplicate later audio")
    precondition(frames.allSatisfy { $0.count <= 1280 })
    precondition(results.filter(\.isFinal) == [.init(id: 0, text: "final 5", isFinal: true), .init(id: 1, text: "final 2", isFinal: true)])
    let finishes = await fixture.finishes
    precondition(finishes == 2, "Final tail is not emitted twice")

    let bounded = EouFixture(endpoint: .max)
    let (continuous, feed) = AsyncThrowingStream<[Float], Error>.makeStream()
    feed.yield(Array(repeating: 0.1, count: 9 * 1280)); feed.finish()
    try await ParakeetStreamProcessor.run(audio: continuous, maximumSegmentSamples: 4 * 1280,
        push: { await bounded.push($0) }, finish: { await bounded.finish() }, reset: { await bounded.reset() }, emit: { await bounded.emit($0) })
    let finals = await bounded.results.filter(\.isFinal)
    precondition(finals.map(\.id) == [0, 1, 2] && finals.map(\.text) == ["final 4", "final 4", "final 1"], "Speech without EOU must still bound token history")
    let delayed = EouFixture(endpoint: 1)
    let (talking, talkingInput) = AsyncThrowingStream<[Float], Error>.makeStream()
    talkingInput.yield(Array(repeating: 0.2, count: 5 * 1280)); talkingInput.finish()
    try await ParakeetStreamProcessor.run(audio: talking, push: { await delayed.push($0) },
        finish: { await delayed.finish() }, reset: { await delayed.reset() }, emit: { await delayed.emit($0) })
    let delayedFinals = await delayed.results.filter(\.isFinal)
    precondition(delayedFinals.count == 1 && delayedFinals[0].text == "final 5", "Delayed EOU during new speech must not reset or clip a word")

    let (silence, silentInput) = AsyncThrowingStream<[Float], Error>.makeStream()
    silentInput.yield([.nan, .infinity, -2, 2, 0]); silentInput.finish()
    try await ParakeetStreamProcessor.run(audio: silence, push: { samples in
        precondition(samples == [0, 0, -1, 1, 0]); return .init(text: "", ended: false)
    }, finish: { "" }, reset: {}, emit: { _ in preconditionFailure("Silence must not create a transcript") })

    let (failing, failureInput) = AsyncThrowingStream<[Float], Error>.makeStream()
    failureInput.finish(throwing: GlacierCoreError.message("microphone overflow"))
    do {
        try await ParakeetStreamProcessor.run(audio: failing, push: { _ in .init(text: "", ended: false) },
            finish: { preconditionFailure("Input failure is not successful Stop") }, reset: {}, emit: { _ in })
        preconditionFailure("Input errors must propagate")
    } catch { precondition(error.localizedDescription == "microphone overflow") }
    let cancelFixture = EouFixture()
    let (cancelAudio, cancelInput) = AsyncThrowingStream<[Float], Error>.makeStream()
    cancelInput.yield([0.1]); cancelInput.finish()
    let canceled = Task {
        try await ParakeetStreamProcessor.run(audio: cancelAudio, push: { samples in
            _ = await cancelFixture.push(samples)
            try await Task.sleep(for: .seconds(10))
            return .init(text: "stale words", ended: false)
        }, finish: { await cancelFixture.finish() }, reset: { await cancelFixture.reset() }, emit: { await cancelFixture.emit($0) })
    }
    while await cancelFixture.count == 0 { await Task.yield() }
    canceled.cancel()
    do { try await canceled.value; preconditionFailure("Cancellation must abort stale inference") } catch is CancellationError { }
    let canceledEvents = await cancelFixture.results, canceledFinals = await cancelFixture.finishes
    precondition(canceledEvents.isEmpty && canceledFinals == 0, "Canceled sessions must not publish or finalize late results")
    print("PASS: Parakeet EOU boundaries, lossless frame splitting, bounded continuous speech, Stop tail, silence and input failures")
    precondition(wordEdits(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"]) == 0)
    precondition(wordEdits(reference: ["a", "b", "c"], hypothesis: ["a", "x"]) == 2)
}
