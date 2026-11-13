import Foundation
import AppKit

enum WordExporter {
    static func xml(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 || [9, 10, 13].contains($0.value) })
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func paragraph(_ text: String, style: String = "Normal", newPage: Bool = false) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/>\(newPage ? "<w:pageBreakBefore/>" : "")</w:pPr><w:r><w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r></w:p>"
    }
    static func export(_ job: ArchiveJob, desktop: URL) throws -> URL {
        guard let digest = job.digest, job.translations.map(\.id).sorted() == job.parts.map(\.id),
              job.parts.map(\.text).joined() == job.english else {
            throw CaptionError.message("文档完整性校验失败，未保存为完整课堂记录。")
        }
        let folder = desktop.appendingPathComponent(ArchiveText.safeName(job.course.isEmpty ? digest.title : job.course), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let name = "\(formatter.string(from: job.created)) \(ArchiveText.safeName(digest.title)) \(job.id.uuidString.prefix(6))"
        let output = folder.appendingPathComponent(name + ".docx")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let working = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: working) }
        for directory in ["_rels", "word/_rels", "word/media", "docProps"] {
            try FileManager.default.createDirectory(at: working.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ content: String) throws {
            try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + content).write(to: working.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let map = try mindMap(digest)
        try map.data.write(to: working.appendingPathComponent("word/media/mindmap.png"))
        let title = job.course.isEmpty ? digest.title : job.course + " " + digest.title
        var body = paragraph(title, style: "Title")
        body += paragraph("\(formatter.string(from: job.created))  来源 Wispr Note", style: "Subtitle")
        body += paragraph("本文件保存本次录音的完整英文转录与完整中文翻译，并提供中文课堂总结、思维导图和英文知识点提纲，供课后复习。学习材料及中文译文由 AI 根据转录生成，原文保留 Wispr 识别结果。")
        body += paragraph("中文课堂总结", style: "Heading1")
        for section in digest.chineseSummary { body += paragraph(section) }
        body += paragraph("思维导图", style: "Heading1", newPage: true)
        let width: Int = 5_700_000
        let height = Int(Double(width) * map.height / map.width)
        body += """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="1" name="思维导图" descr="\(xml(digest.mindMap.map { $0.title + "：" + $0.points.joined(separator: "；") }.joined(separator: "。")))"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="mindmap.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
        body += paragraph("Key Knowledge Outline", style: "Heading1", newPage: true)
        for (index, branch) in digest.englishOutline.enumerated() {
            body += paragraph("\(index + 1)  \(branch.title)", style: "Heading2")
            for point in branch.points { body += paragraph("• " + point) }
        }
        body += paragraph("完整英文转录", style: "Heading1", newPage: true)
        for line in job.english.components(separatedBy: .newlines) { body += paragraph(line, style: line.hasPrefix("Speaker ") && line.count < 80 ? "Speaker" : "Normal") }
        body += paragraph("完整中文翻译", style: "Heading1", newPage: true)
        for part in job.translations.sorted(by: { $0.id < $1.id }) {
            for line in part.chinese.components(separatedBy: .newlines) { body += paragraph(line) }
        }
        body += "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1080\" w:right=\"1080\" w:bottom=\"1080\" w:left=\"1080\" w:header=\"500\" w:footer=\"500\"/></w:sectPr>"
        try write("word/document.xml", """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """)
        try write("word/styles.xml", """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="Songti SC"/><w:sz w:val="22"/><w:color w:val="000000"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/><w:widowControl/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Speaker"><w:name w:val="Speaker"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:after="180"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/><w:color w:val="000000"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="20"/><w:color w:val="000000"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="160"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:color w:val="000000"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="180" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="25"/><w:color w:val="000000"/></w:rPr></w:style>
        </w:styles>
        """)
        try write("word/footer1.xml", "<w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:fldSimple w:instr=\"PAGE\"><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p></w:ftr>")
        try write("word/_rels/document.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"rIdImage\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/mindmap.png\"/><Relationship Id=\"rIdFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/></Relationships>")
        try write("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        try write("[Content_Types].xml", """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>
        """)
        let archive = working.appendingPathComponent("result.docx")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = working
        zip.arguments = ["-q", "-r", archive.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CaptionError.message("Word 文档打包失败。") }
        try FileManager.default.moveItem(at: archive, to: output)
        return output
    }

    static func mindMap(_ digest: LectureDigest) throws -> (data: Data, width: Double, height: Double) {
        let width = 1400, height = max(800, digest.mindMap.count * 240 + 80)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CaptionError.message("思维导图渲染失败。") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        func node(_ rect: NSRect, _ text: String, major: Bool) {
            (major ? NSColor(calibratedRed: 0.9, green: 0.94, blue: 0.98, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
            let inner = rect.insetBy(dx: 16, dy: 12)
            var size: CGFloat = major ? 30 : 28
            var attrs: [NSAttributedString.Key: Any] = [:]
            var bounds = NSRect.zero
            repeat {
                let font = NSFont.systemFont(ofSize: size, weight: major ? .semibold : .regular)
                attrs = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]
                bounds = (text as NSString).boundingRect(with: inner.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
                size -= 1
            } while bounds.height > inner.height && size >= 18
            let drawing = NSRect(x: inner.minX, y: inner.midY - bounds.height / 2, width: inner.width, height: bounds.height)
            (text as NSString).draw(with: drawing, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        }
        func line(_ a: NSPoint, _ b: NSPoint) {
            NSColor(calibratedRed: 0.45, green: 0.55, blue: 0.65, alpha: 1).setStroke()
            let path = NSBezierPath(); path.lineWidth = 3; path.move(to: a)
            path.curve(to: b, controlPoint1: NSPoint(x: (a.x+b.x)/2, y: a.y), controlPoint2: NSPoint(x: (a.x+b.x)/2, y: b.y)); path.stroke()
        }
        let root = NSRect(x: 20, y: Double(height)/2 - 130, width: 240, height: 260)
        for (index, branch) in digest.mindMap.enumerated() {
            let center = Double(height) - 160 - Double(index) * 240
            let branchRect = NSRect(x: 330, y: center - 52, width: 300, height: 104)
            line(NSPoint(x: root.maxX, y: root.midY), NSPoint(x: branchRect.minX, y: center))
            for (pointIndex, point) in branch.points.enumerated() {
                let y = center + Double(branch.points.count - 1) * 38 - Double(pointIndex) * 76
                let leaf = NSRect(x: 710, y: y - 34, width: 665, height: 68)
                line(NSPoint(x: branchRect.maxX, y: center), NSPoint(x: leaf.minX, y: y)); node(leaf, point, major: false)
            }
            node(branchRect, branch.title, major: true)
        }
        node(root, digest.title, major: true)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptionError.message("无法生成思维导图图片。") }
        return (png, Double(width), Double(height))
    }
}
