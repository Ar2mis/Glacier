import SwiftUI
import AppKit

enum GlacierTheme {
    static let ink = Color(red: 0.12, green: 0.28, blue: 0.40)
    static let accent = Color(red: 0.24, green: 0.62, blue: 0.85)
    static let window = NSColor(srgbRed: 0.84, green: 0.94, blue: 0.99, alpha: 1)
    static var background: some View {
        LinearGradient(colors: [Color(red: 0.91, green: 0.97, blue: 1),
                                Color(red: 0.78, green: 0.91, blue: 0.99),
                                Color(red: 0.88, green: 0.96, blue: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func style(_ window: NSWindow) {
        window.backgroundColor = Self.window
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
    }
}

struct GlacierSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(GlacierTheme.ink)
            .tint(GlacierTheme.accent)
            .buttonStyle(GlacierButtonStyle())
            .background { GlacierTheme.background.ignoresSafeArea() }
            .preferredColorScheme(.light)
    }
}

struct GlacierButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(GlacierTheme.ink.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(.white.opacity(configuration.isPressed ? 0.35 : 0.12), in: RoundedRectangle(cornerRadius: 11))
            .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.7), lineWidth: 0.7) }
            .opacity(enabled ? 1 : 0.6)
    }
}
