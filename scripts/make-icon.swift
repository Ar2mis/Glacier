import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let n = CGFloat(pixels)
        let rect = NSRect(x: n * 0.05, y: n * 0.05, width: n * 0.90, height: n * 0.90)
        let shape = NSBezierPath(roundedRect: rect, xRadius: n * 0.21, yRadius: n * 0.21)
        NSGradient(starting: NSColor(srgbRed: 0.87, green: 0.97, blue: 1, alpha: 1),
                   ending: NSColor(srgbRed: 0.55, green: 0.80, blue: 0.98, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor.white.withAlphaComponent(0.65).setStroke()
        shape.lineWidth = max(1, n * 0.006); shape.stroke()
        let emoji = NSAttributedString(string: "🧊", attributes: [.font: NSFont(name: "Apple Color Emoji", size: n * 0.64)!])
        let measured = emoji.size()
        emoji.draw(at: NSPoint(x: (n - measured.width) / 2, y: (n - measured.height) / 2 + n * 0.015))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
