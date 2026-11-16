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
    @Published private(set) var preparingCapture = false
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
    @Published var whisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "") ?? .turbo {
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
            credentialTestPassed = nil; credentialStatus = hasAPIKey ? "Saved on this Mac · not tested" : "No readable key · Apple fallback available"
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
    @Published var credentialStatus = "Not tested"
    @Published var credentialTestPassed: Bool?
    @Published var captionHoldSeconds = (UserDefaults.standard.object(forKey: "captionHoldSeconds") as? Double) ?? 5 {
        didSet { UserDefaults.standard.set(captionHoldSeconds, forKey: "captionHoldSeconds") }
    }
    @Published var readingPriority = UserDefaults.standard.bool(forKey: "readingPriority") {
        didSet { UserDefaults.standard.set(readingPriority, forKey: "readingPriority") }
    }
    @Published var activeTranslationEngine = "等待翻译"
    @Published var translationCatchingUp = false
    @Published var fallbackStatus = "Checking Apple English–Chinese language pack…"
    @Published var queuedSentences = 0
    var canStart: Bool { !busy }
    var canCancelCapture: Bool { preparingCapture && startTask != nil }
    var quickActionTitle: String { canCancelCapture ? "取消准备" : (wisprRecording || running ? "停止录音" : "开始录音") }
    var layoutChanged: (() -> Void)?
    private let capture = SpeechCapture()
    private var coreCapture: (any StreamingTranscriber)?
    private var cachedWhisper: (model: WhisperModel, glossary: String, capture: WhisperTranscriber)?
    private var coreTask: Task<Void, Never>?
    private var coreFinishTask: Task<Void, Never>?
    private var coreSessionID: UUID?
    private var coreFailure: String?
    @Published private(set) var drainingCore = false
    private let coreFactory: ((SpeechProvider, WhisperModel, String) -> any StreamingTranscriber)?
    private var refiner: TranscriptRefiner?
    private let wisprCapture = WisprCapture()
    private var startTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translationRequests: [UUID: (job: CaptionJob, task: Task<Void, Never>)] = [:]
    private var displayedTranslationSequence = 0
    private var session: TranslationSession?
    private var generation = UUID()
    private var liveBuffer = LiveCaptionBuffer()
    private var currentCaptionID = ""
    private var appleSegment = 0
    private var recordingActive = false
    private var readingBuffer = CaptionReadingBuffer()
    private var readingTask: Task<Void, Never>?
    private var stablePrefix = StableCaptionPrefix()
    private var liveDraft: CaptionJob?
    private var gpt: GPTTranslator?
    private var translationEpoch = UUID()
    private var wisprObserving = false
    private var translationProblem: String?
    let simulation: Bool
    private let translationOverride: CaptionTranslationOperation?
    private let localTranslationOverride: (@Sendable (String) async throws -> String)?
    private let credentialOverride: (@Sendable () throws -> String)?
    init(simulation: Bool = false, archive: LectureArchive? = nil, coreFactory: ((SpeechProvider, WhisperModel, String) -> any StreamingTranscriber)? = nil, localTranslation: (@Sendable (String) async throws -> String)? = nil, credential: (@Sendable () throws -> String)? = nil, operation: CaptionTranslationOperation? = nil) {
        self.simulation = simulation
        self.archive = archive ?? LectureArchive()
        self.coreFactory = coreFactory
        self.translationOverride = operation
        self.localTranslationOverride = localTranslation; self.credentialOverride = credential
        if !simulation {
            hasAPIKey = APIKeyStore.exists(provider: provider)
            credentialStatus = hasAPIKey ? "Saved on this Mac · not tested" : "No readable key · Apple fallback available"
            self.archive.recoverSavedLectures()
            Task { _ = await ensureLocalTranslation(requestDownload: false) }
            if inputMode == "whisperkit",
               WhisperModelStorage.cachedFolder(whisperModel, root: WhisperModelStorage.root) != nil ||
               WhisperModelStorage.cachedFolder(whisperModel, root: WhisperModelStorage.legacyRoot) != nil {
                let capture = whisperAdapter()
                Task { try? await capture.prepare() }
            }
        }
    }
    @Published var historyEntries: [CaptionHistoryEntry] = []
    @Published var courseName = UserDefaults.standard.string(forKey: "courseName") ?? "" {
        didSet { UserDefaults.standard.set(courseName, forKey: "courseName") }
    }
    @Published var autoArchive = (UserDefaults.standard.object(forKey: "autoArchive") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoArchive, forKey: "autoArchive") }
    }
    let archive: LectureArchive
    var openHistory: (() -> Void)?
    var recordingStarted: (() -> Void)?
    var recordingStopped: (() -> Void)?
    var captureNotice: ((String) -> Void)?
    private var archiveCaptureTask: Task<Void, Never>?

    func saveSpeechKey() {
        let value = speechKeyDraft
        guard !running, !busy, !value.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try CredentialStore.save(value, provider: "deepgram") }.value
                speechKeyDraft = ""; status = "Deepgram key 已保存到本机配置"
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
                apiKeyDraft = ""; hasAPIKey = true; credentialTestPassed = nil
                credentialStatus = "Saved on this Mac · not tested"; status = "API key 已保存；重启和自动更新后仍可读取"
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
                hasAPIKey = true; credentialTestPassed = nil
                credentialStatus = "Migrated to persistent storage · not tested"
                status = "密钥已迁移到本机配置；以后更新无需重新解锁"
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
                hasAPIKey = false; apiKeyDraft = ""; credentialTestPassed = nil
                credentialStatus = "Key removed · Apple fallback available"; status = "已移除 API key"
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
        let selected = provider, draft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = selected == .openai && refineEnabled ? refineModel : gptModel
        let useRefiner = selected == .openai && refineEnabled
        busy = true; credentialTestPassed = nil; credentialStatus = "Testing…"
        status = "正在测试实际字幕模型：\(model)…"
        startTask = Task {
            defer { busy = false; startTask = nil }
            do {
                let key = try await Task.detached { try draft.isEmpty ? APIKeyStore.read(provider: selected) : draft }.value
                let source = "The membrane is selectively permeable, not completely open."
                let translated: String
                if useRefiner { translated = try await TranscriptRefiner(key: key, model: model).refine(source, glossary: glossary, context: []).chinese }
                else { translated = try await GPTTranslator(key: key, model: model, provider: selected).stream(source, context: [], glossary: glossary) { _ in } }
                try Task.checkCancellation()
                if !draft.isEmpty { try await Task.detached { try APIKeyStore.save(draft, provider: selected) }.value }
                hasAPIKey = true; apiKeyDraft = ""; credentialTestPassed = true
                credentialStatus = "Connected · \(selected.title) / \(model)"
                activeTranslationEngine = "\(selected.title) · \(model)"
                english = source; chinese = translated; visible = true; layoutChanged?()
                status = "AI 翻译测试成功 · 密钥已持久保存"
            } catch {
                if !Task.isCancelled {
                    credentialTestPassed = false
                    credentialStatus = "Connection failed · " + error.localizedDescription
                    status = credentialStatus
                }
            }
        }
    }

    func testLocalTranslation() {
        guard !running, !busy, !simulation else { return }
        busy = true
        startTask = Task {
            defer { busy = false; startTask = nil }
            guard await ensureLocalTranslation(requestDownload: true), let session else {
                status = fallbackStatus; return
            }
            do {
                let source = "The membrane allows water to pass through."
                let response = try await session.translate(source)
                try Task.checkCancellation()
                english = source; chinese = response.targetText; visible = true; layoutChanged?()
                activeTranslationEngine = "Apple 本机翻译"
                status = "Apple 本机翻译测试成功 · 无需 API key 或云端请求"
            } catch { if !Task.isCancelled { status = "Apple 翻译暂不可用；请联网准备语言包后重试" } }
        }
    }

    private func save(_ key: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: key)
        layoutChanged?()
    }
    func prepareTranslation() {
        fallbackStatus = "请完成 Apple 中英语言包下载；安装后可离线翻译"
        if translationConfig == nil {
            translationConfig = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
        } else { translationConfig?.invalidate() }
    }
    private func ensureLocalTranslation(requestDownload: Bool) async -> Bool {
        if localTranslationOverride != nil || session != nil { return true }
        if simulation { return false }
        let available = await LanguageAvailability().status(from: .init(identifier: "en"), to: .init(identifier: "zh-Hans"))
        if Task.isCancelled { return false }
        if available == .installed {
            session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
            translationReady = true; fallbackStatus = "Apple fallback ready · English → 中文 · offline"
            return true
        }
        fallbackStatus = available == .unsupported ? "Apple 不支持此语言对；请使用云端翻译" : "Apple 语言包未安装；联网下载一次后即可离线使用"
        if requestDownload && available == .supported && translationConfig == nil {
            prepareTranslation(); showSettingsRequested?()
        }
        return false
    }
    func translationPrepared() {
        translationReady = true
        session = TranslationSession(installedSource: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
        fallbackStatus = "Apple fallback ready · English → 中文 · offline"
        if translationMode == "apple" && !running { status = "本机中英翻译已就绪" }
        if running && translationProblem != nil { beginTranslation(token: generation) }
    }
    func translationPreparationFailed() {
        fallbackStatus = "Apple 语言包准备失败；请联网后点「准备 Apple 离线翻译」重试"
        if translationProblem != nil || translationMode == "apple" { status = fallbackStatus }
    }
    func quickToggle(showSettingsOnFailure: Bool = true) {
        if simulation && coreFactory == nil { stop(message: "模拟已停止 · 未使用麦克风"); return }
        guard !quickBusy, (!busy || canCancelCapture), !finishingRecording else { return }
        if inputMode != "wispr" {
            if running || canCancelCapture { stop() } else { start() }
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
        guard !busy, !running, (!simulation || coreFactory != nil) else { return }
        if inputMode == "wispr" { watchWispr(); return }
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
    private func whisperAdapter() -> WhisperTranscriber {
        if cachedWhisper?.model != whisperModel || cachedWhisper?.glossary != glossary {
            cachedWhisper = (whisperModel, glossary, WhisperTranscriber(model: whisperModel, vocabulary: glossary))
        }
        return cachedWhisper!.capture
    }
    private func startCore(_ provider: SpeechProvider) {
        wisprCapture.stop(); wisprObserving = false
        busy = true; preparingCapture = true; visible = true; layoutChanged?()
        status = "正在准备收音 · 就绪后自动开始"
        generation = UUID(); let token = generation
        resetCaptionSession(); coreFailure = nil
        startTask = Task {
            do {
                let key: String
                if provider == .openAI {
                    key = try await Task.detached { try APIKeyStore.read(provider: .openai) }.value
                } else if provider == .deepgram {
                    key = try await Task.detached { try CredentialStore.read("deepgram") }.value
                } else { key = "" }
                try Task.checkCancellation()
                let saved = LectureSession(course: courseName, source: provider.title, glossary: glossary,
                                           archiveModel: gptModel, archiveProvider: self.provider.rawValue, autoArchive: autoArchive)
                try await archive.lectures.create(saved)
                coreSessionID = saved.id
                try Task.checkCancellation()
                let capture: any StreamingTranscriber
                if let coreFactory { capture = coreFactory(provider, whisperModel, key) }
                else if provider == .whisperKit { capture = whisperAdapter() }
                else { capture = TranscriberFactory.make(provider: provider, model: whisperModel, key: key, vocabulary: glossary) }
                coreCapture = capture
                let events = try await capture.start { [weak self] text in
                    guard self?.generation == token, self?.drainingCore != true else { return }; self?.status = text
                }
                try Task.checkCancellation()
                guard generation == token else { capture.stop(); return }
                busy = false; preparingCapture = false; startTask = nil; running = true; recordingStarted?()
                beginTranslation(token: token)
                coreTask = Task { [weak self] in
                    do {
                        for try await event in events {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            try await self.archive.lectures.append(event, to: saved.id)
                            guard self.generation == token else { return }
                            if self.drainingCore { continue }
                            let pieces = SentenceFeed.sentences(event.text)
                            self.liveDraft = pieces.last.map { .init(id: "\(event.id):\(pieces.count - 1)", english: $0) }
                            if let stable = self.stablePrefix.observe(event) {
                                self.displaySegments([.init(id: event.id, text: stable)])
                            } else if self.readingBuffer.current == nil {
                                self.english = event.text; self.chinese = "识别中…"; self.layoutChanged?()
                            }
                            if !self.readingPriority { self.refreshLiveEnglish(); self.layoutChanged?() }
                        }
                        if let self, self.generation == token, self.running { self.stop(message: "转录已结束") }
                    } catch {
                        guard let self, self.generation == token else { return }
                        self.coreFailure = error.localizedDescription
                        if !self.drainingCore { self.stop(message: error.localizedDescription) }
                    }
                }
            } catch {
                if generation == token {
                    stop(message: "无法开始：\(error.localizedDescription)")
                    captureNotice?(status)
                }
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
        cancelTranslationWork()
        liveBuffer = LiveCaptionBuffer(); historyEntries = []; currentCaptionID = ""
        readingTask?.cancel(); readingBuffer = CaptionReadingBuffer(); stablePrefix = StableCaptionPrefix()
        liveDraft = nil; translationCatchingUp = false
        queuedSentences = 0; translationProblem = nil
        readingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                if self.running, let next = self.readingBuffer.advance(hold: self.captionHoldSeconds) { self.present(next) }
            }
        }
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
            cancelTranslationWork()
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
        // Keep the last bilingual pair until its successor is actually ready.
        if readingBuffer.current == nil {
            english = latest.english
            if let translationProblem { chinese = translationProblem }
            else { chinese = latest.chinese.isEmpty ? "正在翻译…" : latest.chinese }
        }
        historyEntries = liveBuffer.entries
        queuedSentences = liveBuffer.jobs.count
        if !readingPriority { refreshLiveEnglish() }
        layoutChanged?()
    }
    private func refreshLiveEnglish() {
        let latest = liveDraft ?? liveBuffer.entries.last.map { CaptionJob(id: $0.id, english: $0.english) }
        guard let latest else { return }
        if let pair = readingBuffer.current, pair.id == latest.id && pair.source == latest.english {
            english = pair.english; translationCatchingUp = !pair.complete
        } else {
            english = latest.english
            translationCatchingUp = readingBuffer.current != nil
        }
    }
    private func present(_ caption: ReadingCaption) {
        english = caption.english; chinese = caption.chinese
        if readingPriority { translationCatchingUp = false }
        else { refreshLiveEnglish() }
        layoutChanged?()
    }
    private func showTranslation(_ text: String, job: CaptionJob, complete: Bool, cleanedEnglish: String? = nil, sequence: Int) {
        liveBuffer.translated(job, text: text, complete: complete)
        historyEntries = liveBuffer.entries
        guard !text.isEmpty, liveBuffer.mayDisplay(job) else { return }
        if !readingPriority, let current = readingBuffer.current,
           let shownIndex = liveBuffer.entries.firstIndex(where: { $0.id == current.id }),
           let jobIndex = liveBuffer.entries.firstIndex(where: { $0.id == job.id }), jobIndex < shownIndex { return }
        // Overlapped requests may complete in either order. Keep useful old
        // results in history without rewinding the current Chinese subtitle.
        guard sequence >= displayedTranslationSequence else { return }
        let caption = ReadingCaption(id: job.id, source: job.english, english: cleanedEnglish ?? job.english, chinese: text, complete: complete)
        if let ready = readingBuffer.submit(caption, hold: captionHoldSeconds, live: !readingPriority) {
            displayedTranslationSequence = sequence; present(ready)
        }
    }
    private func showTranslationFailure(_ failure: TranslationFailure) {
        translationProblem = "翻译暂不可用：\(failure.message)"
        status = "\(translationProblem!)；英文仍在保存"
        if readingBuffer.current == nil {
            english = liveBuffer.entries.last?.english ?? english; chinese = translationProblem!
        }
        layoutChanged?()
    }
    private func cancelTranslationWork() {
        translationTask?.cancel()
        translationTask = nil
        translationRequests.values.forEach { $0.task.cancel() }
        translationRequests.removeAll()
        translationEpoch = UUID()
    }
    private func beginTranslation(token: UUID) {
        cancelTranslationWork()
        translationEpoch = UUID(); let epoch = translationEpoch
        displayedTranslationSequence = 0
        translationTask = Task {
            var useLocal = translationMode == "apple"
            var fallbackReason: String?
            var failures = 0
            var nextStart = Date.distantPast, retryAfter = Date.distantPast
            var sequence = 0
            defer {
                if translationEpoch == epoch {
                    translationRequests.values.forEach { $0.task.cancel() }
                    translationRequests.removeAll()
                }
            }
            _ = await ensureLocalTranslation(requestDownload: useLocal)
            guard !Task.isCancelled, translationEpoch == epoch else { return }
            if !useLocal && translationOverride == nil {
                do {
                    let selectedProvider = provider
                    let reader = credentialOverride
                    let key = try await Task.detached { try reader?() ?? APIKeyStore.read(provider: selectedProvider) }.value
                    guard !Task.isCancelled, translationEpoch == epoch else { return }
                    gpt = GPTTranslator(key: key, model: gptModel, provider: provider)
                    refiner = provider == .openai && refineEnabled ? TranscriptRefiner(key: key, model: refineModel) : nil
                } catch {
                    guard !Task.isCancelled, translationEpoch == epoch else { return }
                    let failure = TranslationFailure.classify(error)
                    let localReady = await ensureLocalTranslation(requestDownload: true)
                    guard !Task.isCancelled, generation == token, translationEpoch == epoch else { return }
                    if localReady { useLocal = true; fallbackReason = failure.message }
                    else {
                        showTranslationFailure(.init(kind: .credentials, message: failure.message + " · " + fallbackStatus)); return
                    }
                }
            }
            activeTranslationEngine = useLocal ? "Apple 本机翻译" : "\(provider.title) · \(refiner != nil ? refineModel : gptModel)"
            while !Task.isCancelled && generation == token && translationEpoch == epoch && running {
                // Only live cloud captions overlap. Apple sessions and reading
                // priority remain serial. Limit both concurrency and launch rate.
                let overlap = !readingPriority && !useLocal
                guard translationRequests.count < (overlap ? 2 : 1), Date() >= retryAfter,
                      !overlap || Date() >= nextStart else { try? await Task.sleep(for: .milliseconds(40)); continue }
                guard let job = liveBuffer.nextJob(preferLatest: !readingPriority) else { try? await Task.sleep(for: .milliseconds(80)); continue }
                queuedSentences = liveBuffer.jobs.count
                let preceding = liveBuffer.context(before: job.id)
                let requestID = UUID(), requestUsesLocal = useLocal
                sequence += 1; let requestSequence = sequence
                nextStart = Date().addingTimeInterval(0.8)
                let request = Task {
                    defer { translationRequests[requestID] = nil }
                    do {
                        let translated: String
                        var refined: BilingualCaption?
                        let update: @Sendable (String) async -> Void = { [weak owner = self] text in
                            guard let owner else { return }
                            await MainActor.run {
                                guard owner.generation == token, owner.translationEpoch == epoch, !Task.isCancelled,
                                      owner.running, owner.translationRequests[requestID] != nil else { return }
                                owner.showTranslation(text, job: job, complete: false, sequence: requestSequence)
                            }
                        }
                        if requestUsesLocal {
                            if let localTranslationOverride { translated = try await localTranslationOverride(job.english) }
                            else if let session { translated = try await session.translate(job.english).targetText }
                            else { throw TranslationFailure(kind: .access, message: fallbackStatus) }
                        }
                        else if let translationOverride { translated = try await translationOverride(job.english, preceding, glossary, update) }
                        else if let refiner {
                            let pair = try await refiner.refine(job.english, glossary: glossary,
                                context: preceding.map { .init(english: $0.english, chinese: $0.chinese) }, update: { [weak owner = self] pair in
                                    guard let owner else { return }
                                    await MainActor.run {
                                        guard owner.generation == token, owner.translationEpoch == epoch, owner.running,
                                              !Task.isCancelled, owner.translationRequests[requestID] != nil else { return }
                                        owner.showTranslation(pair.chinese, job: job, complete: false, cleanedEnglish: pair.english, sequence: requestSequence)
                                    }
                                })
                            refined = pair; translated = pair.chinese
                        }
                        else if let gpt { translated = try await gpt.stream(job.english, context: preceding, glossary: glossary, update: update) }
                        else { throw TranslationFailure(kind: .access, message: "翻译引擎尚未准备好") }
                        guard !Task.isCancelled, generation == token, translationEpoch == epoch, running else { return }
                        failures = 0; translationProblem = nil
                        showTranslation(translated, job: job, complete: true, cleanedEnglish: refined?.english, sequence: requestSequence)
                        if let refined {
                            liveBuffer.refined(job, english: refined.english, chinese: refined.chinese)
                            historyEntries = liveBuffer.entries
                        }
                        queuedSentences = liveBuffer.jobs.count
                        if let fallbackReason { status = "本机翻译接替云端 · \(fallbackReason)" }
                        else { status = simulation ? "模拟课堂 · 中英文实时更新 · 未使用麦克风" : "实时字幕 · 中英文同步更新" }
                    } catch {
                        guard !Task.isCancelled, generation == token, translationEpoch == epoch, running else { return }
                        // Another overlapping cloud failure may already have switched
                        // to Apple. Do not let this older failure disable that fallback.
                        if !requestUsesLocal && useLocal { liveBuffer.retry(job); return }
                        let failure: TranslationFailure
                        if let service = error as? RefinementServiceFailure {
                            failure = .init(kind: service.retryable ? .network : .access, message: service.localizedDescription, retryAfter: 2)
                        } else { failure = TranslationFailure.classify(error) }
                        failures += 1
                        let localReady = !requestUsesLocal ? await ensureLocalTranslation(requestDownload: true) : false
                        guard !Task.isCancelled, generation == token, translationEpoch == epoch else { return }
                        if localReady {
                            useLocal = true; fallbackReason = failure.message; activeTranslationEngine = "Apple 本机翻译 · 云端暂不可用"
                            // A hung sibling must not delay the local fallback.
                            for (id, request) in translationRequests where id != requestID {
                                request.task.cancel(); liveBuffer.retry(request.job)
                            }
                            translationRequests = translationRequests.filter { $0.key == requestID }
                            liveBuffer.retry(job)
                            status = "云端暂不可用，已切换本机翻译"
                            return
                        }
                        showTranslationFailure(.init(kind: failure.kind, message: failure.message + (useLocal ? "" : " · " + fallbackStatus), retryAfter: failure.retryAfter))
                        if !failure.retryable { cancelTranslationWork(); return }
                        liveBuffer.retry(job)
                        let delay = max(failure.retryAfter, min(30, pow(2, Double(min(failures, 5)))))
                        retryAfter = Date().addingTimeInterval(delay)
                    }
                }
                translationRequests[requestID] = (job, request)
            }
        }
    }
    func archiveCurrent() {
        if inputMode != "wispr" {
            guard !running, !busy else { archive.status = "请先停止录音，等待最后一句完成。"; return }
            archive.recoverSavedLectures(includeManual: true); return
        }
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
        readingTask?.cancel(); readingTask = nil; readingBuffer = CaptionReadingBuffer()
        liveDraft = nil; translationCatchingUp = false
        visible = false
        layoutChanged?()
    }
    private func finishCoreRecording(_ capture: any StreamingTranscriber, id: UUID) {
        guard coreFinishTask == nil else { return }
        let consumer = coreTask
        drainingCore = true; busy = true; running = false
        hideCaptions(); recordingStopped?()
        cancelTranslationWork()
        status = "麦克风已停止 · 正在完成最后一句并保存全文…"
        coreFinishTask = Task {
            defer {
                capture.stop(); coreCapture = nil; coreTask = nil; coreSessionID = nil
                generation = UUID(); drainingCore = false; busy = false; coreFinishTask = nil
            }
            do { try await capture.finish() } catch { coreFailure = coreFailure ?? error.localizedDescription }
            // The consumer persists each final result before the archive reads the lecture.
            await consumer?.value
            do {
                let saved = try await archive.lectures.finish(id, warning: coreFailure)
                if saved.autoArchive { try await archive.enqueueSavedLecture(saved) }
                status = saved.warning == nil ? "录音已结束 · 全文已保存" : "录音已保存，但有未完成识别；请查看归档说明。"
                if !saved.autoArchive { archive.status = "全文已保存在本机；可点击归档已保存的录音生成 Word。" }
            } catch { status = "保存/归档未完成：\(error.localizedDescription)；已写入的转录仍保留，可恢复归档。" }
        }
    }
    func stop(message: String = "已暂停") {
        if drainingCore { return }
        if let capture = coreCapture, let id = coreSessionID, coreTask != nil {
            finishCoreRecording(capture, id: id); return
        }
        guard !busy || startTask != nil else { return }
        let wasRecording = running
        generation = UUID(); startTask?.cancel(); startTask = nil
        preparingCapture = false
        cancelTranslationWork()
        coreTask?.cancel(); coreTask = nil; coreCapture?.stop(); coreCapture = nil; refiner = nil
        wisprCapture.stop(); wisprObserving = false; recordingActive = false; translationEpoch = UUID(); gpt = nil
        queuedSentences = 0
        running = false; busy = true; status = message
        hideCaptions()
        if wasRecording && inputMode != "wispr" { recordingStopped?() }
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
            if model.translationCatchingUp {
                Text("中文翻译正在跟进…").font(.system(size: 12)).foregroundStyle(model.chineseColor.opacity(0.75))
            }
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
                Button(model.canCancelCapture ? "取消准备" : model.inputMode == "wispr" ? (model.wisprRecording ? "停止录音" : "开始录音") : (model.running ? "停止录音" : "开始收音")) {
                    model.quickToggle()
                }.buttonStyle(GlacierButtonStyle()).disabled((model.busy && !model.canCancelCapture) || model.quickBusy || model.finishingRecording)
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
            Text("WhisperKit/Apple 本机处理语音；OpenAI/Deepgram 语音来源会发送音频。AI 整理/翻译发送文字、最近四句上下文和课程术语。Wispr 单独负责其录音，GlacierCore 和 Wispr 均支持完整 Word 归档。Mac API key 存入本机私有配置（明文、仅当前用户可读），更新 App 不会覆盖。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26)
        }
        .modifier(GlacierSurface())
        .frame(width: 580, height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        .translationTask(model.translationConfig) { session in
            do { try await session.prepareTranslation(); model.translationPrepared() }
            catch { model.translationPreparationFailed() }
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
                Text("Mac 默认 Turbo，优先保证课堂识别质量。首次使用需要下载及预热；Base 适合低内存设备。课程术语也会提供给本机识别器。")
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
                    Button("Test Connection · 测试连接") { model.testGPT() }.disabled(model.running || model.busy)
                    Button("迁移钥匙串密钥") { model.unlockAPIKey() }.disabled(model.running || model.busy)
                    Link("获取 API key", destination: URL(string: model.provider.keyURL)!)
                }
                Label(model.credentialStatus, systemImage: model.credentialTestPassed == true ? "checkmark.circle.fill" : model.credentialTestPassed == false ? "exclamationmark.triangle.fill" : "key.fill")
                    .font(.caption).foregroundStyle(model.credentialTestPassed == true ? Color.green : model.credentialTestPassed == false ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                Text("OpenAI：粘贴 OPENAI_API_KEY 后点 Test Connection；测试成功会自动保存。配置保存在 Application Support/Glacier/config.json，不会随 App 重建丢失。")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text("当前翻译：" + model.activeTranslationEngine).font(.caption).foregroundStyle(.secondary)
            Text(model.fallbackStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("阅读优先（延长停留，可能落后于讲话）", isOn: $model.readingPriority)
            HStack {
                Text("每组字幕至少保留")
                Slider(value: $model.captionHoldSeconds, in: 2...12, step: 1)
                Text("\(Int(model.captionHoldSeconds)) 秒")
            }.disabled(!model.readingPriority)
            Text(model.readingPriority ? "下一组译文就绪且达到停留时间后再替换。关闭阅读优先可实时跟随。" : "实时跟随：英文随识别立即更新，中文增量跟进。等待时保留上一段中文并标示；英文原文持续保存。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("准备 Apple 离线翻译") { model.prepareTranslation() }.disabled(model.running || model.busy || model.translationReady)
                Button("Test Apple Translation · 测试本机翻译") { model.testLocalTranslation() }.disabled(model.running || model.busy)
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
        model.captureNotice = { [weak self] text in self?.quickLauncher?.showErrorNotice(text) }
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
        let height = min(frame.height * 0.4, max(model.displayFontSize * 2.8 + 32, englishHeight + chineseHeight + 48 + (model.translationCatchingUp ? 19 : 0)))
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
