import Foundation
import Darwin

/// Private macOS credentials outside the rebuilt bundle. Plaintext with filesystem
/// permissions, not encryption. iOS continues using its protected Keychain.
public struct CredentialConfig {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL {
        AppDistribution.supportDirectory.appendingPathComponent("config.json")
    }
    private func access<T>(_ operation: (inout [String: Any]) throws -> (T, Bool)) throws -> T {
        let fm = FileManager.default, folder = url.deletingLastPathComponent()
        guard !((try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false),
              !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else {
            throw GlacierCoreError.message("Glacier credential storage must not be a symbolic link.")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let fd = open(folder.appendingPathComponent(".config.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GlacierCoreError.message("Cannot lock Glacier credential storage.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw GlacierCoreError.message("Cannot lock Glacier credential storage.") }
        var object: [String: Any] = ["version": 1, "credentials": [String: String]()]
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  saved["credentials"] is [String: String],
                  saved["disabled"] == nil || saved["disabled"] is [String] else {
                throw GlacierCoreError.message("Glacier config.json is unreadable or invalid; it was preserved.")
            }
            object = saved
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let (result, changed) = try operation(&object)
        if changed {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return result
    }
    public func read(_ provider: String) throws -> (key: String?, disabled: Bool) {
        try access { object in
            let key = (object["credentials"] as? [String: String])?[provider]
            return ((key, (object["disabled"] as? [String] ?? []).contains(provider)), false)
        }
    }
    public func save(_ key: String?, provider: String) throws {
        try access { object in
            var keys = object["credentials"] as? [String: String] ?? [:]
            var disabled = Set(object["disabled"] as? [String] ?? [])
            keys[provider] = key
            if key == nil { disabled.insert(provider) } else { disabled.remove(provider) }
            object["credentials"] = keys; object["disabled"] = disabled.sorted()
            return ((), true)
        }
    }
}

/// Injected dependencies keep credential tests away from the real Keychain.
public struct CredentialRepository {
    public let config: CredentialConfig?
    public let environment: [String: String]
    public let keychainRead: (String, Bool) throws -> String
    public let keychainSave: (String, String) throws -> Void
    public let keychainDelete: (String) throws -> Void
    public init(config: CredentialConfig?, environment: [String: String],
                keychainRead: @escaping (String, Bool) throws -> String,
                keychainSave: @escaping (String, String) throws -> Void,
                keychainDelete: @escaping (String) throws -> Void) {
        self.config = config; self.environment = environment; self.keychainRead = keychainRead
        self.keychainSave = keychainSave; self.keychainDelete = keychainDelete
    }
    private func normalized(_ key: String) throws -> String {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }), value.count < 4096 else {
            throw GlacierCoreError.message("Enter a nonempty API key without spaces.")
        }
        return value
    }
    public func read(_ provider: String, allowInteraction: Bool = false) throws -> String {
        if let saved = try config?.read(provider) {
            if let key = saved.key { return try normalized(key) }
            if saved.disabled { throw GlacierCoreError.message("Save the \(provider) API key in Settings.") }
        }
        if let value = environment[provider.uppercased() + "_API_KEY"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = try normalized(value)
            try config?.save(key, provider: provider)
            return key
        }
        let key = try normalized(keychainRead(provider, allowInteraction))
        try config?.save(key, provider: provider)
        return key
    }
    public func save(_ value: String, provider: String) throws {
        let key = try normalized(value)
        if let config {
            try config.save(key, provider: provider)
            try? keychainSave(key, provider)
        } else { try keychainSave(key, provider) }
    }
    public func delete(_ provider: String) throws {
        if let config {
            try config.save(nil, provider: provider) // Don't resurrect stale Keychain/env values.
            try? keychainDelete(provider)
        } else { try keychainDelete(provider) }
    }
}
