import Foundation
import Security
import LocalAuthentication

public enum CredentialStore {
    private static let lock = NSRecursiveLock()
    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: (AppDistribution.isStore || AppDistribution.isDevelopment ? "\(AppDistribution.credentialService).\(provider)" : "local.ar2mis.lecturecaptions.\(provider)"), kSecAttrAccount as String: "api-key"]
    }
    private static func withoutPrompts<T>(_ allowInteraction: Bool = false, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        #if os(macOS)
        var old = DarwinBoolean(false)
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&old) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                throw GlacierCoreError.message("Keychain is unavailable. Paste the API key in Glacier Settings.")
            }
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(old.boolValue) } }
        #endif
        return try operation()
    }
    private static var repository: CredentialRepository {
        #if os(macOS)
        let config: CredentialConfig? = .init(url: CredentialConfig.defaultURL)
        #else
        let config: CredentialConfig? = nil
        #endif
        return .init(config: config, environment: ProcessInfo.processInfo.environment, keychainRead: { provider, allow in
            try withoutPrompts(allow) {
                var request = query(provider)
                request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
                let context = LAContext(); context.interactionNotAllowed = !allow
                request[kSecUseAuthenticationContext as String] = context
                var result: CFTypeRef?
                let status = SecItemCopyMatching(request as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                    throw GlacierCoreError.message("Cannot read the \(provider) API key (Keychain \(status)). Paste it in Settings or unlock the existing key once.")
                }
                return key
            }
        }, keychainSave: { key, provider in
            try withoutPrompts {
                let item = query(provider), data = Data(key.utf8)
                var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if status == errSecItemNotFound {
                    var new = item; new[kSecValueData as String] = data
                    new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    status = SecItemAdd(new as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw GlacierCoreError.message("Could not save the API key to Keychain.") }
            }
        }, keychainDelete: { provider in
            try withoutPrompts {
                let status = SecItemDelete(query(provider) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw GlacierCoreError.message("Could not remove the API key from Keychain.") }
            }
        })
    }
    public static func read(_ provider: String, allowInteraction: Bool = false) throws -> String { try repository.read(provider, allowInteraction: allowInteraction) }
    public static func save(_ value: String, provider: String) throws { try repository.save(value, provider: provider) }
    public static func delete(_ provider: String) throws { try repository.delete(provider) }
}
