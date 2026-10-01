import Foundation
import CryptoKit
import Security

/// Encrypts/decrypts sensitive clipboard content at rest using a per-install key
/// held in the Keychain (never written to the SwiftData store or exported backups).
enum SensitiveEncryptionService {

    private static let service = "com.minsang.Clipbara"
    private static let account = "sensitive-clip-key"
    private static let keyLock = NSLock()
    // Guarded by `keyLock`, not by actor isolation — the lock is the actual safety mechanism.
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?

    static func encrypt(_ data: Data) -> Data? {
        try? ChaChaPoly.seal(data, using: key()).combined
    }

    static func decrypt(_ data: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: data) else { return nil }
        return try? ChaChaPoly.open(box, using: key())
    }

    /// Duplicate-detection identity for a sensitive clip. HMAC-SHA256 under the
    /// keychain key, so the stored hash is not an offline oracle for the plaintext.
    static func fingerprint(of data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key())
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func key() -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }

        if let cachedKey { return cachedKey }
        if let data = loadKeyData() {
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }

        let newKey = SymmetricKey(size: .bits256)
        store(newKey.withUnsafeBytes { Data($0) })
        cachedKey = newKey
        return newKey
    }

    private static func loadKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func store(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
