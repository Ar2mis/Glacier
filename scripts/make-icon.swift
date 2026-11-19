import AppKit
import Foundation

// Original Glacier artwork: geometric paths and gradients only; no fonts,
// emoji, downloaded artwork, or external image dependencies.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
if let assets { try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
    path.close(); path.lineJoinStyle = .round; return path
}
func render(_ pixels: Int, opaque: Bool) throws -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let background = opaque ? NSBezierPath(rect: canvas) : NSBezierPath(roundedRect: canvas.insetBy(dx: 44, dy: 44), xRadius: 202, yRadius: 202)
    NSGradient(starting: color(0.91, 0.98, 1), ending: color(0.56, 0.81, 0.96))!.draw(in: background, angle: -70)
    // A soft, directional shadow anchors the floating crystal.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0.08, 0.35, 0.52, 0.22); shadow.shadowBlurRadius = 42; shadow.shadowOffset = NSSize(width: 0, height: -22); shadow.set()
    color(0.39, 0.68, 0.87).setFill()
    polygon([(512, 820), (792, 660), (792, 346), (512, 184), (232, 346), (232, 660)]).fill()
    NSGraphicsContext.restoreGraphicsState()
    let top = polygon([(512, 820), (792, 660), (512, 498), (232, 660)])
    let left = polygon([(232, 660), (512, 498), (512, 184), (232, 346)])
    let right = polygon([(512, 498), (792, 660), (792, 346), (512, 184)])
    NSGradient(starting: color(0.99, 1, 1), ending: color(0.66, 0.91, 0.99))!.draw(in: top, angle: -65)
    NSGradient(starting: color(0.74, 0.94, 1), ending: color(0.31, 0.67, 0.88))!.draw(in: left, angle: -65)
    NSGradient(starting: color(0.49, 0.81, 0.96), ending: color(0.22, 0.53, 0.78))!.draw(in: right, angle: -100)
    for face in [top, left, right] { color(1, 1, 1, 0.70).setStroke(); face.lineWidth = 8; face.stroke() }
    // Refracted inner facets are deliberately asymmetric.
    color(1, 1, 1, 0.25).setFill(); polygon([(268, 625), (474, 507), (474, 257), (404, 397)]).fill()
    color(0.77, 0.97, 1, 0.34).setFill(); polygon([(548, 481), (756, 600), (756, 371), (645, 337)]).fill()
    color(1, 1, 1, 0.82).setStroke()
    let gleam = NSBezierPath(); gleam.move(to: NSPoint(x: 299, y: 663)); gleam.line(to: NSPoint(x: 508, y: 784)); gleam.line(to: NSPoint(x: 673, y: 689)); gleam.lineWidth = 10; gleam.lineCapStyle = .round; gleam.lineJoinStyle = .round; gleam.stroke()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let data = try render(size * scale, opaque: false)
        try data.write(to: output.appendingPathComponent(name))
        if let assets {
            try data.write(to: assets.appendingPathComponent(name))
            entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
        }
    }
}
if let assets {
    for (idiom, size, scales) in [("iphone", 20.0, [2,3]), ("iphone", 29, [2,3]), ("iphone", 40, [2,3]), ("iphone", 60, [2,3]), ("ipad", 20, [1,2]), ("ipad", 29, [1,2]), ("ipad", 40, [1,2]), ("ipad", 76, [1,2]), ("ipad", 83.5, [2]), ("ios-marketing", 1024, [1])] {
        let label = size == Double(Int(size)) ? String(Int(size)) : String(size)
        for scale in scales {
            let name = "\(idiom)_\(label)@\(scale)x.png"
            try render(Int(size * Double(scale)), opaque: true).write(to: assets.appendingPathComponent(name))
            entries.append(["idiom": idiom, "size": "\(label)x\(label)", "scale": "\(scale)x", "filename": name])
        }
    }
    try JSONSerialization.data(withJSONObject: ["images": entries, "info": ["version": 1, "author": "Glacier"]], options: [.prettyPrinted, .sortedKeys]).write(to: assets.appendingPathComponent("Contents.json"))
    try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "Glacier"]], options: [.prettyPrinted, .sortedKeys]).write(to: assets.deletingLastPathComponent().appendingPathComponent("Contents.json"))
}
