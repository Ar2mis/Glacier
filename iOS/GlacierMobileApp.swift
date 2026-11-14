import SwiftUI
import GlacierCore
import UIKit

typealias CaptionError = GlacierCoreError

@MainActor final class MobileCaptions: ObservableObject {
    @Published var provider = SpeechProvider(rawValue: UserDefaults.standard.string(forKey: "speechProvider") ?? "") ?? .whisperKit
    @Published var whisperModel = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "") ?? .base
    @Published var glossary = UserDefaults.standard.string(forKey: "courseVocabulary") ?? ""
    @Published var refineModel = UserDefaults.standard.string(forKey: "refineModel") ?? "gpt-4o-mini"
    @Published var cleanup = true
    @Published var openAIKey = ""
    @Published var deepgramKey = ""
    @Published var rawText = ""
    @Published var caption = BilingualCaption(english: "Your lecture, with subtitles.", chinese: "听得见，也跟得上。")
    @Published var status = "Choose a speech provider, then Start."
    @Published var running = false
    @Published var busy = false
    @Published var history: [String] = []
    let archive = LectureArchive()
    @Published var courseName = UserDefaults.standard.string(forKey: "courseName") ?? ""
    @Published var autoArchive = (UserDefaults.standard.object(forKey: "autoArchive") as? Bool) ?? true
    @Published private(set) var finishing = false
    private var sessionID: UUID?
    private var captureFailure: String?
    private var finishingTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    init() { archive.recoverSavedLectures() }
    private var capture: (any StreamingTranscriber)?
    private var recording: Task<Void, Never>?
    private var translating: Task<Void, Never>?
    private var queue: [String] = []
    private var context: [BilingualCaption] = []
    private var generation = UUID()
    private var refiner: TranscriptRefiner?
    func saveKeys() {
        do {
            if !openAIKey.isEmpty { try CredentialStore.save(openAIKey, provider: "openai"); openAIKey = "" }
            if !deepgramKey.isEmpty { try CredentialStore.save(deepgramKey, provider: "deepgram"); deepgramKey = "" }
            status = "Keys saved in this device's Keychain."
        } catch { status = error.localizedDescription }
    }
    func start() {
        guard !running, !busy else { return }
        UserDefaults.standard.set(provider.rawValue, forKey: "speechProvider")
        UserDefaults.standard.set(whisperModel.rawValue, forKey: "whisperModel")
        UserDefaults.standard.set(glossary, forKey: "courseVocabulary")
        UserDefaults.standard.set(refineModel, forKey: "refineModel")
        UserDefaults.standard.set(courseName, forKey: "courseName")
        UserDefaults.standard.set(autoArchive, forKey: "autoArchive")
        generation = UUID(); let token = generation
        captureFailure = nil
        busy = true; context = []; queue = []; history = []; rawText = ""
        recording = Task {
            do {
                let openAI = cleanup || provider == .openAI ? try CredentialStore.read("openai") : ""
                refiner = cleanup ? TranscriptRefiner(key: openAI, model: refineModel) : nil
                let key = provider == .deepgram ? try CredentialStore.read("deepgram") : openAI
                let saved = LectureSession(course: courseName, source: provider.title, glossary: glossary,
                                           archiveModel: "gpt-4o-mini", autoArchive: autoArchive)
                try await archive.lectures.create(saved)
                sessionID = saved.id
                try Task.checkCancellation()
                let capture = TranscriberFactory.make(provider: provider, model: whisperModel, key: key)
                self.capture = capture
                let stream = try await capture.start { [weak self] message in
                    guard self?.generation == token else { return }; self?.status = message
                }
                try Task.checkCancellation()
                guard generation == token else { capture.stop(); return }
                busy = false; running = true
                for try await event in stream {
                    guard generation == token, !Task.isCancelled else { return }
                    try await archive.lectures.append(event, to: saved.id)
                    guard generation == token else { return }
                    if finishing { continue }
                    rawText = event.text
                    if event.isFinal {
                        history.append("ASR: \(event.text)")
                        history = Array(history.suffix(200))
                        if refiner != nil {
                            guard queue.count < 8 else {
                                status = "Live cleanup is behind; complete English is saved for the final Word export."
                                continue
                            }
                            queue.append(event.text); drain(token)
                        } else { caption = .init(english: event.text, chinese: "") }
                    }
                }
                if generation == token && !finishing { stop() }
            } catch {
                guard generation == token else { return }
                captureFailure = error.localizedDescription
                if !finishing { stop() }
                status = error.localizedDescription
            }
        }
    }
    private func drain(_ token: UUID) {
        guard translating == nil else { return }
        translating = Task {
            defer { if generation == token { translating = nil } }
            while generation == token, !Task.isCancelled, !queue.isEmpty, let refiner {
                let text = queue.removeFirst()
                do {
                    let result = try await refiner.refine(text, glossary: glossary, context: context)
                    guard generation == token, !Task.isCancelled else { return }
                    caption = result
                    if !result.english.isEmpty { context.append(result); context = Array(context.suffix(4)) }
                    history.append("\(result.english)\n\(result.chinese)"); history = Array(history.suffix(200))
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    caption = .init(english: text, chinese: "Cleanup unavailable; original English retained.")
                    status = "Cleanup failed. Check the OpenAI key/quota/network."
                    if let service = error as? RefinementServiceFailure, !service.retryable {
                        self.refiner = nil; queue = []
                        status = "Cleanup paused after a key/access/quota error. English continues; fix the key and restart."
                    }
                }
            }
        }
    }
    func resumeArchives() { archive.recoverSavedLectures(excluding: sessionID) }
    func stop() {
        guard !finishing else { return }
        guard running, let capture, let id = sessionID else {
            generation = UUID(); recording?.cancel(); recording = nil
            translating?.cancel(); translating = nil; capture?.stop(); capture = nil; queue = []
            busy = false; running = false; status = "Stopped."; return
        }
        let consumer = recording
        finishing = true; busy = true; running = false
        translating?.cancel(); translating = nil; queue = []
        status = "Microphone stopped. Finishing the last utterance and saving the lecture…"
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish lecture") { [weak self] in
            guard let self else { return }
            self.captureFailure = "iOS suspended finalization; the saved transcript may have a provisional final utterance."
            self.capture?.stop()
            if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
        }
        finishingTask = Task {
            defer {
                capture.stop(); self.capture = nil; recording = nil; sessionID = nil
                generation = UUID(); finishing = false; busy = false; finishingTask = nil
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            }
            do { try await capture.finish() } catch { captureFailure = captureFailure ?? error.localizedDescription }
            await consumer?.value
            do {
                let saved = try await archive.lectures.finish(id, warning: captureFailure)
                if saved.autoArchive { try await archive.enqueueSavedLecture(saved) }
                status = saved.warning == nil ? "Lecture saved. Word export continues below." : "Saved with an interruption warning; see the archive."
            } catch { status = "Archive pending: \(error.localizedDescription). Saved text is retained for recovery." }
        }
    }

}

