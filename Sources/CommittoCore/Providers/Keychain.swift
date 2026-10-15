import Foundation
#if canImport(Security)
import Security
#endif

/// Secret storage. Tokens never touch disk outside the macOS Keychain.
public enum Keychain {
    static let service = "app.committo"
    #if canImport(Security)
    public static func set(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
    public static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
    #else
    nonisolated(unsafe) private static var mem: [String: String] = [:]   // Linux test fallback only
    public static func set(_ v: String, for a: String) { mem[a] = v }
    public static func get(_ a: String) -> String? { mem[a] }
    public static func delete(_ a: String) { mem[a] = nil }
    #endif
}
