#if APP_STORE
import Foundation
import GlacierCore

/// Headless smoke path for a locally ad-hoc signed sandbox bundle. Never records,
/// reads real keys, uploads data, or changes production preference values.
@MainActor enum StoreEnvironmentCheck {
    static func run() throws {
        guard AppDistribution.isStore, let identifier = Bundle.main.bundleIdentifier,
              AppDistribution.supportDirectory.path.contains("/Containers/" + identifier + "/Data/") else {
            throw CaptionError.message("Expected an App Sandbox Application Support container.")
        }
        let folder = AppDistribution.supportDirectory.appendingPathComponent("ReleaseSelfCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = CredentialConfig(url: folder.appendingPathComponent("config.json"))
        try config.save("non-secret-fixture", provider: "self-check")
        let reopened = CredentialConfig(url: config.url)
        guard try reopened.read("self-check").key == "non-secret-fixture" else {
            throw CaptionError.message("Container credential persistence failed.")
        }
        try reopened.save(nil, provider: "self-check")
        guard try reopened.read("self-check").disabled else { throw CaptionError.message("Removed credential resurrected.") }
        let key = "release-self-check-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        guard UserDefaults.standard.bool(forKey: key) else { throw CaptionError.message("Sandbox preferences unavailable.") }
        var denied = false
        do { try CloudConsent.require("release-self-check", .text) } catch { denied = true }
        guard denied else { throw CaptionError.message("Cloud consent did not fail closed.") }
        print("PASS: real sandbox container, reopened credential file, deletion tombstone, preferences and default-denied cloud consent")
    }
}
#endif
