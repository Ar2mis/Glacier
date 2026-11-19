import Foundation

/// Bundle metadata works in the shared Swift package as well as either app target.
public enum AppDistribution {
    public static var isStore: Bool { Bundle.main.object(forInfoDictionaryKey: "GlacierDistribution") as? String == "store" }
    public static var isDevelopment: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true }
    public static var dataDirectoryName: String { isDevelopment ? "Glacier Dev" : "Glacier" }
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    public static var credentialService: String { (Bundle.main.bundleIdentifier ?? "local.ar2mis.lecturecaptions") + ".credentials" }
}

/// Consent is per recipient and data type. Merely pasting a key grants no consent.
public enum CloudConsent {
    public enum Kind: String { case audio, text }
    public static func key(_ provider: String, _ kind: Kind) -> String { "cloudConsent.v1.\(provider).\(kind.rawValue)" }
    public static func allowed(_ provider: String, _ kind: Kind, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(provider, kind))
    }
    public static func set(_ allowed: Bool, provider: String, kind: Kind, defaults: UserDefaults = .standard) {
        defaults.set(allowed, forKey: key(provider, kind))
    }
    public static func require(_ provider: String, _ kind: Kind, defaults: UserDefaults = .standard,
                               enforced: Bool = AppDistribution.isStore) throws {
        guard !enforced || allowed(provider, kind, defaults: defaults) else {
            throw GlacierCoreError.message("Cloud sharing is off. In Settings, explicitly allow sending \(kind.rawValue) to \(provider), or use on-device processing.")
        }
    }
}
