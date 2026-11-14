import Foundation
import AppKit
import GlacierCore

actor ArchiveServiceFixture {
    var requests: [Int] = []
    var fail = true
    let digest: Data
    init(digest: Data) { self.digest = digest }
    func unblock() { fail = false }
    func count(_ id: Int) -> Int { requests.filter { $0 == id }.count }
    func generate(_ input: String) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
        guard let parts = root["parts"] as? [[String: Any]] else { return digest }
        let ids = parts.map { $0["id"] as! Int }; requests += ids
        if fail && ids.contains(where: { $0 >= 3 }) { throw CaptionError.message("Simulated network loss") }
        return try JSONEncoder().encode(TranslationBatch(translations: ids.map { .init(id: $0, chinese: "完整翻译第\($0)段。") }, notes: ["中文学习笔记。 "]))
    }
}

@main
struct ArchiveVerify {
    @MainActor static func main() async throws {
        var live = LiveCaptionBuffer()
        let now = Date(timeIntervalSince1970: 100)
        _ = live.update([.init(id: 1, text: "Old history."), .init(id: 2, text: "The lecture begins")], now: now)
        precondition(live.entries.count == 1)
        precondition(live.entries.last?.english == "The lecture begins")
        _ = live.update([.init(id: 2, text: "The lecture begins now.")], now: now.addingTimeInterval(1))
        precondition(live.jobs.count == 1)
        _ = live.update([.init(id: 2, text: "The lecture begins now."), .init(id: 3, text: "A new sentence.")], now: now.addingTimeInterval(2))
        let earlier = live.nextJob(now: now.addingTimeInterval(2.5))!
        precondition(earlier.english == "The lecture begins now.")
        let newest = live.nextJob(now: now.addingTimeInterval(2.5))!
        precondition(newest.english == "A new sentence.")
        live.translated(newest, text: "新的一句。", complete: true)
        precondition(live.recent(at: now.addingTimeInterval(29)).count == 2)
        precondition(live.recent(at: now.addingTimeInterval(33)).isEmpty)
        print("PASS: immediate partial English, revision coalescing, ordered recent translation and 30-second history")

        let english = (1...22).map { index in
            "Speaker 1 [00:\(String(format: "%02d", index))]\nExample \(index). A randomized experiment compares a treatment group with a control group. Random assignment helps make the groups comparable before treatment. The estimated effect is the difference in their average outcomes."
        }.joined(separator: "\n\n")
        let parts = ArchiveText.parts(english, limit: 700)
        precondition(parts.map(\.text).joined() == english)
        precondition(parts.map(\.id) == Array(0..<parts.count))
        precondition(ArchiveText.safeName("../../Course: Name/Unit") == "Course  Name Unit")
        do {
            try ArchiveText.validate(.init(translations: [], notes: []), for: parts)
            fatalError("Missing full-text translation accepted")
        } catch {}
        var job = ArchiveJob(created: Date(timeIntervalSince1970: 1_791_000_000), course: "测试课程", wisprTitle: "Test lecture", english: english, glossary: "", parts: parts)
        job.translations = parts.map { .init(id: $0.id, chinese: "测试译文第\($0.id + 1)段。随机实验比较干预组和对照组。随机分配有助于使两组在干预前具有可比性。通过比较两组的平均结果，可以估计干预效果。此内容用于验证文档排版和全文分段顺序。") }
        job.digest = .init(title: "随机实验与因果推断", chineseSummary: [
            "本次测试课程说明随机实验的基本逻辑。研究者将符合条件的参与者随机分配到干预组与对照组，通过结果差异估计干预效果。",
            "随机分配的作用是在期望意义上平衡两组的初始特征。分析时需要区分平均效果和个体差异，并结合实施过程理解结果。",
            "本测试资料用于检查英文原文与中文译文是否分别连续保存，并检验思维导图、英文提纲和多页文档的版式。"],
            englishOutline: [
                .init(title: "Random assignment", points: ["Participants are assigned to groups by chance.", "Assignment supports comparability before treatment."]),
                .init(title: "Estimating effects", points: ["Compare average outcomes across groups.", "Distinguish average effects from individual differences."]),
                .init(title: "Interpreting evidence", points: ["Consider implementation and study assumptions.", "Keep the complete source transcript for review."])],
            mindMap: [
                .init(title: "研究问题", points: ["明确政策目标", "识别关注人群", "定义结果变量"]),
                .init(title: "随机分配", points: ["分配干预组与对照组", "比较初始特征", "理解随机性"]),
                .init(title: "因果效应", points: ["构造反事实", "比较平均结果", "区分个体差异"]),
                .init(title: "研究假设", points: ["明确识别条件", "检查实施过程", "考虑潜在偏差"]),
                .init(title: "政策解释", points: ["报告证据范围", "说明适用条件", "避免过度推广"]),
                .init(title: "课后复习", points: ["回看完整英文原文", "核对完整中文译文", "整理关键知识点"])])
        job.source = "WhisperKit · On device"
        let output = try WordExporter.export(job, desktop: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/document-qa"))
        print("PASS: exact English reconstruction, numbered translation coverage, safe filenames and Word export")
        print(output.path)
        try output.path.write(toFile: ".build/archive-output-path.txt", atomically: true, encoding: .utf8)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GlacierArchiveRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = LectureSessionStore(directory: temporary.appendingPathComponent("lectures"))
        let retryEnglish = english + "\n\n" + english
        precondition(ArchiveText.parts(retryEnglish).count > 3, "Fixture must span more than one network batch")
        let saved = LectureSession(course: "Recovery test", source: "WhisperKit", glossary: "", archiveModel: "gpt-4o-mini")
        try await store.create(saved)
        try await store.append(.init(id: 0, text: retryEnglish, isFinal: true), to: saved.id)
        let finished = try await store.finish(saved.id)
        let service = ArchiveServiceFixture(digest: try JSONEncoder().encode(job.digest!))
        let archive = LectureArchive(pendingDirectory: temporary.appendingPathComponent("pending"), outputDirectory: temporary.appendingPathComponent("exports"), lectures: store) { _, input in try await service.generate(input) }
        try await archive.enqueueSavedLecture(finished)
        func awaitIdle() async {
            let deadline = ContinuousClock.now + .seconds(15)
            while archive.working && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            precondition(!archive.working, "Archive test timed out")
        }
        await awaitIdle()
        precondition(archive.lastURL == nil && archive.status.contains("未完成"))
        let progressURL = temporary.appendingPathComponent("pending/\(saved.id.uuidString).json")
        let checkpoint = try JSONDecoder().decode(ArchiveJob.self, from: Data(contentsOf: progressURL))
        precondition(checkpoint.translations.count == 3 && checkpoint.english == retryEnglish)
        await service.unblock()
        // Duplicate handoff must not erase the successful batch before resuming.
        try await archive.enqueueSavedLecture(finished)
        await awaitIdle()
        precondition(archive.lastURL != nil && !FileManager.default.fileExists(atPath: progressURL.path))
        let firstBatchRequests = await service.count(0)
        precondition(firstBatchRequests == 1, "Retry must not translate completed chunks again")
        let final = try await store.session(saved.id)
        precondition(final.exportedURL == archive.lastURL)
        let original = try await store.english(saved.id)
        precondition(original == retryEnglish, "Export must not delete the durable original")
        print("PASS: interrupted full-lecture archive resumes saved translation checkpoints and exports once without losing English")
    }
}