struct MobileContent: View {
    @StateObject private var model = MobileCaptions()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.caption.english).font(.custom("Times New Roman", size: 23))
                    Text(model.caption.chinese).font(.custom("Songti SC", size: 23))
                    if !model.rawText.isEmpty { Text("Live ASR: \(model.rawText)").font(.caption).foregroundStyle(.secondary) }
                    Text(model.status).font(.caption).textSelection(.enabled)
                    Button(model.running || model.busy ? "Stop" : "Start recording") {
                        if model.running || model.busy { model.stop() } else { model.start() }
                    }.buttonStyle(.borderedProminent).tint(.cyan).disabled(model.finishing)
                }
                Section("Transcription") {
                    Picker("Provider", selection: $model.provider) { ForEach(SpeechProvider.allCases) { Text($0.title).tag($0) } }
                    if model.provider == .whisperKit {
                        Picker("Model", selection: $model.whisperModel) { ForEach(WhisperModel.allCases) { Text($0.title).tag($0) } }
                        Text("Base is the mobile default. First use downloads and warms the model. Turbo needs more memory.").font(.caption)
                    }
                    if model.provider.sendsAudioToCloud { Text("Microphone audio will be sent to the selected cloud provider.").font(.caption) }
                }.disabled(model.running || model.busy)
                Section("Bilingual cleanup") {
                    Toggle("English cleanup + Chinese translation", isOn: $model.cleanup)
                    Picker("OpenAI model", selection: $model.refineModel) {
                        Text("GPT-4o mini").tag("gpt-4o-mini"); Text("GPT-5 mini").tag("gpt-5-mini")
                    }
                    TextField("Course Vocabulary / Glossary: one term per line", text: $model.glossary, axis: .vertical).lineLimit(3...8)
                    SecureField("OpenAI API key", text: $model.openAIKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Deepgram API key (only for Deepgram)", text: $model.deepgramKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save keys on this device") { model.saveKeys() }
                    Text("Cleanup sends transcript text, recent context and vocabulary to OpenAI. Turn it off for local English-only captions. Your GitHub secret is separate.").font(.caption)
                }.disabled(model.running || model.busy)
                Section("Lecture archive") {
                    TextField("Course name (optional)", text: $model.courseName).disabled(model.running || model.busy)
                    Toggle("Export Word automatically after Stop", isOn: $model.autoArchive).disabled(model.running || model.busy)
                    Text("Full English, full Chinese, Chinese summary, mind map and English outline. Exports send the saved transcript to OpenAI and require your API key. Keep Glacier open until export finishes.").font(.caption)
                    MobileArchiveStatus(archive: model.archive, disabled: model.running || model.busy)
                }
                Section("Recent session text") {
                    ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in Text(text).textSelection(.enabled) }
                }
                Section { Text("Keep Glacier in the foreground. iOS captions appear inside Glacier; system-wide overlays are Mac-only. Word files are saved in Glacier’s Documents folder and can be shared below.").font(.caption) }
            }.scrollContentBackground(.hidden).background(Color.cyan.opacity(0.08)).navigationTitle("🧊 Glacier")
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() }; if phase == .active { model.resumeArchives() } }
    }
}

struct MobileArchiveStatus: View {
    @ObservedObject var archive: LectureArchive
    let disabled: Bool
    var body: some View {
        Text(archive.status).font(.caption).textSelection(.enabled)
        Button("Resume saved lecture exports") { archive.recoverSavedLectures(includeManual: true) }.disabled(disabled || archive.working)
        if let url = archive.lastURL { ShareLink("Share Word document", item: url) }
    }
}

@main struct GlacierMobileApp: App {
    var body: some Scene { WindowGroup { MobileContent() } }
}
