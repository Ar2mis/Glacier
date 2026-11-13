import AppKit
import SwiftUI
import Translation
import Combine
import ApplicationServices
import GlacierCore

typealias CaptionTranslationOperation = @Sendable (String, [TranslationPair], String,
    @escaping @Sendable (String) async -> Void) async throws -> String

@MainActor
final class CaptionModel: ObservableObject {
    @Published var english = "Your lecture, with subtitles."
    @Published var chinese = "听得见，也跟得上。"
    @Published var status = "准备好后，点击开始听课"
    @Published var running = false
    @Published var busy = false
    @Published var quickBusy = false
    @Published var wisprRecording = false
    private var finishTimeout: Task<Void, Never>?
    @Published var finishingRecording = false {
        didSet {
            finishTimeout?.cancel()
            if finishingRecording {
                finishTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    guard let self else { return }
                    self.finishingRecording = false
                    self.archive.status = "未及时取得最终转录；请保持 Wispr Transcript 打开，并点「归档当前已结束的录音」重试。"
                }
            }
        }
    }
    @Published var quickVisible = (UserDefaults.standard.object(forKey: "quickVisible") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(quickVisible, forKey: "quickVisible") }
    }
    var showSettingsRequested: (() -> Void)?
    private var quickTask: Task<Void, Never>?
    @Published var visible = false
    @Published var fontSize = UserDefaults.standard.double(forKey: "fontSize").nonzero(or: 24) { didSet { save("fontSize", fontSize) } }
    @Published var bottom = UserDefaults.standard.double(forKey: "bottom").nonzero(or: 36) { didSet { save("bottom", bottom) } }
    @Published var width = UserDefaults.standard.double(forKey: "width").nonzero(or: 0.82) { didSet { save("width", width) } }
    @Published var opacity = UserDefaults.standard.double(forKey: "opacity").nonzero(or: 0.82) { didSet { save("opacity", opacity) } }
    @Published var screenIndex = 0
    @Published var englishFont = UserDefaults.standard.string(forKey: "englishFont") ?? "Times New Roman" {
        didSet { UserDefaults.standard.set(englishFont, forKey: "englishFont"); layoutChanged?() }
    }
    @Published var chineseFont = UserDefaults.standard.string(forKey: "chineseFont") ?? "Songti SC" {
        didSet { UserDefaults.standard.set(chineseFont, forKey: "chineseFont"); layoutChanged?() }
    }
    @Published var englishBold = UserDefaults.standard.bool(forKey: "englishBold") {
        didSet { UserDefaults.standard.set(englishBold, forKey: "englishBold"); layoutChanged?() }
    }
    @Published var chineseBold = UserDefaults.standard.bool(forKey: "chineseBold") {
        didSet { UserDefaults.standard.set(chineseBold, forKey: "chineseBold"); layoutChanged?() }
    }
    @Published var titleMode = UserDefaults.standard.bool(forKey: "titleMode") {
        didSet { UserDefaults.standard.set(titleMode, forKey: "titleMode"); layoutChanged?() }
    }
    var displayFontSize: Double { fontSize * (titleMode ? 1.3 : 1) }
    @Published var backgroundEnabled = UserDefaults.standard.bool(forKey: "backgroundEnabled") {
        didSet { UserDefaults.standard.set(backgroundEnabled, forKey: "backgroundEnabled") }
    }
    @Published var shadowWidth = (UserDefaults.standard.object(forKey: "shadowWidth") as? Double) ?? 1.5 {
        didSet { UserDefaults.standard.set(shadowWidth, forKey: "shadowWidth") }
    }
    @Published var blackWithoutShadow = (UserDefaults.standard.object(forKey: "blackWithoutShadow") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(blackWithoutShadow, forKey: "blackWithoutShadow") }
    }
    @Published var englishColor = CaptionPalette.load("englishColor", fallback: .white) {
        didSet { CaptionPalette.save(englishColor, key: "englishColor") }
    }
    @Published var chineseColor = CaptionPalette.load("chineseColor", fallback: Color(red: 1, green: 0.86, blue: 0.48)) {
        didSet { CaptionPalette.save(chineseColor, key: "chineseColor") }
    }
    @Published var translationConfig: TranslationSession.Configuration?
    @Published var translationReady = false
    @Published var inputMode = UserDefaults.standard.string(forKey: "inputMode") ?? "whisperkit" {
        didSet { UserDefaults.standard.set(inputMode, forKey: "inputMode") }
    }
    @Published var whisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "") ?? .base {
        didSet { UserDefaults.standard.set(whisperModel.rawValue, forKey: "whisperModel") }
    }
    @Published var refineEnabled = (UserDefaults.standard.object(forKey: "refineEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(refineEnabled, forKey: "refineEnabled") }
    }
    @Published var refineModel = UserDefaults.standard.string(forKey: "refineModel") ?? "gpt-4o-mini" {
        didSet { UserDefaults.standard.set(refineModel, forKey: "refineModel") }
    }
    @Published var speechKeyDraft = ""
    @Published var translationMode = UserDefaults.standard.string(forKey: "translationMode") ?? "gpt" {
        didSet { UserDefaults.standard.set(translationMode, forKey: "translationMode") }
    }
    @Published var provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "openai") ?? .openai {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider")
            gptModel = provider.defaultModel
            apiKeyDraft = ""
            hasAPIKey = APIKeyStore.exists(provider: provider)
        }
    }
    @Published var gptModel = UserDefaults.standard.string(forKey: "gptModel") ?? "gpt-4.1" {
        didSet { UserDefaults.standard.set(gptModel, forKey: "gptModel") }
    }
    @Published var glossary = UserDefaults.standard.string(forKey: "glossary") ?? "" {
        didSet { UserDefaults.standard.set(glossary, forKey: "glossary") }
    }
    @Published var apiKeyDraft = ""
    @Published var hasAPIKey = false
    @Published var connectionStatus = ""
    @Published var queuedSentences = 0
    var canStart: Bool { !busy && (translationMode == "gpt" ? hasAPIKey : translationReady) }
    var layoutChanged: (() -> Void)?
    private let capture = SpeechCapture()
    private var coreCapture: (any StreamingTranscriber)?
    private var coreTask: Task<Void, Never>?
    private var refiner: TranscriptRefiner?
    private let wisprCapture = WisprCapture()
    private var startTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var session: TranslationSession?
    private var generation = UUID()
    private var liveBuffer = LiveCaptionBuffer()
    private var currentCaptionID = ""
    private var appleSegment = 0
    private var recordingActive = false
    private var displayedTranslation: CaptionJob?
    private var gpt: GPTTranslator?
    private var translationEpoch = UUID()
    private var wisprObserving = false
    private var translatedAt = Date.distantPast
    private var translationProblem: String?
    let simulation: Bool
    private let translationOverride: CaptionTranslationOperation?
    init(simulation: Bool = false, operation: CaptionTranslationOperation? = nil) {
        self.simulation = simulation
        self.translationOverride = operation
        if !simulation { hasAPIKey = APIKeyStore.exists(provider: provider) }
    }
    @Published var historyEntries: [CaptionHistoryEntry] = []
    @Published var courseName = UserDefaults.standard.string(forKey: "courseName") ?? "" {
        didSet { UserDefaults.standard.set(courseName, forKey: "courseName") }
    }
    @Published var autoArchive = (UserDefaults.standard.object(forKey: "autoArchive") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoArchive, forKey: "autoArchive") }
    }
    let archive = LectureArchive()
    var openHistory: (() -> Void)?
    var recordingStarted: (() -> Void)?
    var recordingStopped: (() -> Void)?
    private var archiveCaptureTask: Task<Void, Never>?

    func saveSpeechKey() {
        let value = speechKeyDraft
        guard !running, !busy, !value.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try CredentialStore.save(value, provider: "deepgram") }.value
                speechKeyDraft = ""; status = "Deepgram key 已保存到本机钥匙串"
            } catch { status = error.localizedDescription }
        }
    }

    func saveAPIKey() {
        guard !busy, !running, !simulation else { return }
        let draft = apiKeyDraft; let selected = provider
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try APIKeyStore.save(draft, provider: selected) }.value
                apiKeyDraft = ""; hasAPIKey = true; status = "API key 已保存到本机钥匙串"
            } catch { status = error.localizedDescription }
        }
    }
    func unlockAPIKey() {
        guard !busy, !running, !simulation else { return }
        let selected = provider
        busy = true; status = "等待系统确认密钥访问…"
        Task {
            defer { busy = false }
            do {
                _ = try await Task.detached { try APIKeyStore.read(provider: selected, allowInteraction: true) }.value
                hasAPIKey = true; status = "密钥已解锁，可以测试 AI 翻译"
            } catch { status = error.localizedDescription }
        }
    }
    func removeAPIKey() {
        guard !busy, !running, !simulation else { return }
        let selected = provider
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try APIKeyStore.delete(provider: selected) }.value
                hasAPIKey = false; apiKeyDraft = ""; status = "已移除 API key"
            } catch { status = error.localizedDescription }
        }
    }
    func accessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func checkWispr() {
        guard !running, !busy else { return }
        busy = true
        startTask = Task {
            defer { busy = false; startTask = nil }
            do {
                let snapshot = try await WisprReader.shared.snapshot()
                try Task.checkCancellation()
                guard let latest = snapshot.segments.last else { status = "已连接 Wispr，等待出现转录文字"; return }
                english = SentenceFeed.sentences(latest.text).last ?? latest.text
                chinese = "Wispr 连接预览 · 未发送翻译请求"
                visible = true; layoutChanged?()
                status = "已读到 Wispr 的最新分段；此检查没有向翻译服务发送文字"
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    func testGPT() {
        guard !running, !busy, !simulation else { return }
        busy = true; status = "正在用示例句测试 AI 翻译…"
        startTask = Task {
            defer { busy = false; startTask = nil }
            do {
                let selectedProvider = provider
                let key = try await Task.detached { try APIKeyStore.read(provider: selectedProvider) }.value
                let source = "The difference-in-differences estimator relies on the parallel trends assumption."
                let translated = try await GPTTranslator(key: key, model: gptModel, provider: provider).stream(source, context: [], glossary: glossary) { _ in }
                try Task.checkCancellation()
                guard !running else { return }
                english = source; chinese = translated; visible = true; layoutChanged?()
                status = "AI 翻译测试成功"
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }

    private func save(_ key: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: key)
        layoutChanged?()
    }
    func prepareTranslation() {
        status = "正在准备中英翻译，请完成系统的语言下载提示…"
        if translationConfig == nil {
            translationConfig = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
        } else { translationConfig?.invalidate() }
    }
    func translationPrepared() {
        translationReady = true
        session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
        if translationMode == "apple" && !running { status = "本机中英翻译已就绪" }
        if running && translationProblem != nil { beginTranslation(token: generation) }
    }
    func quickToggle(showSettingsOnFailure: Bool = true) {
        if simulation { stop(message: "模拟已停止 · 未使用麦克风"); return }
        guard !quickBusy, !busy, !finishingRecording, !simulation else { return }
        if inputMode != "wispr" {
            if running { stop() } else { start() }
            return
        }
        guard AXIsProcessTrusted() else {
            status = "当前版本尚未获系统授权；若 Glacier 开关已开启，请关闭后重新开启，再重启 Glacier。"
            if showSettingsOnFailure { showSettingsRequested?() }; return
        }
        let shouldStop = wisprRecording
        quickBusy = true
        quickTask = Task {
            defer { quickBusy = false; quickTask = nil }
            do {
                let reader = WisprReader.shared
                let actualState = try? await reader.recordingState()
                if actualState ?? shouldStop {
                    status = "正在停止 Wispr Note…"
                    try await reader.stopNote()
                    receive(WisprSnapshot(meeting: "", segments: [], recording: false))
                    wisprRecording = false
                    running = false
                    hideCaptions()
                    finishingRecording = autoArchive
                    status = autoArchive ? "录音已停止 · 等待全文归档" : "录音已停止"
                    recordingStopped?()
                    // Keep observing until Wispr's final transcript is exported.
                } else {
                    watchWispr()
                    status = "正在启动 Wispr Note…"
                    try await reader.startNote()
                    wisprRecording = true
                    status = "Wispr 已确认录音 · 再点冰块停止"
                    recordingStarted?()
                }
            } catch {
                status = error.localizedDescription
                if showSettingsOnFailure { showSettingsRequested?() }
            }
        }
    }
    func start(allowEnglishOnly: Bool = false) {
        guard !busy, !running, !simulation else { return }
        if inputMode == "wispr" { watchWispr(); return }
        if translationMode == "apple" && !translationReady { prepareTranslation(); return }
        if let provider = SpeechProvider(rawValue: inputMode) { startCore(provider); return }
        busy = true; visible = true; layoutChanged?()
        generation = UUID(); let token = generation
        resetCaptionSession()
        startTask = Task {
            do {
                try await capture.start(status: { [weak self] text in self?.status = text }, result: { [weak self] text, final in
                    guard let self, self.generation == token else { return }
                    self.displaySegments([.init(id: self.appleSegment, text: text)])
                    if final { self.appleSegment += 1 }
                }, failure: { [weak self] message in
                    guard let self, self.generation == token else { return }
                    self.stop(message: "收音停止：\(message)")
                })
                try Task.checkCancellation()
                guard generation == token else { return }
                busy = false; running = true
                beginTranslation(token: token)
            } catch {
                if generation == token { stop(message: "无法开始：\(error.localizedDescription)") }
            }
        }
    }
    private func startCore(_ provider: SpeechProvider) {
        wisprCapture.stop(); wisprObserving = false
        busy = true; visible = true; layoutChanged?()
        generation = UUID(); let token = generation
        resetCaptionSession()
        startTask = Task {
            do {
                let key: String
                if provider == .openAI {
                    key = try await Task.detached { try APIKeyStore.read(provider: .openai) }.value
                } else if provider == .deepgram {
                    key = try await Task.detached { try CredentialStore.read("deepgram") }.value
                } else { key = "" }
                try Task.checkCancellation()
                let capture = TranscriberFactory.make(provider: provider, model: whisperModel, key: key)
                coreCapture = capture
                let events = try await capture.start { [weak self] text in
                    guard self?.generation == token else { return }; self?.status = text
                }
                try Task.checkCancellation()
                guard generation == token else { capture.stop(); return }
                busy = false; running = true; recordingStarted?()
                beginTranslation(token: token)
                coreTask = Task { [weak self] in
                    do {
                        for try await event in events {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            if event.isFinal { self.displaySegments([.init(id: event.id, text: event.text)]) }
                            else {
                                self.english = event.text; self.chinese = "识别中…"; self.layoutChanged?()
                            }
                        }
                        if let self, self.generation == token, self.running { self.stop(message: "转录已结束") }
                    } catch {
                        guard let self, self.generation == token else { return }
                        self.stop(message: error.localizedDescription)
                    }
                }
            } catch {
                if generation == token { stop(message: "无法开始：\(error.localizedDescription)") }
            }
        }
    }
    func watchWispr() {
        guard inputMode == "wispr", !simulation, !wisprObserving else { return }
        wisprObserving = true
        let token = generation
        wisprCapture.start(status: { [weak self] text in
            guard let self, self.generation == token else { return }
            self.connectionStatus = text
        }, snapshotChanged: { [weak self] snapshot in
            guard let self, self.generation == token else { return }
            self.receive(snapshot)
        }, ended: { [weak self] snapshot in
            guard let self, self.generation == token else { return }
            if self.autoArchive { self.archiveMeeting(snapshot) }
        }, failure: { [weak self] message in
            guard let self, self.generation == token else { return }
            self.connectionStatus = message
        })
        status = "已就绪 · 在 Wispr 或冰块开始录音均可"
    }
    private func resetCaptionSession() {
        translationTask?.cancel(); translationEpoch = UUID()
        liveBuffer = LiveCaptionBuffer(); historyEntries = []; currentCaptionID = ""
        displayedTranslation = nil; queuedSentences = 0; translationProblem = nil
        english = "Waiting for speech…"; chinese = "等待实时文字…"
    }
    // Same ingress for real Wispr observations and deterministic simulation.
    func receive(_ snapshot: WisprSnapshot) {
        if let active = snapshot.recording {
            if wisprRecording && !active && autoArchive && !simulation { finishingRecording = true }
            wisprRecording = active
        }
        if snapshot.recording == true {
            if !recordingActive {
                resetCaptionSession()
                visible = true; running = true; layoutChanged?()
                status = simulation ? "模拟课堂 · 未使用麦克风" : "Wispr 正在录音 · 点击冰块停止"
                beginTranslation(token: generation)
                if !quickBusy { recordingStarted?() }
            }
            recordingActive = true
            displaySegments(snapshot.segments)
        } else if snapshot.recording == false, recordingActive {
            displaySegments(snapshot.segments)
            running = false; recordingActive = false
            translationEpoch = UUID()
            translationTask?.cancel(); translationTask = nil
            queuedSentences = 0
            hideCaptions()
            if !quickBusy { recordingStopped?() }
            status = "录音已停止"
        }
        // Repeated stopped/unknown observations must not erase a key, test,
        // billing or connection error, or close an intentional subtitle preview.
    }
    private func displaySegments(_ segments: [TranscriptSegment]) {
        guard let latest = liveBuffer.update(segments) else { return }
        currentCaptionID = latest.id
        // Keep each pair together during short ASR revisions, but never freeze
        // the original line indefinitely behind a stalled translation service.
        if displayedTranslation == nil || Date().timeIntervalSince(translatedAt) > 4 {
            displayedTranslation = nil
            english = latest.english
            if let translationProblem { chinese = translationProblem }
            else { chinese = latest.chinese.isEmpty ? "正在翻译…" : latest.chinese }
        }
        historyEntries = liveBuffer.entries
        queuedSentences = liveBuffer.jobs.count
        layoutChanged?()
    }
    private func showTranslation(_ text: String, job: CaptionJob, complete: Bool) {
        liveBuffer.translated(job, text: text, complete: complete)
        historyEntries = liveBuffer.entries
        guard !text.isEmpty, liveBuffer.mayDisplay(job) else { return }
        displayedTranslation = job; translatedAt = Date()
        english = job.english; chinese = text; layoutChanged?()
    }
    private func showTranslationFailure(_ failure: TranslationFailure) {
        translationProblem = "翻译暂不可用：\(failure.message)"
        status = "\(translationProblem!)；英文仍在跟随"
        displayedTranslation = nil
        english = liveBuffer.entries.last?.english ?? english
        chinese = translationProblem!
        layoutChanged?()
    }
    private func beginTranslation(token: UUID) {
        translationTask?.cancel()
        translationEpoch = UUID(); let epoch = translationEpoch
        translationTask = Task {
            var useLocal = translationMode == "apple"
            var fallbackReason: String?
            var failures = 0
            if !useLocal && translationOverride == nil {
                do {
                    let selectedProvider = provider
                    let key = try await Task.detached { try APIKeyStore.read(provider: selectedProvider) }.value
                    guard !Task.isCancelled, translationEpoch == epoch else { return }
                    gpt = GPTTranslator(key: key, model: gptModel, provider: provider)
                    refiner = provider == .openai && refineEnabled ? TranscriptRefiner(key: key, model: refineModel) : nil
                } catch {
                    guard !Task.isCancelled, translationEpoch == epoch else { return }
                    let failure = TranslationFailure.classify(error)
                    if session != nil { useLocal = true; fallbackReason = failure.message }
                    else { showTranslationFailure(failure); return }
                }
            }
            while !Task.isCancelled && generation == token && translationEpoch == epoch && running {
                guard let job = liveBuffer.nextJob() else { try? await Task.sleep(for: .milliseconds(80)); continue }
                queuedSentences = liveBuffer.jobs.count
                let preceding = liveBuffer.context(before: job.id)
                do {
                    let translated: String
                    var refined: BilingualCaption?
                    let update: @Sendable (String) async -> Void = { [weak self] text in
                        guard let owner = self else { return }
                        await MainActor.run {
                            guard owner.generation == token, owner.translationEpoch == epoch, !Task.isCancelled, owner.running else { return }
                            owner.showTranslation(text, job: job, complete: false)
                        }
                    }
                    if useLocal, let session { translated = try await session.translate(job.english).targetText }
                    else if let translationOverride { translated = try await translationOverride(job.english, preceding, glossary, update) }
                    else if let refiner {
                        let pair = try await refiner.refine(job.english, glossary: glossary,
                            context: preceding.map { .init(english: $0.english, chinese: $0.chinese) })
                        refined = pair; translated = pair.chinese
                    }
                    else if let gpt { translated = try await gpt.stream(job.english, context: preceding, glossary: glossary, update: update) }
                    else { throw TranslationFailure(kind: .access, message: "翻译引擎尚未准备好") }
                    guard !Task.isCancelled, generation == token, translationEpoch == epoch, running else { return }
                    failures = 0; translationProblem = nil
                    showTranslation(translated, job: job, complete: true)
                    if let refined {
                        liveBuffer.refined(job, english: refined.english, chinese: refined.chinese)
                        historyEntries = liveBuffer.entries
                        if liveBuffer.mayDisplay(job) { english = refined.english; chinese = refined.chinese; layoutChanged?() }
                    }
                    queuedSentences = liveBuffer.jobs.count
                    if let fallbackReason { status = "本机翻译接替云端 · \(fallbackReason)" }
                    else { status = simulation ? "模拟课堂 · 中英文实时更新 · 未使用麦克风" : "实时字幕 · 中英文同步更新" }
                } catch {
                    guard !Task.isCancelled, generation == token, translationEpoch == epoch, running else { return }
                    let failure = TranslationFailure.classify(error)
                    failures += 1
                    if !useLocal && session != nil && (!failure.retryable || failures >= 2) {
                        useLocal = true; fallbackReason = failure.message
                        liveBuffer.retry(job)
                        status = "云端暂不可用，已切换本机翻译"
                        continue
                    }
                    showTranslationFailure(failure)
                    if !failure.retryable { return }
                    liveBuffer.retry(job)
                    let delay = max(failure.retryAfter, min(30, pow(2, Double(min(failures, 5)))))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }
    func archiveCurrent() {
        guard archiveCaptureTask == nil else { return }
        archiveCaptureTask = Task {
            defer { archiveCaptureTask = nil }
            do {
                let reader = WisprReader.shared
                let snapshot = try await reader.snapshot()
                guard snapshot.recording == false else { throw CaptionError.message("请先在 Wispr 停止录音，再归档。") }
                archive.status = "正在从 Wispr 取得完整英文转录…"
                let full = try await reader.fullTranscript(expectedMeeting: snapshot.meeting)
                archive.enqueue(english: full, course: courseName, wisprTitle: snapshot.meeting, glossary: glossary, model: gptModel, provider: provider)
            } catch { archive.status = "无法归档：\(error.localizedDescription)" }
        }
    }
    private func archiveMeeting(_ snapshot: WisprSnapshot) {
        guard archiveCaptureTask == nil else { return }
        archiveCaptureTask = Task {
            defer { archiveCaptureTask = nil }
            do {
                defer { finishingRecording = false }
                archive.status = "Wispr 已结束，正在取得完整英文转录…"
                let full = try await WisprReader.shared.fullTranscript(expectedMeeting: snapshot.meeting)
                archive.enqueue(english: full, course: courseName, wisprTitle: snapshot.meeting, glossary: glossary, model: gptModel, provider: provider)
            } catch { archive.status = "自动归档未完成：\(error.localizedDescription) 可点击归档当前录音重试。" }
        }
    }
    private func hideCaptions() {
        visible = false
        layoutChanged?()
    }
    func stop(message: String = "已暂停") {
        guard !busy || startTask != nil else { return }
        generation = UUID(); startTask?.cancel(); startTask = nil
        translationTask?.cancel(); translationTask = nil
        coreTask?.cancel(); coreTask = nil; coreCapture?.stop(); coreCapture = nil; refiner = nil
        wisprCapture.stop(); wisprObserving = false; recordingActive = false; translationEpoch = UUID(); gpt = nil
        queuedSentences = 0
        running = false; busy = true; status = message
        hideCaptions()
        Task { if !simulation { await capture.stop() }; busy = false }
    }
    func demo() {
        guard !running, !busy else { return }
        english = "The membrane allows some substances to pass through."
        chinese = "细胞膜允许某些物质通过。"
        status = "字幕预览 · 可以切换 App、桌面或全屏检查位置"
        visible = true; layoutChanged?()
    }
}

extension Double {
    func nonzero(or fallback: Double) -> Double { self == 0 ? fallback : self }
}

enum CaptionPalette {
    static func load(_ key: String, fallback: Color) -> Color {
        guard let rgb = UserDefaults.standard.array(forKey: key) as? [Double], rgb.count == 3 else { return fallback }
        return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
    }
    static func save(_ color: Color, key: String) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        UserDefaults.standard.set([Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)], forKey: key)
    }
    static func isBlack(_ color: Color) -> Bool {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return false }
        return max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) <= 0.1
    }
}

struct CaptionShadow: ViewModifier {
    let color: Color
    let width: Double
    let blackWithoutShadow: Bool
    func body(content: Content) -> some View {
        let enabled = width > 0 && !(blackWithoutShadow && CaptionPalette.isBlack(color))
        content.shadow(color: enabled ? .black.opacity(0.85) : .clear,
                       radius: enabled ? width : 0, x: 0, y: enabled ? 1 : 0)
    }
}

struct CaptionView: View {
    @ObservedObject var model: CaptionModel
    var body: some View {
        VStack(spacing: 7) {
            Text(model.english).font(CaptionFonts.font(model.englishFont, size: model.displayFontSize, bold: model.englishBold || model.titleMode))
                .foregroundStyle(model.englishColor).fixedSize(horizontal: false, vertical: true)
                .modifier(CaptionShadow(color: model.englishColor, width: model.shadowWidth, blackWithoutShadow: model.blackWithoutShadow))
            Text(model.chinese).font(CaptionFonts.font(model.chineseFont, size: model.displayFontSize, bold: model.chineseBold || model.titleMode))
                .foregroundStyle(model.chineseColor).fixedSize(horizontal: false, vertical: true)
                .modifier(CaptionShadow(color: model.chineseColor, width: model.shadowWidth, blackWithoutShadow: model.blackWithoutShadow))
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 25).padding(.vertical, 13)
        .background(Color.black.opacity(model.backgroundEnabled ? model.opacity : 0), in: RoundedRectangle(cornerRadius: 18))
        .padding(3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

enum CaptionFonts {
    static let english = ["Times New Roman", "Georgia", "Arial", "Helvetica"]
    static let chinese = [("宋体（Songti SC）", "Songti SC"), ("苹方", "PingFang SC"), ("黑体", "Heiti SC")]
    static func nativeFont(_ family: String, size: Double, bold: Bool) -> NSFont {
        NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                             weight: bold ? 9 : 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
    static func font(_ family: String, size: Double, bold: Bool) -> Font {
        Font(nativeFont(family, size: size, bold: bold))
    }
    static func height(_ text: String, family: String, size: Double, bold: Bool, width: Double) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [.font: nativeFont(family, size: size, bold: bold)]
        return ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 10000),
                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height)
    }
}

struct SettingsView: View {
    @ObservedObject var model: CaptionModel
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text("🧊").font(.system(size: 38))
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Glacier").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("英语原文 · 中文翻译 · 始终在你眼前").foregroundStyle(.secondary)
                }
            }
            Text(model.status).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.white.opacity(0.30), in: RoundedRectangle(cornerRadius: 14))
            engineControls
            HStack {
                if model.translationMode == "apple" {
                    Button(model.translationReady ? "本机翻译已就绪" : "准备本机翻译") { model.prepareTranslation() }
                        .disabled(model.running || model.busy || model.translationReady)
                }
                Button(model.inputMode == "wispr" ? (model.wisprRecording ? "停止录音" : "开始录音") : (model.running ? "暂停字幕" : "开始本机收音")) {
                    model.quickToggle()
                }.buttonStyle(GlacierButtonStyle()).disabled(model.busy || model.quickBusy || model.finishingRecording)
                Button("预览字幕") { model.demo() }.disabled(model.running || model.busy)
                Button("回看最近 30 秒") { model.openHistory?() }
            }
            Toggle("显示侧边冰块快捷按钮（点击录音，右键回看，可拖动）", isOn: $model.quickVisible)
            ArchiveControls(model: model, archive: model.archive)
            fontControls
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 15) {
                GridRow { Text("字幕字号"); Slider(value: $model.fontSize, in: 18...38, step: 1); Text("\(Int(model.fontSize))") }
                GridRow { Text("底部距离"); Slider(value: $model.bottom, in: 8...220, step: 1); Text("\(Int(model.bottom))") }
                GridRow { Text("字幕宽度"); Slider(value: $model.width, in: 0.45...0.96); Text("\(Int(model.width * 100))%") }
                GridRow {
                    Text("阴影宽度")
                    Slider(value: $model.shadowWidth, in: 0...8, step: 0.5)
                    Text(model.shadowWidth == 0 ? "无阴影" : String(format: "%.1f pt", model.shadowWidth))
                }
                GridRow {
                    Toggle("添加底色", isOn: $model.backgroundEnabled)
                    Slider(value: $model.opacity, in: 0.15...0.95).disabled(!model.backgroundEnabled)
                    Text(model.backgroundEnabled ? "\(Int(model.opacity * 100))%" : "无底色")
                }
            }
            Toggle("黑色文字自动无阴影", isOn: $model.blackWithoutShadow)
                .help("默认对黑色和接近黑色的文字关闭阴影，中英文分别判断。关闭此选项后，所有颜色都使用所选阴影宽度。")
            HStack(spacing: 26) {
                ColorPicker("英文颜色", selection: $model.englishColor, supportsOpacity: false)
                ColorPicker("中文颜色", selection: $model.chineseColor, supportsOpacity: false)
                Button("恢复配色") {
                    model.englishColor = .white
                    model.chineseColor = Color(red: 1, green: 0.86, blue: 0.48)
                }
            }
            Picker("显示屏", selection: $model.screenIndex) {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    Text(screen.localizedName).tag(index)
                }
            }.onChange(of: model.screenIndex) { model.layoutChanged?() }
            Toggle("显示底部字幕", isOn: $model.visible).onChange(of: model.visible) { model.layoutChanged?() }
            Divider()
            Text("底部字幕完全穿透点击，不拦截下方按钮。通过设置或菜单栏回看最近 30 秒，回看窗口可拖动。关闭设置后，菜单栏的字幕图标仍可控制应用。")
                .font(.callout).foregroundStyle(.secondary)
            Text("WhisperKit/Apple 本机处理语音；OpenAI/Deepgram 语音来源会发送音频。AI 整理/翻译发送文字、最近四句上下文和课程术语。Wispr 单独负责其录音，自动 Word 全文归档目前只支持 Wispr。API key 存入本机钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26)
        }
        .modifier(GlacierSurface())
        .frame(width: 580, height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        .translationTask(model.translationConfig) { session in
            do { try await session.prepareTranslation(); model.translationPrepared() }
            catch { model.status = "翻译准备失败：\(error.localizedDescription)。请重试。" }
        }
    }

    private var engineControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("转录来源", selection: $model.inputMode) {
                ForEach(SpeechProvider.allCases) { Text($0.title).tag($0.rawValue) }
                Text("Wispr Note · 跟随转录窗口").tag("wispr")
                Text("Apple · SpeechAnalyzer（macOS 26）").tag("apple")
            }.disabled(model.running || model.busy)
            if model.inputMode == "whisperkit" {
                Picker("本机语音模型", selection: $model.whisperModel) {
                    ForEach(WhisperModel.allCases) { Text($0.title).tag($0) }
                }.disabled(model.running || model.busy)
                Text("首次开始会下载模型并进行预热；之后使用缓存。Base 适合先测试，Turbo 占用更多内存。无需安装 Wispr。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.inputMode == "deepgram" {
                HStack {
                    SecureField("Deepgram API key", text: $model.speechKeyDraft)
                    Button("保存语音 key") { model.saveSpeechKey() }.disabled(model.speechKeyDraft.isEmpty || model.running || model.busy)
                }
            }
            if SpeechProvider(rawValue: model.inputMode)?.sendsAudioToCloud == true {
                Text("此来源会把麦克风音频发送到所选云服务。OpenAI 语音使用下方保存的 OpenAI key；Deepgram 需要独立 key。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.inputMode == "wispr" {
                Text("打开 Wispr Transcript 并滚到底部，再连接字幕。点击侧边冰块或「开始录音」会联动 Wispr New note，再次点击停止。结束后自动归档。请勿最小化转录窗口。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("允许读取 Wispr · 辅助功能设置") { model.accessibilitySettings() }
                    Button("检查 Wispr 连接") { model.checkWispr() }.disabled(model.running || model.busy)
                }
                if !model.connectionStatus.isEmpty { Text(model.connectionStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Picker("中文翻译", selection: $model.translationMode) {
                Text("AI · 上下文逐句翻译").tag("gpt")
                Text("Apple · 本机翻译（备用）").tag("apple")
            }.disabled(model.running || model.busy)
            if model.translationMode == "gpt" {
                Picker("AI 服务", selection: $model.provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }.disabled(model.running || model.busy || model.archive.working)
                TextField("模型名称", text: $model.gptModel)
                    .textFieldStyle(.roundedBorder).disabled(model.running || model.busy || model.archive.working)
                HStack {
                    SecureField(model.hasAPIKey ? "已保存；输入新 key 可替换" : "\(model.provider.title) API key", text: $model.apiKeyDraft)
                    Button("保存") { model.saveAPIKey() }.disabled(model.apiKeyDraft.isEmpty)
                    if model.hasAPIKey { Button("移除") { model.removeAPIKey() } }
                }.disabled(model.running || model.busy)
                HStack {
                    Button("测试 AI 翻译") { model.testGPT() }.disabled(!model.hasAPIKey || model.running || model.busy)
                    Button("解锁已保存的密钥") { model.unlockAPIKey() }.disabled(!model.hasAPIKey || model.running || model.busy)
                    Link("获取 API key", destination: URL(string: model.provider.keyURL)!)
                }
                Text(model.provider.notice)
                    .font(.caption).foregroundStyle(.secondary)
                if model.provider == .openai {
                    Toggle("一次请求完成英文整理 + 中文翻译", isOn: $model.refineEnabled).disabled(model.running || model.busy)
                    if model.refineEnabled {
                        Picker("整理模型", selection: $model.refineModel) {
                            Text("GPT-4o mini").tag("gpt-4o-mini")
                            Text("GPT-5 mini").tag("gpt-5-mini")
                        }.disabled(model.running || model.busy)
                    }
                }
                TextField("Course Vocabulary / Glossary：课程代码、教授姓名、专业词汇（每行一条）", text: $model.glossary, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(model.running || model.busy)
            }
            if model.queuedSentences > 0 { Text("待更新翻译：\(model.queuedSentences) 句").font(.caption) }
            Divider()
        }
    }

    private var fontControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("英文字体", selection: $model.englishFont) {
                    ForEach(CaptionFonts.english, id: \.self) { Text($0).tag($0) }
                }
                Toggle("英文加粗", isOn: $model.englishBold).disabled(model.titleMode)
            }
            HStack {
                Picker("中文字体", selection: $model.chineseFont) {
                    ForEach(CaptionFonts.chinese, id: \.1) { Text($0.0).tag($0.1) }
                }
                Toggle("中文加粗", isOn: $model.chineseBold).disabled(model.titleMode)
            }
            Picker("显示样式", selection: $model.titleMode) {
                Text("普通字幕").tag(false)
                Text("标题 · 放大加粗").tag(true)
            }.pickerStyle(.segmented)
            if model.titleMode {
                Text("标题模式：字号放大 30%，中英文都加粗；切回普通字幕后恢复原来的设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = GlacierSimulation.makeModel()
    private var simulationTask: Task<Void, Never>?
    var panel: SubtitlePanel!
    var settings: NSWindow!
    var statusItem: NSStatusItem!
    var historyWindow: NSPanel?
    var quickLauncher: IceLauncher?
    var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 140), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Glacier · 悬浮字幕"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        let captionHost = NSHostingView(rootView: CaptionView(model: model))
        // AppKit owns the overlay size. SwiftUI's automatic sizing can expand this
        // borderless window beyond the display and place its text off screen.
        captionHost.sizingOptions = []
        panel.contentView = captionHost
        model.showSettingsRequested = { [weak self] in self?.showSettings() }
        model.openHistory = { [weak self] in self?.showHistory() }
        model.layoutChanged = { [weak self] in
            DispatchQueue.main.async { self?.positionPanel() }
        }
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: 620),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        settings.title = "Glacier · 设置"; settings.isReleasedWhenClosed = false
        GlacierTheme.style(settings)
        settings.contentView = NSHostingView(rootView: SettingsView(model: model))
        settings.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Glacier")
        let menu = NSMenu()
        for (title, action, key) in [("打开设置", #selector(showSettings), ","), ("开始 / 停止录音", #selector(toggleListening), "s"), ("显示 / 隐藏字幕", #selector(toggleVisibility), "h"), ("回看最近 30 秒", #selector(showHistory), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Glacier", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(positionPanel), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioChanged), name: .AVAudioEngineConfigurationChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        quickLauncher = IceLauncher(model: model)
        model.recordingStarted = { [weak self] in self?.quickLauncher?.showStartedNotice() }
        model.recordingStopped = { [weak self] in self?.quickLauncher?.showStoppedNotice() }
        positionPanel(); showSettings()
        if model.simulation {
            simulationTask = Task {
                if CommandLine.arguments.contains("--simulate-local") {
                    let availability = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
                    guard availability == .installed else { model.status = "模拟未开始：本机中英语言包尚未安装"; return }
                    model.translationPrepared()
                }
                await GlacierSimulation.run(model)
            }
            return
        }
        model.watchWispr()
        if CommandLine.arguments.contains("--demo") { model.demo() }
        Task {
            let availability = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
            if availability == .installed { model.translationPrepared() }
        }
    }
    @objc func positionPanel() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens[max(0, min(model.screenIndex, screens.count - 1))]
        let frame = screen.frame
        let width = min(frame.width - 24, frame.width * model.width)
        let englishHeight = CaptionFonts.height(model.english, family: model.englishFont, size: model.displayFontSize,
                                               bold: model.englishBold || model.titleMode, width: width - 62)
        let chineseHeight = CaptionFonts.height(model.chinese, family: model.chineseFont, size: model.displayFontSize,
                                               bold: model.chineseBold || model.titleMode, width: width - 62)
        let height = min(frame.height * 0.4, max(model.displayFontSize * 2.8 + 32, englishHeight + chineseHeight + 48))
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + model.bottom, width: width, height: height), display: true)
        if model.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    @objc func showHistory() {
        historyWindow?.close()
        let snapshot = model.historyEntries.filter { $0.lastSeen >= Date().addingTimeInterval(-30) }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Glacier · 最近 30 秒"
        GlacierTheme.style(window)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: HistoryView(entries: snapshot))
        window.center(); window.makeKeyAndOrderFront(nil)
        historyWindow = window
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    @objc func showSettings() { settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggleListening() { model.quickToggle() }
    @objc func toggleVisibility() { model.visible.toggle(); positionPanel() }
    @objc func audioChanged() {
        if model.inputMode != "wispr" && model.running { model.stop(message: "音频设备发生变化，请重新开始听课。") }
    }
    @objc func sleeping() {
        if model.running || model.busy { model.stop(message: "电脑已休眠，唤醒后请重新开始听课。") }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if !GLACIER_TESTING
@main
enum Main {
    @MainActor static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
