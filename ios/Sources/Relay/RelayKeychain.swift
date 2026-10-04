import ClaudeRelay
import Foundation
import Security

/// The Mac pairing (host, port, secret) as its claudeboard:// URL in the Keychain, this device only, readable
/// after the first unlock (the relay runs in the background). Never in UserDefaults.
enum RelayKeychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.cicca.esptranslator.relay",
        kSecAttrAccount as String: "mac",
    ]

    static func load() -> RelayPairing? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return RelayPairing.parse(text)   // re-validated on every load
    }

    @discardableResult
    static func save(_ pairing: RelayPairing) -> Bool {
        forget()
        var item = base
        item[kSecValueData as String] = Data(pairing.url.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func forget() { SecItemDelete(base as CFDictionary) }
}
