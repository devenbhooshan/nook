import Foundation
import Testing
@testable import NookCore

@Suite("SyncEngine")
struct SyncEngineTests {
    let account = "me@example.com"
    let repo: MailRepository
    let gmail: FakeGmail
    let changes = Counter()
    let engine: SyncEngine

    init() throws {
        repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        gmail = FakeGmail(messages: [
            gmailMessage(id: "1", thread: "A", date: Date(timeIntervalSince1970: 100)),
            gmailMessage(id: "2", thread: "A", labels: ["INBOX", "UNREAD"], date: Date(timeIntervalSince1970: 200)),
            gmailMessage(id: "3", thread: "B", labels: [], date: Date(timeIntervalSince1970: 300)),
            gmailMessage(id: "spam", labels: ["SPAM"]),
            gmailMessage(id: "draft", labels: ["DRAFT"]),
        ])
        let gmail = gmail
        let changes = changes
        engine = SyncEngine(repo: repo, makeService: { _ in gmail }, onChange: { changes.increment() })
    }

    @Test func firstSyncDownloadsMailAndSavesTheCursor() async throws {
        let report = try await engine.sync(account)

        #expect(report == SyncReport(kind: .full, added: 3))
        #expect(repo.messageIds(account: account) == ["1", "2", "3"])
        #expect(repo.account(account)?.historyId == "100")
        #expect(repo.threads(ThreadQuery(mailbox: .inbox)).map(\.threadId) == ["A"])
        #expect(repo.threads(ThreadQuery(mailbox: .inbox)).first?.isUnread == true)
        #expect(changes.count >= 2)
    }

    @Test func storesInBatchesAndNotifiesAsItGoes() async throws {
        await engine.configure(batchSize: 1)
        try await engine.sync(account)
        // One notification per stored batch (three messages; spam and drafts aren't listed) plus one at the end.
        #expect(changes.count == 4)
    }

    @Test func incrementalSyncAppliesAddsDeletesAndLabelChanges() async throws {
        try await engine.sync(account)
        await gmail.resetCounters()

        await gmail.add(gmailMessage(id: "4", thread: "C"), historyId: "101")
        await gmail.delete("3", historyId: "102")
        await gmail.relabel("2", labels: ["INBOX"], historyId: "103")

        let report = try await engine.sync(account)
        #expect(report == SyncReport(kind: .incremental, added: 1, updated: 1, deleted: 1))
        #expect(repo.messageIds(account: account) == ["1", "2", "4"])
        #expect(repo.message(account: account, id: "2")?.isUnread == false)
        #expect(repo.account(account)?.historyId == "103")
        // Only the new message is downloaded in full.
        #expect(await gmail.fullFetches == ["4"])
    }

    @Test func incrementalSyncWithNoChangesIsCheap() async throws {
        try await engine.sync(account)
        await gmail.resetCounters()

        let report = try await engine.sync(account)
        #expect(report == SyncReport(kind: .incremental))
        #expect(await gmail.fullFetches.isEmpty)
        #expect(await gmail.historyCalls == 1)
    }

    @Test func labelChangesWithoutLabelsAreRefetchedMinimally() async throws {
        try await engine.sync(account)
        await gmail.resetCounters()
        await gmail.relabel("1", labels: ["STARRED"], historyId: "101", includeLabelsInHistory: false)

        try await engine.sync(account)
        #expect(await gmail.minimalFetches == ["1"])
        #expect(repo.message(account: account, id: "1")?.labels == ["STARRED"])
    }

    @Test func messageMovedToSpamIsRemovedLocally() async throws {
        try await engine.sync(account)
        await gmail.relabel("1", labels: ["SPAM"], historyId: "101")

        let report = try await engine.sync(account)
        #expect(report.deleted == 1)
        #expect(!repo.messageIds(account: account).contains("1"))
    }

    @Test func labelChangeOnAnUnknownMessageDownloadsIt() async throws {
        try await engine.sync(account)
        // An old message, outside the first sync's window, is moved back into the inbox.
        let old = gmailMessage(id: "old", labels: ["INBOX"])
        await gmail.add(old, historyId: "100") // Same cursor, so it isn't replayed as an add.
        await gmail.relabel("old", labels: ["INBOX"], historyId: "101")

        let report = try await engine.sync(account)
        #expect(report.added == 1)
        #expect(repo.messageIds(account: account).contains("old"))
    }

    @Test func messageAddedThenDeletedBetweenSyncsIsNeverFetched() async throws {
        try await engine.sync(account)
        await gmail.resetCounters()
        await gmail.add(gmailMessage(id: "flash"), historyId: "101")
        await gmail.delete("flash", historyId: "102")

        try await engine.sync(account)
        #expect(await gmail.fullFetches.isEmpty)
        #expect(!repo.messageIds(account: account).contains("flash"))
    }

    @Test func expiredHistoryFallsBackToAFullResync() async throws {
        try await engine.sync(account)
        await gmail.expireHistory()
        await gmail.relabel("2", labels: ["INBOX"], historyId: "150")
        await gmail.resetCounters()

        let report = try await engine.sync(account)
        #expect(report.kind == .full)
        #expect(report.added == 0)
        #expect(report.updated == 3)
        // Known messages only get their labels refreshed, not their bodies.
        #expect(await gmail.fullFetches.isEmpty)
        #expect(repo.message(account: account, id: "2")?.isUnread == false)
        #expect(repo.account(account)?.historyId == "150")
    }

    @Test func concurrentSyncsForOneAccountShareOneRun() async throws {
        async let first = engine.sync(account)
        async let second = engine.sync(account)
        let reports = try await [first, second]
        #expect(reports.allSatisfy { $0.kind == .full })
        #expect(await gmail.fullFetches.count == 3)
    }

    @Test func respectsTheInitialLimit() async throws {
        await engine.configure(initialLimit: 2)
        let report = try await engine.sync(account)
        #expect(report.added <= 2)
    }

    @Test func surfacesServiceErrors() async throws {
        let engine = SyncEngine(repo: repo, makeService: { _ in throw GmailError.notSignedIn("me@example.com") })
        await #expect(throws: GmailError.notSignedIn("me@example.com")) {
            try await engine.sync(account)
        }
    }
}
