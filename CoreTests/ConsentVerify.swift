import Foundation
import GlacierCore

func verifyCloudConsent() throws {
    let name = "GlacierConsentTest-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    do { try CloudConsent.require("openai", .text, defaults: defaults, enforced: true); preconditionFailure("Default allowed cloud") } catch { }
    CloudConsent.set(true, provider: "openai", kind: .text, defaults: defaults)
    try CloudConsent.require("openai", .text, defaults: UserDefaults(suiteName: name)!, enforced: true)
    for (provider, kind) in [("openai", CloudConsent.Kind.audio), ("deepgram", .audio), ("gemini", .text)] {
        do { try CloudConsent.require(provider, kind, defaults: defaults, enforced: true); preconditionFailure("Consent crossed data type/provider") } catch { }
    }
    CloudConsent.set(false, provider: "openai", kind: .text, defaults: defaults)
    do { try CloudConsent.require("openai", .text, defaults: defaults, enforced: true); preconditionFailure("Revocation ignored") } catch { }
    print("PASS: cloud consent defaults denied, persists, isolates providers/audio/text and can be revoked")
}
