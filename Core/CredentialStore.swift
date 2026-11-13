import Foundation
import Security
import LocalAuthentication

public enum CredentialStore {
    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.ar2mis.lecturecaptions.\(provider)", kSecAttrAccount as String: "api-key"]
    }
    public static func read(_ provider: String) throws -> String {
        if provider == "openai", let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        var query = query(provider)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw GlacierCoreError.message("Save or unlock the \(provider) API key in Settings.")
        }
        return key
    }
    public static func save(_ value: String, provider: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GlacierCoreError.message("API key cannot be empty.") }
        let query = query(provider), value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var new = query; new[kSecValueData as String] = Data(key.utf8)
            new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GlacierCoreError.message("Could not save the API key to Keychain.") }
    }
}
