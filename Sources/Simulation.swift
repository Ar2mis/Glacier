import Foundation
import AppKit

// Runs the normal CaptionModel ingress, scheduler, history and overlay. The
// simulated translator is explicit: this is not an API accuracy benchmark.
@MainActor enum GlacierSimulation {
    static let lines: [(String, String)] = [
        ("The cell membrane allows water to pass through.", "细胞膜允许水通过。"),
        ("This movement of water is called osmosis.", "水的这种移动称为渗透。"),
        ("Water moves toward the side with a higher solute concentration.", "水向溶质浓度较高的一侧移动。"),
        ("The membrane is selectively permeable, not completely open.", "细胞膜具有选择透过性，并非完全开放。"),
        ("At equilibrium, water still moves in both directions.", "达到平衡时，水仍然向两个方向移动。"),
        ("There is no net movement of water across the membrane.", "此时没有跨膜水分的净移动。")
    ]
    static func makeModel() -> CaptionModel {
        if CommandLine.arguments.contains("--simulate-local") {
            return CaptionModel(simulation: true) { _, _, _, _ in
                throw TranslationFailure(kind: .quota, message: "模拟云端不可用（未请求云端）")
            }
        }
        guard CommandLine.arguments.contains("--simulate") else { return CaptionModel() }
        let pairs = Dictionary(uniqueKeysWithValues: lines)
        return CaptionModel(simulation: true) { source, _, _, update in
            guard let translated = pairs[source] else { throw TranslationFailure(kind: .incomplete, message: "模拟句子未配置") }
            var partial = ""
            for character in translated {
                try await Task.sleep(for: .milliseconds(45))
                partial.append(character)
                await update(partial)
            }
            return translated
        }
    }
    static func run(_ model: CaptionModel) async {
        var segments = [TranscriptSegment]()
        for (index, line) in lines.enumerated() {
            guard !Task.isCancelled else { return }
            segments.append(.init(id: index, text: line.0))
            model.receive(.init(meeting: "模拟生物课堂", segments: segments, recording: true))
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, model.running else { return }
                model.receive(.init(meeting: "模拟生物课堂", segments: segments, recording: true))
            }
        }
        model.receive(.init(meeting: "模拟生物课堂", segments: segments, recording: false))
        model.status = "模拟完成 · 未开启麦克风、Wispr 或云端 API"
        if CommandLine.arguments.contains("--simulate-exit") { NSApp.terminate(nil) }
    }
}
