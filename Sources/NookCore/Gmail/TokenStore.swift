import Foundation
import Security

/// OAuth tokens for one account.
public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiry: Date

    public init(accessToken: String, refreshToken: String, expiry: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }
}

/// Where secrets live. The app uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func data(for key: String) -> Data?
    /// Like `data(for:)`, but throws for anything other than "not found" (a locked keychain, a denied prompt…),
    /// so callers that would otherwise create a replacement secret can tell "missing" from "unreadable".
    func lookup(_ key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String)
}

public extension SecretStore {
    func lookup(_ key: String) throws -> Data? { data(for: key) }

    func tokens(for email: String) -> TokenSet? {
        data(for: "token:\(email)").flatMap { try? JSONDecoder().decode(TokenSet.self, from: $0) }
    }

    func setTokens(_ tokens: TokenSet, for email: String) throws {
        try set(JSONEncoder().encode(tokens), for: "token:\(email)")
    }

    func removeTokens(for email: String) {
        remove("token:\(email)")
    }

    func string(for key: String) -> String? {
        data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    func setString(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Generic-password items in the login Keychain, available only on this Mac.
public struct KeychainStore: SecretStore {
    public let service: String

    /// The service name Nook stores secrets under. (Pre-release builds used `app.nook.mail` and
    /// `app.nook.mail.secrets`; those items are left alone, because their access rules belong to old builds
    /// and reading them makes macOS prompt.)
    public static let defaultService = "com.devenbhooshan.nook"

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func data(for key: String) -> Data? {
        try? lookup(key)
    }

    public func lookup(_ key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func remove(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// An in-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(for key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    public func set(_ data: Data, for key: String) throws {
        lock.withLock { storage[key] = data }
    }

    public func remove(_ key: String) {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }
}
