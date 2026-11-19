import AppKit
import SwiftUI
import GlacierCore

struct CloudSharingToggle: View {
    let title: String
    @AppStorage private var consent: Bool
    init(_ title: String, provider: String, kind: CloudConsent.Kind) {
        self.title = title
        _consent = AppStorage(wrappedValue: false, CloudConsent.key(provider, kind))
    }
    var body: some View { Toggle(title, isOn: $consent) }
}

@MainActor final class PolicyPresentation: ObservableObject { @Published var document: String? }

struct CloudPrivacyControls: View {
    @ObservedObject var model: CaptionModel
    @StateObject private var policy = PolicyPresentation()
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("隐私与云端授权").font(.headline)
            Text("本机识别与 Apple 翻译无需此授权。开启云端后，所选服务会收到课堂文字、术语和上下文，或麦克风音频；完整归档还会发送整份转录。对方按自己的政策处理数据。保存 API key 不代表同意发送。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(AIProvider.allCases) { provider in
                CloudSharingToggle("允许向 \(provider.title) 发送文字（翻译 / 总结）", provider: provider.rawValue, kind: .text)
            }
            CloudSharingToggle("允许向 OpenAI 发送麦克风音频", provider: "openai", kind: .audio)
            CloudSharingToggle("允许向 Deepgram 发送麦克风音频", provider: "deepgram", kind: .audio)
            HStack {
                Button("隐私政策") { policy.document = "PRIVACY_POLICY" }
                Button("帮助与支持") { policy.document = "SUPPORT" }
                Button("查看本机课堂数据") { NSWorkspace.shared.open(AppDistribution.supportDirectory) }
            }
        }
        .disabled(model.running || model.busy || model.archive.working)
        .sheet(isPresented: Binding(get: { policy.document != nil }, set: { if !$0 { policy.document = nil } })) {
            VStack(alignment: .leading) {
                ScrollView {
                    Text(policy.document.flatMap { Bundle.main.url(forResource: $0, withExtension: "md") }
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "See https://github.com/Ar2mis/Glacier for policy and support.")
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("关闭") { policy.document = nil }
            }.padding(24).frame(width: 580, height: 580)
        }
    }
}
