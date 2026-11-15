import Foundation
import GlacierCore

func verifyWhisperStorage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlacierModelTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + WhisperModel.turbo.rawValue)
    precondition(WhisperModelStorage.cachedFolder(.turbo, root: root) == nil)
    let files = ["MelSpectrogram.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/coremldata.bin",
                 "AudioEncoder.mlmodelc/weights/weight.bin", "TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/weights/weight.bin"]
    for file in files.dropLast() {
        let url = folder.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
    }
    precondition(WhisperModelStorage.cachedFolder(.turbo, root: root) == nil, "Partial downloads must not bypass download completion")
    let last = folder.appendingPathComponent(files.last!)
    try FileManager.default.createDirectory(at: last.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1]).write(to: last)
    precondition(WhisperModelStorage.cachedFolder(.turbo, root: root)?.path == folder.path)
    precondition(WhisperModelStorage.cachedFolder(.base, root: root) == nil)
    print("PASS: complete local model lookup, partial-download rejection and model isolation")
}

private actor DecodeGate {
    var started = false, released = false
    var counts: [Int] = []
    func decode(_ samples: [Float]) async throws -> String {
        counts.append(samples.count); started = true
        while !released { try await Task.sleep(for: .milliseconds(2)) }
        return "samples \(samples.count)"
    }
    func release() { released = true }
}

func verifyWhisperCoalescing() async throws {
    let gate = DecodeGate()
    let (audio, input) = AsyncThrowingStream<[Float], Error>.makeStream()
    let consumer = Task { () throws -> [TranscriptEvent] in
        var result: [TranscriptEvent] = []
        try await WhisperStreamProcessor.run(audio: audio, decode: { try await gate.decode($0) }, emit: { result.append($0) })
        return result
    }
    input.yield(Array(repeating: 0.2, count: 12000))
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await gate.started) {
        precondition(ContinuousClock.now < deadline, "First 0.75-second partial must start before finalization")
        try await Task.sleep(for: .milliseconds(2))
    }
    for _ in 0..<7 { input.yield(Array(repeating: 0.2, count: 12000)) }
    input.finish()
    // Emulate a decoder busy while microphone frames continue arriving.
    try await Task.sleep(for: .milliseconds(100)); await gate.release()
    let events = try await consumer.value
    let counts = await gate.counts
    precondition(counts.first == 12000 && counts.last == 96000)
    precondition(counts.count <= 3, "Stale intermediate prefixes must not form a decode backlog")
    precondition(events.filter(\.isFinal) == [.init(id: 0, text: "samples 96000", isFinal: true)], "Coalescing may skip partials, never final audio")
    print("PASS: early partial decoding, concurrent audio ingestion, coalesced backlog and exact final tail")
}
