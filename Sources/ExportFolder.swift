import Foundation
import AppKit
import GlacierCore

/// Persist the user's Powerbox grant, not just a path that stops working on restart.
@MainActor enum ExportFolder {
    private static let key = "exportFolderBookmark.v1"
    static func choose() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "选择课堂文档保存文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: key)
        return true
    }
    static func withAccess<T>(_ operation: (URL) throws -> T) throws -> T {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else {
            throw CaptionError.message("请先选择导出文件夹；原文和翻译进度已保存在应用内。")
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        guard started || !AppDistribution.isStore else { throw CaptionError.message("导出权限已失效，请重新选择保存文件夹。") }
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        if stale { UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: key) }
        return try operation(url)
    }
}

