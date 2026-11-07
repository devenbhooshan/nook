import CryptoKit
import Foundation

/// Downloaded attachments, one encrypted file each, next to the mail store. Kept out of the database because
/// gigabytes of files inside it made every read slower and the store file enormous.
///
/// Each file is sealed with AES-GCM under a key derived from the store's own key (which stays in the Keychain), and
/// bound to its account, message and part, so a file can't be swapped for another. File and folder names are hashes,
/// so they don't reveal who sent what.
public struct AttachmentVault: Sendable {
    public let root: URL
    private let key: SymmetricKey

    public init(root: URL, storeKey: Data) {
        self.root = root
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: storeKey), info: Data("nook attachments v1".utf8), outputByteCount: 32
        )
    }

    /// `Attachments` beside the store at `databasePath`.
    public static func root(forDatabaseAt databasePath: String) -> URL {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func folder(account: String) -> URL {
        root.appendingPathComponent(String(Self.hash("account:" + account).prefix(24)), isDirectory: true)
    }

    func url(account: String, messageId: String, partId: String) -> URL {
        folder(account: account).appendingPathComponent(Self.hash("\(account)\n\(messageId)\n\(partId)"))
    }

    private static func context(account: String, messageId: String, partId: String) -> Data {
        Data("\(account)\n\(messageId)\n\(partId)".utf8)
    }

    public func write(_ data: Data, account: String, messageId: String, partId: String) throws {
        let folder = folder(account: account)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Self.context(account: account, messageId: messageId, partId: partId))
        guard let combined = sealed.combined else { throw DatabaseError(message: "Couldn't encrypt an attachment.") }
        let url = url(account: account, messageId: messageId, partId: partId)
        try combined.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func read(account: String, messageId: String, partId: String) -> Data? {
        guard let combined = try? Data(contentsOf: url(account: account, messageId: messageId, partId: partId)),
              let box = try? AES.GCM.SealedBox(combined: combined)
        else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Self.context(account: account, messageId: messageId, partId: partId))
    }

    public func remove(account: String, messageId: String, partId: String) {
        try? FileManager.default.removeItem(at: url(account: account, messageId: messageId, partId: partId))
    }

    public func removeAccount(_ account: String) {
        try? FileManager.default.removeItem(at: folder(account: account))
    }
}
