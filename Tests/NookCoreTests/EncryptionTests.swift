import Foundation
import Testing
@testable import NookCore

@Suite("Encryption at rest")
struct EncryptionTests {
    let directory: URL
    var path: String { directory.appendingPathComponent("nook.sqlite").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Everything SQLite wrote, including the WAL, which holds recent writes before a checkpoint.
    func bytesOnDisk() throws -> Data {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("nook.sqlite") }
            .reduce(into: Data()) { $0.append(try Data(contentsOf: directory.appendingPathComponent($1))) }
    }

    @Test func mailIsUnreadableOnDisk() throws {
        let secrets = MemorySecretStore()
        do {
            let repo = try MailStore.open(path: path, secrets: secrets).repository
            try repo.addAccount(email: "me@example.com", name: "Me")
            try repo.upsert([.fixture(id: "1", subject: "Quarterly salary review", body: "Confidential numbers inside")])
        }
        #expect(!Database.isPlaintext(at: path))
        let raw = try bytesOnDisk()
        for secret in ["Quarterly salary review", "Confidential numbers", "me@example.com", "SQLite format 3"] {
            #expect(raw.range(of: Data(secret.utf8)) == nil, "\"\(secret)\" is readable on disk")
        }

        // …but reopening with the key gets everything back, search included.
        let reopened = try MailStore.open(path: path, secrets: secrets).repository
        #expect(reopened.threads(ThreadQuery(search: SearchQuery.parse("salary"))).count == 1)
    }

    @Test func onlyTheOwnerCanReadTheFiles() throws {
        _ = try MailStore.open(path: path, secrets: MemorySecretStore())
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func theWrongKeyIsRejected() throws {
        _ = try MailStore.open(path: path, secrets: MemorySecretStore())
        #expect(throws: DatabaseError.wrongKey) {
            _ = try Database(path: path, key: Data(repeating: 7, count: 32))
        }
        #expect(throws: DatabaseError.wrongKey) {
            _ = try Database(path: path) // no key at all
        }
    }

    @Test func anOlderUnencryptedStoreIsConvertedInPlace() throws {
        do {
            let plain = MailRepository(db: try Database(path: path))
            try plain.addAccount(email: "me@example.com", name: "Me")
            try plain.setHistoryId("42", for: "me@example.com")
            try plain.upsert([.fixture(id: "1", subject: "Lunch plans", body: "Tacos on Friday")])
            try plain.setAutoTags(["Personal"], account: "me@example.com", messageId: "1")
        }
        #expect(Database.isPlaintext(at: path))

        let opened = try MailStore.open(path: path, secrets: MemorySecretStore())
        #expect(!opened.startedFresh)
        #expect(!Database.isPlaintext(at: path))
        let repo = opened.repository
        #expect(repo.account("me@example.com")?.historyId == "42")
        let thread = try #require(repo.threads(ThreadQuery()).first)
        #expect(thread.subject == "Lunch plans")
        #expect(thread.tags == ["Personal"])
        #expect(repo.threadMessages(account: "me@example.com", threadId: thread.threadId).first?.bodyText == "Tacos on Friday")
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("tacos"))).count == 1)
        // Schema version survives, so no migration runs again.
        #expect(try repo.db.query("PRAGMA user_version").first?.int("user_version") == Schema.version)
        #expect(!FileManager.default.fileExists(atPath: path + ".encrypting"))
    }

    @Test func aLostKeyStartsAFreshStoreAndKeepsTheOldFile() throws {
        do {
            let repo = try MailStore.open(path: path, secrets: MemorySecretStore()).repository
            try repo.addAccount(email: "me@example.com", name: "Me")
        }
        // A different secret store means a different (new) key: the old file can't be read anymore.
        let opened = try MailStore.open(path: path, secrets: MemorySecretStore())
        #expect(opened.startedFresh)
        #expect(opened.repository.accounts().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.contains { $0.hasPrefix("nook.sqlite.unreadable-") })
    }

    @Test func otherProcessesReadWithTheSharedKey() throws {
        let secrets = MemorySecretStore()
        do {
            let repo = try MailStore.open(path: path, secrets: secrets).repository
            try repo.addAccount(email: "me@example.com", name: "Me")
        }
        #expect(try MailStore.openForReading(path: path, secrets: secrets).accounts().count == 1)
        #expect(throws: DatabaseError.self) {
            _ = try MailStore.openForReading(path: path, secrets: MemorySecretStore())
        }
    }

    @Test func theKeyIsCreatedOnceAndReused() throws {
        let secrets = MemorySecretStore()
        let first = try MailStore.key(in: secrets)
        #expect(first.count == 32)
        #expect(try MailStore.key(in: secrets) == first)
        #expect(try MailStore.key(in: MemorySecretStore()) != first)
    }
}
