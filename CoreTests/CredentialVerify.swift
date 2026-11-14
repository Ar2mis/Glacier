import Foundation
import GlacierCore

func verifyCredentialPersistence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = CredentialConfig(url: directory.appendingPathComponent("Glacier/config.json"))
    var reads = 0
    func repository(_ env: [String: String] = [:]) -> CredentialRepository {
        .init(config: config, environment: env, keychainRead: { _, _ in
            reads += 1; throw GlacierCoreError.message("Simulated rebuilt binary denied by Keychain")
        }, keychainSave: { _, _ in throw GlacierCoreError.message("Keychain unavailable") }, keychainDelete: { _ in throw GlacierCoreError.message("Keychain unavailable") })
    }
    try repository().save("  fixture-saved-key\n", provider: "openai")
    let restarted = try repository(["OPENAI_API_KEY": "fixture-stale-env"]).read("openai")
    precondition(restarted == "fixture-saved-key" && reads == 0)
    try repository().save("fixture-deepgram-key", provider: "deepgram")
    let assertion1 = try config.read("openai").key == "fixture-saved-key"
    precondition(assertion1)
    let mode = try FileManager.default.attributesOfItem(atPath: config.url.path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600)
    try repository().delete("openai")
    do { _ = try repository(["OPENAI_API_KEY": "fixture-stale-env"]).read("openai"); preconditionFailure("Deleted key resurrected") }
    catch { precondition(reads == 0) }
    try repository().save("fixture-replacement", provider: "openai")
    let assertion2 = try repository().read("openai") == "fixture-replacement"
    precondition(assertion2)

    let envConfig = CredentialConfig(url: directory.appendingPathComponent("Env/config.json"))
    let env = CredentialRepository(config: envConfig, environment: ["OPENAI_API_KEY": "fixture-environment"], keychainRead: { _,_ in preconditionFailure("Environment migration must not read Keychain") }, keychainSave: { _,_ in }, keychainDelete: { _ in })
    let assertion3 = try env.read("openai") == "fixture-environment"
    precondition(assertion3)
    let assertion4 = try envConfig.read("openai").key == "fixture-environment"
    precondition(assertion4)
    let legacyConfig = CredentialConfig(url: directory.appendingPathComponent("Legacy/config.json"))
    let legacy = CredentialRepository(config: legacyConfig, environment: [:], keychainRead: { _,_ in "fixture-legacy" }, keychainSave: { _,_ in }, keychainDelete: { _ in })
    let assertion5 = try legacy.read("openai", allowInteraction: true) == "fixture-legacy"
    precondition(assertion5)
    let assertion6 = try legacyConfig.read("openai").key == "fixture-legacy"
    precondition(assertion6)
    try Data("invalid-json-preserve-me".utf8).write(to: config.url)
    do { try repository().save("fixture-new", provider: "openai"); preconditionFailure("Corrupt config overwritten") } catch {}
    let assertion7 = try String(contentsOf: config.url) == "invalid-json-preserve-me"
    precondition(assertion7)
    print("PASS: saved credentials survive restart/Keychain denial; environment and legacy migration; replacement/deletion; private permissions; malformed config preserved")
}
