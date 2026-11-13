import AppKit
import Combine

@MainActor
final class IceLauncher {
    private let model: CaptionModel
    private let panel: NSPanel
    private let ice: IceButtonView
    private var subscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var notice: NSPanel?
    private var dismissNotice: Task<Void, Never>?
    init(model: CaptionModel) {
        self.model = model
        panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Glacier · 冰块快捷录音"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        ice = IceButtonView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        ice.model = model
        panel.contentView = ice
        place()
        refresh()
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
    }
    func showStartedNotice() { showNotice("已开启录音") }
    func showStoppedNotice() { showNotice("已停止录音") }
    private func showNotice(_ text: String) {
        dismissNotice?.cancel()
        notice?.orderOut(nil)
        let frame = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width: CGFloat = 100
        let x = min(frame.maxX - width - 2, max(frame.minX + 2, panel.frame.midX - width / 2))
        let tip = SubtitlePanel(contentRect: NSRect(x: x, y: max(frame.minY, panel.frame.minY - 23), width: width, height: 20),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tip.title = "Glacier · 录音提示"
        tip.level = .statusBar; tip.collectionBehavior = panel.collectionBehavior
        tip.isOpaque = false; tip.backgroundColor = .clear; tip.hasShadow = false
        tip.ignoresMouseEvents = true; tip.hidesOnDeactivate = false; tip.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12); label.textColor = .black
        label.alignment = .center; label.backgroundColor = .clear; label.drawsBackground = false
        label.frame = NSRect(x: 0, y: 1, width: width, height: 18)
        tip.contentView = label
        notice = tip; tip.orderFrontRegardless()
        dismissNotice = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.notice?.orderOut(nil); self?.notice = nil
        }
    }
    private func place() {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(panel.frame.origin) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let saved = UserDefaults.standard.object(forKey: "iceVerticalFraction") as? Double ?? 0.55
        let left = UserDefaults.standard.bool(forKey: "iceOnLeft")
        panel.setFrameOrigin(NSPoint(x: left ? frame.minX + 6 : frame.maxX - 62,
                                     y: frame.minY + min(1, max(0, saved)) * (frame.height - 56)))
    }
    private func refresh() {
        ice.needsDisplay = true
        ice.toolTip = model.quickBusy ? "正在联动 Wispr…" : model.finishingRecording ? "正在获取完整转录…" :
            "点击冰块开始／停止录音 · 右键查看30秒文本 · 可拖动\n\(model.status)"
        ice.setAccessibilityLabel(ice.toolTip)
        if model.quickVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
}

@MainActor
final class IceButtonView: NSView {
    weak var model: CaptionModel?
    private var down = NSPoint.zero
    private var origin = NSPoint.zero
    private var dragged = false
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var hoverTracking: NSTrackingArea?
    override var isOpaque: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
        if let window { hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityPerformPress() -> Bool { model?.quickToggle(showSettingsOnFailure: false); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        if hovered {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18)
        NSGradient(starting: NSColor(srgbRed: 0.89, green: 0.98, blue: 1, alpha: 0.97),
                   ending: NSColor(srgbRed: 0.57, green: 0.82, blue: 0.98, alpha: 0.97))!.draw(in: shape, angle: -80)
        NSColor.white.withAlphaComponent(0.85).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        let emoji = NSAttributedString(string: "🧊", attributes: [.font: NSFont(name: "Apple Color Emoji", size: 35)!])
        let size = emoji.size()
        emoji.draw(at: NSPoint(x: (56 - size.width) / 2, y: (56 - size.height) / 2 + 1))
        if model?.quickBusy == true || model?.finishingRecording == true {
            ("···" as NSString).draw(at: NSPoint(x: 20, y: 0), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
        } else if model?.wisprRecording == true || (model?.inputMode != "wispr" && model?.running == true) {
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: 41, y: 5, width: 9, height: 9)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) { down = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x - down.x, point.y - down.y) > 4 { dragged = true }
        guard dragged else { return }
        window?.setFrameOrigin(NSPoint(x: origin.x + point.x - down.x, y: origin.y + point.y - down.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { snap() } else { model?.quickToggle(showSettingsOnFailure: false) }
    }
    private func snap() {
        guard let window, let frame = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame else { return }
        let left = window.frame.midX < frame.midX
        let y = min(frame.maxY - 56, max(frame.minY, window.frame.minY))
        window.setFrameOrigin(NSPoint(x: left ? frame.minX + 6 : frame.maxX - 62, y: y))
        UserDefaults.standard.set(left, forKey: "iceOnLeft")
        UserDefaults.standard.set((y - frame.minY) / max(1, frame.height - 56), forKey: "iceVerticalFraction")
    }
    override func rightMouseDown(with event: NSEvent) { showQuickMenu() }
    private func showQuickMenu() {
        guard let model else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let recording = model.wisprRecording || (model.inputMode != "wispr" && model.running)
        let record = NSMenuItem(title: recording ? "停止录音" : "开始录音", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        record.isEnabled = !model.quickBusy && (!model.busy || model.canCancelCapture) && !model.finishingRecording
        record.toolTip = model.status
        menu.addItem(record)
        let history = NSMenuItem(title: "查看30秒文本", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }
    @objc private func toggleRecording() { model?.quickToggle(showSettingsOnFailure: false) }
    @objc private func showHistory() { model?.openHistory?() }
}
