import AppKit
import ApplicationServices

struct WisprSnapshot: Sendable {
    let meeting: String
    let segments: [TranscriptSegment]
    let recording: Bool?
}

// Reads only the open Wispr Meeting Recorder's transcript accessibility subtree.
// Uses public accessibility controls; full export temporarily uses the clipboard.
// No account tokens, historical files or private APIs.
actor WisprReader {
    static let shared = WisprReader()
    private var cachedRecorder: AXUIElement?
    private var cachedPID: pid_t?

    func recordingState() throws -> Bool? {
        guard let window = try recorder(appRoot()) else { return nil }
        return state(window)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private func label(_ element: AXUIElement) -> String {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].map { string(element, $0) }.joined(separator: " ")
    }
    private func find(_ root: AXUIElement, depth: Int = 0, budget: inout Int, matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 18, budget > 0 else { return nil }
        budget -= 1
        if matches(root) { return root }
        for child in children(root) {
            if let found = find(child, depth: depth + 1, budget: &budget, matches: matches) { return found }
        }
        return nil
    }
    private func controls(_ root: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 16 else { return [] }
        if label(root).contains("Meeting transcript") { return [] }
        if string(root, kAXRoleAttribute) == kAXButtonRole {
            return [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { string(root, $0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return children(root).flatMap { controls($0, depth: depth + 1) }
    }
    private func texts(_ root: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        let role = string(root, kAXRoleAttribute)
        if role == kAXButtonRole || role == kAXTextFieldRole || role == kAXTextAreaRole { return [] }
        if role == kAXStaticTextRole {
            let value = string(root, kAXValueAttribute)
            let text = value.isEmpty ? string(root, kAXTitleAttribute) : value
            return text.isEmpty ? [] : [text]
        }
        return children(root).flatMap { texts($0, depth: depth + 1) }
    }

    func snapshot() throws -> WisprSnapshot {
        guard AXIsProcessTrusted() else { throw CaptionError.message("当前版本尚未获系统授权。如果 Glacier 开关已打开，请关闭后重新打开；仍无效时移除旧条目，重新添加 ~/Applications/Glacier.app。") }
        let root = try appRoot()
        guard let window = try recorder(root) else {
            throw CaptionError.message("等待 Wispr 录音窗口…")
        }
        let buttons = controls(window)
        let stopped = buttons.contains { $0 == "Resume" || $0 == "Resume recording" }
        let active = buttons.contains { $0 == "Stop" || $0 == "Stop Notetaker" || $0 == "Stop recording" || $0 == "Stop listening" }
        let recording: Bool? = active ? true : stopped ? false : nil
        var titleBudget = 80
        let titleElement = find(window, budget: &titleBudget, matches: { string($0, kAXDescriptionAttribute) == "Title" })
        let currentTitle = titleElement.map { string($0, kAXValueAttribute) } ?? "Meeting Recorder"
        var budget = 500
        guard let transcript = find(window, budget: &budget, matches: { label($0).contains("Meeting transcript") }) else {
            if let recording { return WisprSnapshot(meeting: currentTitle, segments: [], recording: recording) }
            throw CaptionError.message("暂时读不到 Wispr Transcript。请打开该标签并保持窗口未最小化。")
        }
        let description = label(transcript)
        let pattern = try NSRegularExpression(pattern: "showing\\s+(\\d+)[–-](\\d+)\\s+of\\s+(\\d+)", options: .caseInsensitive)
        let range = NSRange(description.startIndex..., in: description)
        // Older Wispr exposes a virtualized range; the current release exposes
        // ordinary paragraph containers with speaker labels as separate static text.
        let rows = children(transcript).filter { string($0, kAXRoleAttribute) != kAXStaticTextRole }
            .map { texts($0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var end = rows.count
        if let match = pattern.firstMatch(in: description, range: range),
           let endRange = Range(match.range(at: 2), in: description),
           let totalRange = Range(match.range(at: 3), in: description),
           let visibleEnd = Int(description[endRange]), let total = Int(description[totalRange]) {
            guard visibleEnd == total else { throw CaptionError.message("请将 Wispr Transcript 滚动到最底部，以跟随最新讲话。") }
            end = visibleEnd
        } else if description.localizedCaseInsensitiveContains("showing") {
            throw CaptionError.message("无法确认 Wispr 转录滚动范围，请更新连接器。")
        }
        guard !rows.isEmpty else { return WisprSnapshot(meeting: currentTitle, segments: [], recording: recording) }
        let start = end - rows.count + 1
        let segments = rows.enumerated().map { TranscriptSegment(id: start + $0.offset, text: $0.element) }
        budget = 50
        let title = find(window, budget: &budget, matches: { string($0, kAXDescriptionAttribute) == "Title" })
        let meeting = title.map { string($0, kAXValueAttribute) } ?? "Meeting Recorder"
        return WisprSnapshot(meeting: meeting, segments: Array(segments.suffix(12)), recording: recording)
    }

    func fullTranscript(expectedMeeting: String) async throws -> String {
        let snapshot = try self.snapshot()
        guard snapshot.meeting == expectedMeeting, snapshot.recording == false else {
            throw CaptionError.message("请保持已结束的 Wispr Transcript 打开；当前会议状态不匹配。")
        }
        guard let window = try recorder(appRoot()) else {
            throw CaptionError.message("Wispr 转录窗口已关闭。")
        }
        var budget = 200
        guard let button = find(window, budget: &budget, matches: { element in
            string(element, kAXRoleAttribute) == kAXButtonRole && [kAXTitleAttribute, kAXDescriptionAttribute].contains { name in string(element, name) == "Copy transcript" }
        }) else { throw CaptionError.message("找不到 Wispr 的 Copy transcript 按钮，未导出不完整文本。") }
        let backup = await ClipboardSnapshot.capture()
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw CaptionError.message("无法通过 Wispr 的复制按钮获取完整文本。")
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let current = await ClipboardSnapshot.readText()
            if current.count != backup.count, let text = current.text, !text.isEmpty {
                // Verify the copied text belongs to this transcript before touching
                // the clipboard again, so an unrelated user copy is never restored over.
                let expected = snapshot.segments.last?.text ?? ""
                let probe = String(expected.prefix(80))
                guard !probe.isEmpty, text.contains(probe) else {
                    throw CaptionError.message("复制内容未通过会议校验，未导出。请重试。")
                }
                await backup.restore(ifUnchanged: current.count)
                let after = try self.snapshot()
                guard after.meeting == expectedMeeting, after.recording == false else {
                    throw CaptionError.message("获取原文时 Wispr 状态发生变化，已取消此次归档。")
                }
                return text
            }
        }
        throw CaptionError.message("Wispr 复制全文超时，请保持 Transcript 打开后重试归档。")
    }
}

private struct ClipboardSnapshot: Sendable {
    let count: Int
    let items: [[String: Data]]
    @MainActor static func capture() -> Self {
        let board = NSPasteboard.general
        return .init(count: board.changeCount, items: (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        })
    }
    @MainActor static func readText() -> (count: Int, text: String?) {
        (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string))
    }
    @MainActor func restore(ifUnchanged count: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return }
        let objects = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: .init(type)) }
            return item
        }
        board.clearContents(); board.writeObjects(objects)
    }
}

