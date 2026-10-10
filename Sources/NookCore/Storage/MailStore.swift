import Foundation
import Security

/// Opens Nook's encrypted mail store, creating its key and converting an older unencrypted store as needed.
public enum MailStore {
    /// Where the key lives in the secret store (the Keychain, in the app).
    static let keyName = "database-key"

    public struct Opened {
        public let repository: MailRepository
        /// The previous store couldn't be unlocked (its key was lost), so it was set aside and a fresh one started.
        /// Mail downloads again from Gmail; local-only data such as tags is rebuilt by the tagger.
        public let startedFresh: Bool
    }

    /// The store's key, created on first use: 32 random bytes, kept only on this Mac.
    public static func key(in secrets: SecretStore) throws -> Data {
        // A read error must not look like "no key yet": creating a new key would overwrite the real one and
        // make the store unreadable for good. Only a genuine "not found" creates one.
        if let existing = try secrets.lookup(keyName) {
            guard existing.count == 32 else { throw DatabaseError(message: "Nook's encryption key in the Keychain is damaged.") }
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DatabaseError(message: "Couldn't generate an encryption key.")
        }
        let key = Data(bytes)
        try secrets.set(key, for: keyName)
        return key
    }

    /// Opens the store for the app: a read-write connection plus a read-only one for the UI.
    public static func open(path: String, secrets: SecretStore) throws -> Opened {
        // Files SQLite creates fresh get default permissions, so tighten again once everything is open.
        defer { restrictToOwner(path: path) }
        let key = try key(in: secrets)
        if Database.isPlaintext(at: path) {
            try Database.encryptInPlace(path: path, key: key)
        }
        do {
            return Opened(repository: try connect(path: path, key: key), startedFresh: false)
        } catch let error as DatabaseError where error == .wrongKey {
            // Without its key the old store is unreadable for good. Keep the file, but start over.
            let aside = path + ".unreadable-\(Int(Date().timeIntervalSince1970))"
            try FileManager.default.moveItem(atPath: path, toPath: aside)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            return Opened(repository: try connect(path: path, key: key), startedFresh: true)
        }
    }

    /// Opens the store read-only for another process (nook-mcp). Never creates a key or converts the store.
    public static func openForReading(path: String, secrets: SecretStore) throws -> MailRepository {
        if Database.isPlaintext(at: path) {
            return MailRepository(db: try Database(path: path))
        }
        guard let key = try secrets.lookup(keyName) else {
            throw DatabaseError(message: "Nook's mail store is encrypted and its key isn't available. Open Nook once, then try again.")
        }
        return try connect(path: path, key: key)
    }

    /// Only you can read the folder and its files (on top of the encryption).
    static func restrictToOwner(path: String) {
        let fileManager = FileManager.default
        let folder = (path as NSString).deletingLastPathComponent
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        for suffix in ["", "-wal", "-shm"] where fileManager.fileExists(atPath: path + suffix) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
    }

    private static func connect(path: String, key: Data) throws -> MailRepository {
        let writer = try Database(path: path, key: key)
        let reader = try Database(path: path, key: key, readOnly: true)
        return MailRepository(db: writer, reader: reader)
    }
}
