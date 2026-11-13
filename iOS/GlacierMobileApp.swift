import SwiftUI
import GlacierCore

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
        generation = UUID(); let token = generation
        busy = true; context = []; queue = []; history = []; rawText = ""
        recording = Task {
            do {
                let openAI = cleanup || provider == .openAI ? try CredentialStore.read("openai") : ""
                refiner = cleanup ? TranscriptRefiner(key: openAI, model: refineModel) : nil
                let key = provider == .deepgram ? try CredentialStore.read("deepgram") : openAI
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
                    rawText = event.text
                    if event.isFinal {
                        history.append("ASR: \(event.text)")
                        history = Array(history.suffix(200))
                        if refiner != nil {
                            // Fail visibly rather than silently dropping source under overload.
                            guard queue.count < 8 else { throw GlacierCoreError.message("Cleanup is falling behind. Stop and choose a faster model or English-only mode.") }
                            queue.append(event.text); drain(token)
                        } else { caption = .init(english: event.text, chinese: "") }
                    }
                }
                if generation == token { stop() }
            } catch {
                guard generation == token else { return }
                stop(); status = error.localizedDescription
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
                }
            }
        }
    }
    func stop() {
        generation = UUID(); recording?.cancel(); recording = nil
        translating?.cancel(); translating = nil; capture?.stop(); capture = nil; queue = []
        busy = false; running = false; status = "Stopped."
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
                    }.buttonStyle(.borderedProminent).tint(.cyan)
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
                Section("Recent session text") {
                    ForEach(Array(model.history.enumerated()), id: \.offset) { _, text in Text(text).textSelection(.enabled) }
                }
                Section { Text("Keep Glacier in the foreground. iOS captions appear inside Glacier; the Mac's system-wide overlay and Word archive are not part of this iOS preview.").font(.caption) }
            }.scrollContentBackground(.hidden).background(Color.cyan.opacity(0.08)).navigationTitle("🧊 Glacier")
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() } }
    }
}

@main struct GlacierMobileApp: App {
    var body: some Scene { WindowGroup { MobileContent() } }
}
