import Foundation
import Testing
@testable import NookCore

/// Regression tests for issues found in the pre-release review.
@Suite("Hardening")
struct HardeningTests {
    // MARK: Header injection

    /// The header block of a built message, one header per line.
    func headers(of draft: Draft) -> [String] {
        let raw = MIMEBuilder.rfc822(draft, fromName: "Me")
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? ""
        return head.components(separatedBy: "\r\n")
    }

    @Test(arguments: ["\r\n", "\n", "\r", "\u{2028}", "\u{0085}"])
    func lineBreaksInHeaderValuesCantAddHeaders(separator: String) {
        let draft = Draft(
            from: "me@example.com",
            to: "boss@corp.example\(separator)Bcc: spy@evil.example",
            cc: "a@b.example\(separator)X-Evil: 1",
            subject: "Q3 numbers\(separator)Bcc: spy@evil.example\(separator)\(separator)Injected body",
            body: "Hello",
            inReplyTo: "<id@x>\(separator)Bcc: spy@evil.example",
            references: "<r@x>\(separator)Bcc: spy@evil.example"
        )
        let lines = headers(of: draft)
        #expect(!lines.contains { $0.hasPrefix("Bcc:") }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("X-Evil:") })
        // Exactly one blank line separates headers from the base64 body.
        #expect(MIMEBuilder.rfc822(draft, fromName: "Me").components(separatedBy: "\r\n\r\n").count == 2)
        #expect(lines.contains { $0.hasPrefix("Subject: Q3 numbers") })
    }

    @Test func aNookLinkCantSmuggleABcc() throws {
        let url = try #require(URL(string: "nook://compose?to=boss@corp.example&subject=Q3%0D%0ABcc:%20spy@evil.example&body=hi"))
        guard case let .compose(from, to, cc, subject, body)? = NookURL(url) else { Issue.record("not a compose link"); return }
        let draft = Draft(from: from ?? "me@example.com", to: to, cc: cc, subject: subject, body: body)
        #expect(!headers(of: draft).contains { $0.hasPrefix("Bcc:") })
    }

    @Test func singleLineKeepsOrdinaryText() {
        #expect(MIMEBuilder.singleLine("Café ☕️ — Q3 \"numbers\"") == "Café ☕️ — Q3 \"numbers\"")
        #expect(MIMEBuilder.singleLine("a\r\nb\tc") == "a  b c")
    }

    // MARK: Encryption key safety

    /// A keychain that can't be read right now (locked, prompt denied…).
    final class UnreadableStore: SecretStore, @unchecked Sendable {
        var writes = 0
        func data(for key: String) -> Data? { nil }
        func lookup(_ key: String) throws -> Data? { throw KeychainError(status: errSecInteractionNotAllowed) }
        func set(_ data: Data, for key: String) throws { writes += 1 }
        func remove(_ key: String) {}
    }

    @Test func anUnreadableKeychainNeverReplacesTheKey() {
        let store = UnreadableStore()
        #expect(throws: KeychainError.self) { _ = try MailStore.key(in: store) }
        #expect(store.writes == 0, "a new key would make the existing store unreadable")
    }

    // MARK: Sending

    @Test func aServerErrorOnSendIsNotRetried() async throws {
        let transport = StubTransport([.init(500, #"{"error":{"message":"backend error"}}"#), .init(200)])
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: nil, retryDelay: { _, _ in })
        await #expect(throws: GmailError.http(status: 500, message: "backend error")) {
            try await client.send(raw: "abc", threadId: nil)
        }
        #expect(transport.recorded.count == 1, "a retry could send the email twice")
    }

    @Test func aRateLimitOnSendIsRetried() async throws {
        // Gmail rejected the request outright, so trying again can't duplicate it.
        let transport = StubTransport([.init(429), .init(200)])
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: nil, retryDelay: { _, _ in })
        try await client.send(raw: "abc", threadId: nil)
        #expect(transport.recorded.count == 2)
    }

    @Test func otherCallsStillRetryServerErrors() async throws {
        let transport = StubTransport([.init(503), .init(200)])
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: nil, retryDelay: { _, _ in })
        try await client.modifyThread(id: "t", add: [], remove: ["INBOX"])
        #expect(transport.recorded.count == 2)
    }

    // MARK: Sync

    @Test func refreshingAThreadMatchesGmail() async throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        let gmail = FakeGmail(messages: [
            gmailMessage(id: "1", thread: "T", labels: ["INBOX"]),
            gmailMessage(id: "2", thread: "T", labels: ["INBOX", "UNREAD"]),
        ])
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail })
        try await engine.sync("me@example.com")

        // Locally the thread was archived, but Gmail refused; meanwhile message 2 was deleted in Gmail.
        try repo.modifyThread(account: "me@example.com", threadId: "T", add: [], remove: ["INBOX"])
        await gmail.delete("2", historyId: "101")

        try await engine.refreshThread(account: "me@example.com", threadId: "T")
        #expect(repo.message(account: "me@example.com", id: "1")?.labels == ["INBOX"])
        #expect(repo.message(account: "me@example.com", id: "2") == nil)
        #expect(repo.threads(ThreadQuery(mailbox: .inbox)).map(\.threadId) == ["T"])
    }

    @Test func aRemovedAccountIsNeverSynced() async throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        let gmail = FakeGmail(messages: [gmailMessage(id: "1")])
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail })
        try repo.removeAccount("me@example.com")

        await #expect(throws: CancellationError.self) { try await engine.sync("me@example.com") }
        #expect(repo.threads(ThreadQuery(mailbox: .all)).isEmpty, "mail must not reappear for a removed account")
    }

    @Test func forgettingAnAccountWaitsForItsSyncToStop() async throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        let gmail = FakeGmail(messages: (0..<30).map { gmailMessage(id: "m\($0)") })
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail })
        await engine.configure(batchSize: 1)

        let syncing = Task { try await engine.sync("me@example.com") }
        await Task.yield()
        await engine.forget("me@example.com")
        try repo.removeAccount("me@example.com")
        _ = try? await syncing.value

        #expect(repo.threads(ThreadQuery(mailbox: .all)).isEmpty, "a batch in flight wrote mail back after removal")
    }

    // MARK: Migrations

    @Test func anInterruptedUpgradeCanBeRunAgain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let repo = MailRepository(db: try Database(path: url.path))
            try repo.addAccount(email: "me@example.com", name: "Me")
            try repo.upsert([.fixture(id: "1", subject: "Still here")])
            // Pretend the upgrade record was lost after the steps ran (crash between a step and its version bump).
            try repo.db.run("PRAGMA user_version = 0")
        }
        let reopened = MailRepository(db: try Database(path: url.path))
        #expect(reopened.threads(ThreadQuery()).first?.subject == "Still here")
        #expect(try reopened.db.query("PRAGMA user_version").first?.int("user_version") == Schema.version)
    }

    @Test func storesFromTheRemovedRulesFeatureLoseItsTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let repo = MailRepository(db: try Database(path: url.path))
            try repo.upsert([.fixture(id: "1", subject: "Still here")])
            // A store upgraded while the rules feature existed.
            try repo.db.run("CREATE TABLE rules(id TEXT PRIMARY KEY, position INTEGER NOT NULL DEFAULT 0, definition TEXT NOT NULL)")
            try repo.db.run("PRAGMA user_version = 7")
        }
        let reopened = MailRepository(db: try Database(path: url.path))
        #expect(try reopened.db.query("SELECT name FROM sqlite_master WHERE name = 'rules'").isEmpty)
        #expect(reopened.threads(ThreadQuery()).first?.subject == "Still here")
    }
}