@MainActor
final class WisprCapture {
    private var task: Task<Void, Never>?
    private let reader = WisprReader.shared
    func start(status: @escaping (String) -> Void, snapshotChanged: @escaping (WisprSnapshot) -> Void,
               ended: @escaping (WisprSnapshot) -> Void, failure: @escaping (String) -> Void) {
        stop()
        task = Task {
            var meeting: String?
            var lastSegmentID: Int?
            var wasRecording = false
            var stoppedAt: Date?
            var stoppedText = ""
            var endDelivered = false
            while !Task.isCancelled {
                do {
                    let snapshot = try await reader.snapshot()
                    guard !Task.isCancelled else { return }
                    if let meeting, !snapshot.meeting.isEmpty, snapshot.meeting != meeting {
                        // Wispr may automatically rename the current note while recording.
                        // Only reject a simultaneous segment reset, not a title update alone.
                        if wasRecording && !endDelivered {
                            if let previous = lastSegmentID, let latest = snapshot.segments.last?.id, latest < previous {
                                failure("Wispr 的会议已切换；请先归档上一场，再重新连接。"); return
                            }
                        } else {
                            lastSegmentID = nil; stoppedAt = nil; endDelivered = false; wasRecording = false
                        }
                    }
                    if !snapshot.meeting.isEmpty { meeting = snapshot.meeting }
                    if let lastSegmentID, let first = snapshot.segments.first?.id, first > lastSegmentID + 1 {
                        failure("Wispr 窗口恢复后出现转录间隙，请重新连接以从当前进度继续。"); return
                    }
                    lastSegmentID = snapshot.segments.last?.id ?? lastSegmentID
                    snapshotChanged(snapshot)
                    if snapshot.recording == true {
                        wasRecording = true; stoppedAt = nil; endDelivered = false
                        status("Wispr 正在录音 · 实时跟随")
                    } else if snapshot.recording == false {
                        status("Wispr 已停止录音")
                        let text = snapshot.segments.map(\.text).joined(separator: "\n")
                        if stoppedAt == nil || stoppedText != text { stoppedAt = Date(); stoppedText = text }
                        if wasRecording, !endDelivered, Date().timeIntervalSince(stoppedAt!) >= 5 {
                            endDelivered = true; ended(snapshot)
                        }
                    } else { status("已连接 Wispr · 等待录音状态") }
                } catch {
                    guard !Task.isCancelled else { return }
                    status(error.localizedDescription)
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

// Public UI bridge: presses Wispr's own controls and verifies the resulting state.
// Never injects a global shortcut, which could type into an unrelated application.
extension WisprReader {
    private func appRoot() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw CaptionError.message("当前版本尚未获系统授权；若 Glacier 开关已开启，请关闭后重新开启，再重启 Glacier。") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow")
        guard let app = apps.first(where: { $0.bundleURL?.path == "/Applications/Wispr Flow.app" }) ?? apps.first else {
            throw CaptionError.message("Wispr 尚未打开。")
        }
        if cachedPID != app.processIdentifier { cachedRecorder = nil; cachedPID = app.processIdentifier }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        return root
    }
    private func recorder(_ root: AXUIElement) throws -> AXUIElement? {
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches = windows.filter { string($0, kAXTitleAttribute) == "Meeting Recorder" }
        guard matches.count <= 1 else { throw CaptionError.message("存在多个 Wispr 录音窗口，请先只保留一个。") }
        if let window = matches.first { cachedRecorder = window; return window }
        // Electron may omit its background window from AXWindows while the
        // previously resolved accessibility element remains valid.
        if let window = cachedRecorder, string(window, kAXTitleAttribute) == "Meeting Recorder" {
            return window
        }
        cachedRecorder = nil
        return nil
    }
    private func state(_ window: AXUIElement) -> Bool? {
        let labels = controls(window)
        if labels.contains(where: { ["Stop", "Stop Notetaker", "Stop recording", "Stop listening"].contains($0) }) { return true }
        if labels.contains(where: { ["Resume", "Resume recording"].contains($0) }) { return false }
        return nil
    }
    private func press(_ root: AXUIElement, names: [String], roles: [String] = [kAXButtonRole]) -> Bool {
        var budget = 2500
        guard let control = find(root, budget: &budget, matches: { element in
            roles.contains(string(element, kAXRoleAttribute)) &&
                [kAXTitleAttribute, kAXDescriptionAttribute].contains { names.contains(string(element, $0)) }
        }) else { return false }
        return AXUIElementPerformAction(control, kAXPressAction as CFString) == .success
    }
    private func clickStart(_ root: AXUIElement) async throws -> Bool {
        // Wispr can launch with only its Status widget. The app menu remains
        // available even when neither its hub nor recorder has been opened.
        if let bar = attribute(root, kAXMenuBarAttribute) {
            let menuBar = bar as! AXUIElement
            var menuBudget = 150
            if let notetaker = find(menuBar, budget: &menuBudget, matches: {
                string($0, kAXTitleAttribute) == "Notetaker"
            }), AXUIElementPerformAction(notetaker, kAXPressAction as CFString) == .success {
                try await Task.sleep(for: .milliseconds(150))
                var itemBudget = 200
                if let item = find(notetaker, budget: &itemBudget, matches: {
                    string($0, kAXRoleAttribute) == kAXMenuItemRole &&
                    string($0, kAXTitleAttribute) == "Start Notetaker" &&
                    (attribute($0, kAXEnabledAttribute) as? Bool) == true
                }), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return true }
                AXUIElementPerformAction(notetaker, kAXCancelAction as CFString)
            }
        }
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let hub = windows.first(where: { string($0, kAXTitleAttribute) == "Wispr Flow" })
                ?? windows.first(where: { string($0, kAXTitleAttribute) == "Meeting Recorder" }) else { return false }
        let isHub = string(hub, kAXTitleAttribute) == "Wispr Flow"
        let startLabels = isHub ? ["New note", "Start Notetaker"] : ["Home"]
        var budget = 2500
        guard let button = find(hub, budget: &budget, matches: { element in
            string(element, kAXRoleAttribute) == kAXButtonRole &&
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
                    startLabels.contains(string(element, $0))
                }
        }) else { return false }
        try await clickControl(button, in: hub)
        return isHub
    }
    private func clickControl(_ button: AXUIElement, in hub: AXUIElement) async throws {
        // Electron can acknowledge AXPress without invoking a background button.
        // Raise its own window and click the verified button's accessible bounds.
        let activated = await MainActor.run { () -> Bool in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow")
            guard let app = apps.first(where: { $0.bundleURL?.path == "/Applications/Wispr Flow.app" }) ?? apps.first else { return false }
            return app.activate(options: [.activateAllWindows])
        }
        guard activated else { throw CaptionError.message("无法激活 Wispr 窗口。") }
        try await Task.sleep(for: .milliseconds(300))
        AXUIElementPerformAction(hub, kAXRaiseAction as CFString)
        try await Task.sleep(for: .milliseconds(150))
        let foreground = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.electron.wispr-flow" }
        guard foreground else { throw CaptionError.message("当前前台已切换，未发送录音点击，请重试。") }
        guard let p = attribute(button, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(button, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else {
            throw CaptionError.message("无法定位 Wispr 录音按钮。")
        }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { throw CaptionError.message("Wispr 按钮位置暂不可用。") }
        point.x += size.width / 2; point.y += size.height / 2
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    func startNote() async throws {
        guard AXIsProcessTrusted() else { throw CaptionError.message("当前版本尚未获系统授权；若 Glacier 开关已开启，请关闭后重新开启，再重启 Glacier。") }
        let installed = await MainActor.run {
            let usual = URL(fileURLWithPath: "/Applications/Wispr Flow.app")
            return FileManager.default.fileExists(atPath: usual.path) ? usual : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.wispr-flow")
        }
        guard let installed else { throw CaptionError.message("此版本需要先安装并登录 Wispr Flow，尚未内置 Wispr 引擎。") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        for _ in 0..<20 {
            try Task.checkCancellation()
            let root = try appRoot()
            if let window = try recorder(root), state(window) == true {
                _ = press(window, names: ["Transcript"], roles: [kAXButtonRole, kAXRadioButtonRole])
                return // Reuse an active recording; never create a second one.
            }
            if try await clickStart(root) {
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(250))
                    if let window = try recorder(try appRoot()), state(window) == true {
                        _ = press(window, names: ["Transcript"], roles: [kAXButtonRole, kAXRadioButtonRole])
                        return
                    }
                }
                throw CaptionError.message("已请求 New note，但未确认开始录音。请查看 Wispr 的设置、额度或提示；不会重复点击。")
            }
            _ = press(root, names: ["Notetaker"])
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CaptionError.message("找不到 Wispr 的 New note 按钮。请打开 Wispr 主窗口的 Notetaker 页面后重试。")
    }
    func stopNote() async throws {
        // Electron can temporarily omit background windows from its AX tree.
        await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow")
            _ = (apps.first(where: { $0.bundleURL?.path == "/Applications/Wispr Flow.app" }) ?? apps.first)?.activate(options: [.activateAllWindows])
        }
        try await Task.sleep(for: .milliseconds(500))
        var stopWindow: AXUIElement?
        for _ in 0..<10 {
            stopWindow = try recorder(try appRoot())
            if stopWindow != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let window = stopWindow else { throw CaptionError.message("未找到 Wispr 录音窗口，无法确认停止。") }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        try await Task.sleep(for: .milliseconds(150))
        if state(window) == false { return }
        var budget = 2500
        guard let button = find(window, budget: &budget, matches: { element in
            string(element, kAXRoleAttribute) == kAXButtonRole &&
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
                ["Stop", "Stop Notetaker", "Stop recording", "Stop listening"].contains(string(element, $0))
            }
        }) else { throw CaptionError.message("Wispr 正在结束录音或停止按钮暂不可用，请稍后重试。") }
        try await clickControl(button, in: window)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if let updated = try recorder(try appRoot()), state(updated) == false { return }
        }
        throw CaptionError.message("尚未确认 Wispr 停止，请检查 Wispr 窗口。")
    }
}
