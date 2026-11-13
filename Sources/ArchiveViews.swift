import SwiftUI
import AppKit

struct ArchiveControls: View {
    @ObservedObject var model: CaptionModel
    @ObservedObject var archive: LectureArchive
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课后归档").font(.headline)
            TextField("课程名称（留空时由 AI 根据主要内容命名）", text: $model.courseName)
                .textFieldStyle(.roundedBorder)
            Toggle("Wispr 停止录音后自动生成 Word", isOn: $model.autoArchive)
            Text("保存到桌面同名文件夹：中文总结、思维导图、英文知识点提纲，然后完整英文原文，再完整中文翻译。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("归档当前已结束的录音") { model.archiveCurrent() }.disabled(archive.working)
                Button("继续未完成的归档") { archive.resume(model: model.gptModel) }.disabled(archive.working || !model.hasAPIKey)
            }
            Text(archive.status).font(.caption).textSelection(.enabled)
            if let url = archive.lastURL {
                Button("在 Finder 中查看 Word") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
        }
    }
}

struct HistoryView: View {
    let entries: [CaptionHistoryEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近 30 秒").font(.title2.bold())
            Text("按本应用收到字幕的时间回看；此窗口保留点击时的内容，实时字幕继续更新。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if entries.isEmpty { Text("还没有最近 30 秒的字幕。连接 Wispr 并开始讲话后，再从设置或菜单栏打开回看。").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.firstSeen, style: .time).font(.caption).foregroundStyle(.secondary)
                            Text(entry.cleanedEnglish.isEmpty ? entry.english : entry.cleanedEnglish).font(.custom("TimesNewRomanPSMT", size: 18))
                            if !entry.cleanedEnglish.isEmpty && entry.cleanedEnglish != entry.english {
                                Text("ASR: \(entry.english)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.chinese.isEmpty ? "尚无译文" : entry.chinese).font(.custom("STSongti-SC-Regular", size: 18))
                                .foregroundStyle(entry.chinese.isEmpty ? .secondary : .primary)
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }.padding(.trailing, 8)
            }
        }.padding(20).frame(minWidth: 400, minHeight: 260)
            .modifier(GlacierSurface())
    }
}
