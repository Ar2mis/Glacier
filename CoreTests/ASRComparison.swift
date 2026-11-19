import Foundation
import CryptoKit
import GlacierCore
import WhisperKit

private struct ReplayEvent: Codable {
    let seconds: Double
    let id: Int
    let text: String
    let final: Bool
}

/// Callbacks may arrive on different executors; the report itself is never UI state.
private final class ReplayLog: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private var events: [ReplayEvent] = []
    func append(_ event: TranscriptEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(.init(seconds: ProcessInfo.processInfo.systemUptime - start,
                            id: event.id, text: event.text, final: event.isFinal))
    }
    func result() -> [ReplayEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

private func words(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
}

func wordEdits(reference: [String], hypothesis: [String]) -> Int {
    var row = Array(0...hypothesis.count)
    for (i, left) in reference.enumerated() {
        var next = [i + 1]
        for (j, right) in hypothesis.enumerated() {
            next.append(min(row[j] + (left == right ? 0 : 1), min(row[j + 1] + 1, next[j] + 1)))
        }
        row = next
    }
    return row.last!
}

/// Explicit opt-in: local model downloads and real-time-paced file inference.
/// Never reads the microphone or sends the recording to a cloud service.
func compareASR() async throws {
    func option(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    guard let path = option("--compare-asr"), let referencePath = option("--reference"), let reportPath = option("--report") else {
        throw GlacierCoreError.message("Usage: --compare-asr audio.wav --reference reference.txt --report report.json [--glossary terms.txt] [--only parakeet|base|turbo] [--parakeet-mode 160ms|320ms] [--no-previous-context]")
    }
    let pcm = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    guard !pcm.isEmpty, pcm.count <= 16_000 * 600 else { throw GlacierCoreError.message("Use a nonempty comparison clip of at most 10 minutes.") }
    let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
    let vocabulary = try option("--glossary").map { try String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
    let duration = Double(pcm.count) / 16000
    var rows = [[String: Any]]()
    let selected = option("--only")
    let previousContext = !CommandLine.arguments.contains("--no-previous-context")
    guard let parakeetMode = ParakeetMode(rawValue: option("--parakeet-mode") ?? "320ms") else { throw GlacierCoreError.message("Unknown Parakeet mode") }
    guard selected == nil || ["parakeet", "base", "turbo"].contains(selected!) else { throw GlacierCoreError.message("Unknown --only provider") }
    for name in ["parakeet", "base", "turbo"] where selected == nil || name == selected {
        print("Preparing \(name); models are local, downloads may take several minutes.")
        let prepareStart = ProcessInfo.processInfo.systemUptime
        let parakeet = ParakeetEngine(mode: parakeetMode), whisper = WhisperDecoder()
        if name == "parakeet" { try await parakeet.prepare() }
        else {
            await whisper.setVocabulary(vocabulary)
            try await whisper.prepare(model: name == "turbo" ? .turbo : .base)
        }
        let preparation = ProcessInfo.processInfo.systemUptime - prepareStart
        let (audio, input) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let log = ReplayLog(), clock = ContinuousClock()
        let began = clock.now
        let feed = Task {
            do {
                for offset in stride(from: 0, to: pcm.count, by: 1600) {
                    let end = min(pcm.count, offset + 1600)
                    // Feed only audio which would have arrived by this time. One
                    // identical PCM stream and cadence are used for every provider.
                    try await clock.sleep(until: began + .seconds(Double(end) / 16000))
                    if case .dropped = input.yield(Array(pcm[offset..<end])) {
                        throw GlacierCoreError.message("Replay consumer exceeded bounded audio backlog")
                    }
                }
                input.finish()
            } catch { input.finish(throwing: error) }
        }
        do {
            if name == "parakeet" { try await parakeet.run(audio: audio) { log.append($0) } }
            else {
                try await WhisperStreamProcessor.run(audio: audio, decode: { try await whisper.decode($0) },
                    completed: { if previousContext { await whisper.remember($0) } }, emit: { log.append($0) })
            }
        } catch { feed.cancel(); throw error }
        await feed.value
        let events = log.result(), elapsed = began.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let finals = events.filter(\.final)
        let transcript = finals.map(\.text).joined(separator: " ")
        guard !transcript.isEmpty else { throw GlacierCoreError.message("\(name) produced no finalized speech") }
        let ref = words(reference), edits = wordEdits(reference: ref, hypothesis: words(transcript))
        let encodedEvents = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events))
        let row: [String: Any] = ["provider": name, "model_preparation_seconds": preparation,
            "first_text_seconds_from_audio_start": events.first?.seconds as Any? ?? NSNull(),
            "first_final_seconds_from_audio_start": finals.first?.seconds as Any? ?? NSNull(),
            "stop_drain_seconds": max(0, seconds - duration), "reference_words": ref.count,
            "word_edits": edits, "word_error_rate": Double(edits) / Double(max(1, ref.count)),
            "finalized_segments": finals.count, "transcript": transcript, "events": encodedEvents]
        rows.append(row)
        let report: [String: Any] = ["schema": 1, "recorded_at": ISO8601DateFormatter().string(from: Date()),
            "audio_sha256": hash, "audio_seconds": duration, "reference": reference,
            "pace": "real time, 100ms PCM input frames", "microphone_used": false, "cloud_used": false,
            "fluid_audio_version": "0.18.3", "whisperkit_version": "1.1.1",
            "parakeet_model_revision": ParakeetEngine.modelRevision,
            "parakeet_chunk_mode": parakeetMode.rawValue,
            "whisper_previous_context": previousContext,
            "whisper_glossary": CourseVocabulary.normalize(vocabulary), "results": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        print("\(name): WER \(String(format: "%.1f", Double(edits) * 100 / Double(max(1, ref.count))))%, first text \(String(format: "%.3f", events.first!.seconds))s, Stop drain \(String(format: "%.3f", max(0, seconds - duration)))s")
        print("Final: \(transcript)")
    }
    print("Saved paced ASR comparison: \(reportPath)")
}
