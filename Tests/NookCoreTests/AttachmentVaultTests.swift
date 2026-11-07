import Foundation
import Testing
@testable import NookCore

/// Attachments live in encrypted files beside the store, not inside it.
@Suite("Attachment vault", .serialized)
struct AttachmentVaultTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-vault-\(UUID().uuidString)", isDirectory: true)
    var path: String { folder.appendingPathComponent("nook.sqlite").path }
    let secrets = MemorySecretStore()
    let account = "me@example.com"

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func open() throws -> MailRepository {
        let repo = try MailStore.open(path: path, secrets: secrets).repository
        if repo.accounts().isEmpty { try repo.addAccount(email: account, name: "Me") }
        return repo
    }

    func files(in repo: MailRepository) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: repo.vault!.root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    @Test func filesAreEncryptedOnDiskAndReadBack() throws {
        let repo = try open()
        try repo.upsert([.fixture(id: "1", thread: "T")])
        let secret = Data("the quarterly numbers".utf8)
        try repo.storeAttachments(account: account, messageId: "1", files: [("2", secret)])

        #expect(repo.storedAttachment(account: account, messageId: "1", partId: "2") == secret)
        let onDisk = files(in: repo)
        #expect(onDisk.count == 1)
        let raw = try Data(contentsOf: onDisk[0])
        #expect(raw.range(of: secret) == nil, "the file isn't plaintext")
        let name = onDisk[0].lastPathComponent
        #expect(!onDisk[0].path.contains(account) && name.count == 64 && name.allSatisfy(\.isHexDigit), "names don't give anything away")
        // Nothing big is left inside the store.
        #expect(try repo.db.query("SELECT data FROM attachment_files WHERE data IS NOT NULL").isEmpty)
    }

    @Test func trimmingAndDeletingRemoveTheFiles() throws {
        let repo = try open()
        try repo.upsert([.fixture(id: "old", thread: "A", minutesAgo: 60), .fixture(id: "new", thread: "B")])
        try repo.storeAttachments(account: account, messageId: "old", files: [("1", Data(count: 60))])
        try repo.storeAttachments(account: account, messageId: "new", files: [("1", Data(count: 60))])
        #expect(files(in: repo).count == 2)

        try repo.trimStoredAttachments(toBudget: 100)
        #expect(repo.storedAttachment(account: account, messageId: "old", partId: "1") == nil)
        #expect(repo.storedAttachment(account: account, messageId: "new", partId: "1") == Data(count: 60))
        #expect(files(in: repo).count == 1)

        try repo.deleteMessages(account: account, ids: ["new"])
        #expect(files(in: repo).isEmpty)
    }

    @Test func removingAnAccountRemovesItsFiles() throws {
        let repo = try open()
        try repo.upsert([.fixture(id: "1", thread: "T")])
        try repo.storeAttachments(account: account, messageId: "1", files: [("1", Data([1, 2, 3]))])
        try repo.removeAccount(account)
        #expect(files(in: repo).isEmpty)
    }

    /// Stores from before the vault kept attachments inside: they move out, and compacting gives the space back.
    @Test func attachmentsInsideTheStoreMoveOutAndTheStoreShrinks() throws {
        let repo = try open()
        try repo.upsert((0..<40).map { .fixture(id: "m\($0)", thread: "t\($0)") })
        let blob = Data((0..<200_000).map { UInt8($0 % 251) })
        for i in 0..<40 {
            try repo.db.execute("INSERT INTO attachment_files(account, message_id, part_id, data) VALUES (?, ?, '1', ?)", [account, "m\(i)", blob])
        }
        try repo.db.run("PRAGMA wal_checkpoint(TRUNCATE)")
        let before = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
        #expect(repo.attachmentsLeftInStore)

        while repo.attachmentsLeftInStore { #expect(try repo.moveAttachmentsToVault(limit: 7) > 0) }
        #expect(files(in: repo).count == 40)
        #expect(repo.storedAttachment(account: account, messageId: "m17", partId: "1") == blob)

        try repo.compact()
        let after = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
        #expect(after < before / 4, "\(before) → \(after) bytes")
        // And it all still reads after reopening.
        #expect(try open().storedAttachment(account: account, messageId: "m39", partId: "1") == blob)
    }

    @Test func aStoreWithoutAVaultKeepsFilesInside() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        try repo.upsert([.fixture(id: "1", thread: "T")])
        try repo.storeAttachments(account: account, messageId: "1", files: [("1", Data([9]))])
        #expect(repo.storedAttachment(account: account, messageId: "1", partId: "1") == Data([9]))
        #expect(!repo.attachmentsLeftInStore, "nothing to move without a vault")
    }
}
