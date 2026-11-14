import Foundation
import Darwin

public struct LectureSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let created: Date
    public let course: String
    public let source: String
    public let glossary: String
    public let archiveModel: String
    public let archiveProvider: String
    public let autoArchive: Bool
    public var ended: Date?
    public var warning: String?
    public var exportedURL: URL?
    public var ownerPID: Int32?
    public init(id: UUID = UUID(), created: Date = Date(), course: String, source: String, glossary: String,
                archiveModel: String, archiveProvider: String = "openai", autoArchive: Bool = true) {
        self.ownerPID = getpid()
        self.id = id; self.created = created; self.course = course; self.source = source; self.glossary = glossary
        self.archiveModel = archiveModel; self.archiveProvider = archiveProvider; self.autoArchive = autoArchive
    }
}

public struct SavedUtterance: Codable, Sendable {
    public let id: Int
    public let text: String
    public let isFinal: Bool
}

/// Separate from the bounded caption history. Each utterance is atomically replaced
/// on disk, so partial revisions neither duplicate text nor rewrite a whole lecture.
/// No API keys or raw microphone audio are stored here.
public actor LectureSessionStore {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glacier/Lectures", isDirectory: true)
    }
    public let directory: URL
    public init(directory: URL = LectureSessionStore.defaultDirectory) { self.directory = directory }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func metadata(_ id: UUID) -> URL { folder(id).appendingPathComponent("session.json") }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        // Atomic replacement uses a private temporary file inside a private directory.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func create(_ session: LectureSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: folder(session.id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write(session, to: metadata(session.id))
    }
    public func session(_ id: UUID) throws -> LectureSession {
        try JSONDecoder().decode(LectureSession.self, from: Data(contentsOf: metadata(id)))
    }
    public func append(_ event: TranscriptEvent, to id: UUID) throws {
        guard event.id >= 0 else { throw GlacierCoreError.message("Invalid lecture utterance ID.") }
        guard try session(id).ended == nil else { throw GlacierCoreError.message("Lecture is already closed.") }
        let url = folder(id).appendingPathComponent("utterance-\(event.id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try JSONDecoder().decode(SavedUtterance.self, from: Data(contentsOf: url))
            if old.isFinal && !event.isFinal { return }
        }
        try write(SavedUtterance(id: event.id, text: event.text, isFinal: event.isFinal), to: url)
    }
    public func utterances(_ id: UUID) throws -> [SavedUtterance] {
        try FileManager.default.contentsOfDirectory(at: folder(id), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("utterance-") && $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(SavedUtterance.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }
    public func english(_ id: UUID) throws -> String {
        try utterances(id).map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }
    public func finish(_ id: UUID, warning: String? = nil) throws -> LectureSession {
        var value = try session(id)
        if value.ended == nil { value.ended = Date() }
        if let warning { value.warning = warning }
        if try utterances(id).contains(where: { !$0.isFinal }), value.warning == nil {
            value.warning = "Recording ended before all speech was finalized; provisional ASR text is retained."
        }
        try Data(english(id).utf8).write(to: folder(id).appendingPathComponent("English.txt"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder(id).appendingPathComponent("English.txt").path)
        try write(value, to: metadata(id)); return value
    }
    public func markExported(_ id: UUID, url: URL) throws {
        guard FileManager.default.fileExists(atPath: metadata(id).path) else { return } // Legacy Wispr archive.
        var value = try session(id); value.exportedURL = url
        try write(value, to: metadata(id))
    }
    public func isStillRecordingElsewhere(_ session: LectureSession) -> Bool {
        guard session.ended == nil, let pid = session.ownerPID else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    public func pending() throws -> [LectureSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try session(UUID(uuidString: $0.lastPathComponent)!) }
            .filter { $0.exportedURL == nil }.sorted { $0.created < $1.created }
    }
}
