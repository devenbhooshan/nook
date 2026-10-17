import Foundation
import Testing
@testable import NookCore

@Suite("MailRepository")
struct MailRepositoryTests {
    let repo: MailRepository

    init() throws {
        repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        try repo.addAccount(email: "work@example.com", name: "Work")
    }

    @Test func seedsDefaultTags() {
        #expect(repo.tags() == Tag.defaults)
        #expect(repo.tags().filter(\.isSplit).map(\.name) == ["Needs Reply", "Newsletter", "Receipt", "Notification"])
    }

    @Test func upgradesInlineBodiesIntoTheirOwnTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            // Recreate a version 2 store: bodies inline in messages, no message_bodies table.
            let db = try Database(path: url.path)
            try db.run("DROP TABLE message_bodies")
            try db.run("ALTER TABLE messages ADD COLUMN body_html TEXT NOT NULL DEFAULT ''")
            try db.run("ALTER TABLE messages ADD COLUMN body_text TEXT NOT NULL DEFAULT ''")
            try db.execute(
                "INSERT INTO messages(account, id, thread_id, date, labels, body_html, body_text) VALUES ('me@example.com', '1', 'T', 0, ',INBOX,', '<p>Hi</p>', 'Hi')"
            )
            try db.run("PRAGMA user_version = 2")
        }
        let upgraded = MailRepository(db: try Database(path: url.path))
        let message = try #require(upgraded.message(account: "me@example.com", id: "1"))
        #expect(message.bodyHTML == "<p>Hi</p>")
        #expect(message.bodyText == "Hi")
        let columns = try upgraded.db.query("PRAGMA table_info(messages)").map { $0.string("name") }
        #expect(!columns.contains("body_html"))
    }

    @Test func listsDontNeedBodiesButThreadsHaveThem() throws {
        try repo.upsert([.fixture(id: "1", body: "Full body text")])
        #expect(repo.threadMessages(account: "me@example.com", threadId: "1").first?.bodyText == "Full body text")
        try repo.deleteMessages(account: "me@example.com", ids: ["1"])
        #expect(try repo.db.query("SELECT COUNT(*) AS n FROM message_bodies").first?.int("n") == 0)
    }

    @Test func upgradesAVersionOneStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            // Recreate what version 1 left behind: no split column, and a user-renamed tag list.
            let db = try Database(path: url.path)
            try db.run("ALTER TABLE tags DROP COLUMN split")
            try db.run("DELETE FROM tags")
            try db.execute("INSERT INTO tags(name, description, color, position) VALUES ('Needs Reply', 'x', 0, 0), ('Mine', 'y', 1, 1)")
            try db.run("PRAGMA user_version = 1")
        }
        let upgraded = MailRepository(db: try Database(path: url.path))
        #expect(upgraded.tags().map(\.name) == ["Needs Reply", "Mine"])
        #expect(upgraded.tags().map(\.isSplit) == [true, false])
    }

    @Test func knowsWhetherAnyMailIsStored() throws {
        #expect(!repo.hasMessages())
        try repo.upsert([.fixture(id: "1", labels: [])])
        #expect(repo.hasMessages())
    }

    @Test func addsAccountsInOrderAndUpdatesNames() throws {
        try repo.addAccount(email: "me@example.com", name: "Renamed")
        let accounts = repo.accounts()
        #expect(accounts.map(\.email) == ["me@example.com", "work@example.com"])
        #expect(accounts.first?.name == "Renamed")
        #expect(accounts.map(\.colorIndex) == [0, 1])
    }

    @Test func groupsMessagesIntoThreadsShowingTheNewest() throws {
        try repo.upsert([
            .fixture(id: "a1", thread: "A", subject: "Plans", body: "first", labels: [SystemLabel.inbox], minutesAgo: 30),
            .fixture(id: "a2", thread: "A", fromName: "Ben", subject: "Re: Plans", body: "second", labels: [SystemLabel.inbox, SystemLabel.unread], minutesAgo: 10),
            .fixture(id: "b1", thread: "B", subject: "Other", minutesAgo: 20),
        ])

        let threads = repo.threads(ThreadQuery())
        #expect(threads.map(\.threadId) == ["A", "B"])
        #expect(threads[0].latestMessageId == "a2")
        #expect(threads[0].fromName == "Ben")
        #expect(threads[0].messageCount == 2)
        #expect(threads[0].isUnread)
        #expect(!threads[1].isUnread)
    }

    @Test func filtersByMailboxAndHidesTrashSpamAndDrafts() throws {
        try repo.upsert([
            .fixture(id: "inbox", labels: [SystemLabel.inbox]),
            .fixture(id: "archived", labels: []),
            .fixture(id: "sent", labels: [SystemLabel.sent]),
            .fixture(id: "starred", labels: [SystemLabel.starred]),
            .fixture(id: "trash", labels: [SystemLabel.trash, SystemLabel.inbox]),
            .fixture(id: "spam", labels: [SystemLabel.spam]),
            .fixture(id: "draft", labels: [SystemLabel.draft]),
        ])

        func ids(_ mailbox: Mailbox) -> Set<String> {
            Set(repo.threads(ThreadQuery(mailbox: mailbox)).map(\.threadId))
        }
        #expect(ids(.inbox) == ["inbox"])
        #expect(ids(.sent) == ["sent"])
        #expect(ids(.starred) == ["starred"])
        #expect(ids(.trash) == ["trash"])
        #expect(ids(.all) == ["inbox", "archived", "sent", "starred"])
        #expect(ids(.drafts) == ["draft"])
    }

    @Test func draftsListWhoTheyreToAndStayOutOfTheirConversation() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "t", subject: "Plans", minutesAgo: 10),
            .fixture(id: "2", thread: "t", from: "me@example.com", subject: "Re: Plans", labels: [SystemLabel.draft], to: "Anna Lee <anna@example.com>"),
            .fixture(id: "3", from: "me@example.com", subject: "New idea", labels: [SystemLabel.draft], minutesAgo: 5, to: ""),
        ])
        let drafts = repo.threads(ThreadQuery(mailbox: .drafts))
        #expect(drafts.map(\.latestMessageId) == ["2", "3"])
        #expect(drafts.map(\.fromName) == ["Anna Lee", "No recipient"])
        #expect(repo.threadMessages(account: "me@example.com", threadId: "t").map(\.id) == ["1"])
        #expect(repo.threads(ThreadQuery(mailbox: .inbox)).first?.latestMessageId == "1")
    }

    @Test func scopesToOneAccountOrShowsAllTogether() throws {
        try repo.upsert([
            .fixture(id: "m1", account: "me@example.com"),
            .fixture(id: "w1", account: "work@example.com"),
        ])
        #expect(repo.threads(ThreadQuery(account: "work@example.com")).map(\.threadId) == ["w1"])
        #expect(repo.threads(ThreadQuery()).count == 2)
    }

    @Test func sameThreadIdInTwoAccountsStaysSeparate() throws {
        try repo.upsert([
            .fixture(id: "x", account: "me@example.com", thread: "T"),
            .fixture(id: "x", account: "work@example.com", thread: "T"),
        ])
        #expect(repo.threads(ThreadQuery()).count == 2)
    }

    @Test func fullTextSearchMatchesPrefixesAcrossAllMail() throws {
        try repo.upsert([
            .fixture(id: "1", subject: "Quarterly invoice", body: "Please pay", labels: []),
            .fixture(id: "2", subject: "Lunch?", body: "Tacos on Friday"),
        ])
        let query = ThreadQuery(mailbox: .inbox, search: SearchQuery.parse("invoi"))
        // Searching ignores the selected mailbox, so archived mail shows up too.
        #expect(repo.threads(query).map(\.threadId) == ["1"])
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("taco friday"))).map(\.threadId) == ["2"])
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("taco invoice"))).isEmpty)
    }

    @Test func searchOperators() throws {
        try repo.upsert([
            .fixture(id: "1", from: "anna@acme.com", fromName: "Anna", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "2", from: "ben@other.com", fromName: "Ben", labels: [SystemLabel.inbox, SystemLabel.starred]),
            .fixture(id: "3", account: "work@example.com", from: "cy@acme.com", labels: [SystemLabel.sent], to: "dana@client.com"),
        ])
        func ids(_ search: String) -> Set<String> {
            Set(repo.threads(ThreadQuery(search: SearchQuery.parse(search))).map(\.threadId))
        }
        #expect(ids("from:acme") == ["1", "3"])
        #expect(ids("is:unread") == ["1"])
        #expect(ids("is:starred") == ["2"])
        #expect(ids("to:dana") == ["3"])
        #expect(ids("account:work") == ["3"])
        #expect(ids("in:sent") == ["3"])
        #expect(ids("from:acme in:inbox") == ["1"])
    }

    @Test func searchSurvivesQuotesAndPunctuation() throws {
        try repo.upsert([.fixture(id: "1", subject: "Re: \"Q3\" numbers (draft)")])
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("\"q3 numbers\""))).count == 1)
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("(draft) AND OR"))).count == 0)
    }

    @Test func unreadOnlyKeepsThreadsWithAnythingUnread() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "A", labels: [SystemLabel.inbox, SystemLabel.unread], minutesAgo: 10),
            .fixture(id: "2", thread: "A", labels: [SystemLabel.inbox], minutesAgo: 1),
            .fixture(id: "3", thread: "B", labels: [SystemLabel.inbox]),
            .fixture(id: "4", thread: "C", labels: [SystemLabel.inbox, SystemLabel.unread, SystemLabel.trash]),
        ])
        let unread = repo.threads(ThreadQuery(unreadOnly: true))
        #expect(unread.map(\.threadId) == ["A"])
        // The whole thread comes back, not just its unread message.
        #expect(unread.first?.messageCount == 2)
        #expect(unread.first?.latestMessageId == "2")
    }

    @Test func unreadOnlyCanKeepJustReadThreadsVisible() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "A", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "2", thread: "B", labels: [SystemLabel.inbox]),
            .fixture(id: "3", thread: "C", labels: [SystemLabel.inbox]),
        ])
        let query = ThreadQuery(unreadOnly: true, keepVisible: ["me@example.com/B"])
        #expect(Set(repo.threads(query).map(\.threadId)) == ["A", "B"])
        // keepVisible only matters for the unread filter.
        #expect(repo.threads(ThreadQuery(keepVisible: ["me@example.com/B"])).count == 3)
    }

    @Test func splitCountsCanCountOnlyUnread() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "A", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "2", thread: "B", labels: [SystemLabel.inbox]),
        ])
        try repo.setAutoTags(["Receipt"], account: "me@example.com", messageId: "1")
        try repo.setAutoTags(["Receipt"], account: "me@example.com", messageId: "2")
        #expect(repo.splitCounts(account: nil, unreadOnly: true) == SplitCounts(total: 1, tags: ["Receipt": 1], other: 0))
        #expect(repo.splitCounts(account: nil).tags["Receipt"] == 2)
    }

    @Test func modifyThreadReturnsSnapshotsForUndo() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "T", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "2", thread: "T", labels: [SystemLabel.inbox]),
        ])
        let snapshots = try repo.modifyThread(account: "me@example.com", threadId: "T", add: [], remove: [SystemLabel.inbox, SystemLabel.unread])
        #expect(repo.threads(ThreadQuery(mailbox: .inbox)).isEmpty)
        #expect(repo.threads(ThreadQuery(mailbox: .all)).first?.isUnread == false)

        try repo.restore(snapshots)
        let restored = repo.threads(ThreadQuery(mailbox: .inbox))
        #expect(restored.count == 1)
        #expect(restored.first?.isUnread == true)
    }

    @Test func upsertKeepsTagsAndUpdatesLabels() throws {
        try repo.upsert([.fixture(id: "1")])
        try repo.setAutoTags(["Receipt"], account: "me@example.com", messageId: "1")
        try repo.upsert([.fixture(id: "1", labels: [SystemLabel.inbox, SystemLabel.starred])])

        #expect(repo.tags(account: "me@example.com", messageId: "1") == ["Receipt"])
        #expect(repo.threads(ThreadQuery()).first?.isStarred == true)
        #expect(repo.untaggedCount() == 0)
    }

    @Test func threadTagsFollowTagOrderAndFilterTheList() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "T"),
            .fixture(id: "2", thread: "T", minutesAgo: 5),
            .fixture(id: "3", thread: "U"),
        ])
        try repo.setAutoTags(["Receipt"], account: "me@example.com", messageId: "1")
        try repo.setAutoTags(["Needs Reply"], account: "me@example.com", messageId: "2")

        let thread = repo.threads(ThreadQuery()).first { $0.threadId == "T" }
        #expect(thread?.tags == ["Needs Reply", "Receipt"])
        #expect(repo.threads(ThreadQuery(split: .tag("Receipt"))).map(\.threadId) == ["T"])
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("tag:receipt"))).map(\.threadId) == ["T"])
    }

    @Test func splitsSortThreadsByTagAndCountThem() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "T"),
            .fixture(id: "2", thread: "T", minutesAgo: 5),
            .fixture(id: "3", thread: "U"),
            .fixture(id: "4", account: "work@example.com", thread: "V"),
            .fixture(id: "5", thread: "W", labels: []),
            .fixture(id: "6", thread: "X"),
        ])
        // Finance isn't an inbox tab, so a thread tagged only Finance still belongs in Other.
        try repo.setAutoTags(["Finance"], account: "me@example.com", messageId: "6")
        // Only one message in T is tagged, but the whole thread counts as tagged.
        try repo.setAutoTags(["Receipt"], account: "me@example.com", messageId: "2")
        try repo.setAutoTags(["Receipt", "Finance"], account: "work@example.com", messageId: "4")

        #expect(repo.threads(ThreadQuery(split: .tag("Receipt"))).map(\.threadId).sorted() == ["T", "V"])
        #expect(repo.threads(ThreadQuery(split: .other)).map(\.threadId).sorted() == ["U", "X"])
        #expect(repo.threads(ThreadQuery(mailbox: .all, split: .other)).map(\.threadId).sorted() == ["U", "W", "X"])

        #expect(repo.splitCounts(account: nil) == SplitCounts(total: 4, tags: ["Receipt": 2, "Finance": 2], other: 2))
        #expect(repo.splitCounts(account: "me@example.com") == SplitCounts(total: 3, tags: ["Receipt": 1, "Finance": 1], other: 2))
    }

    @Test func autoTaggingNeverOverwritesManualTags() throws {
        try repo.upsert([.fixture(id: "1", thread: "T")])
        try repo.toggleTag("Personal", account: "me@example.com", threadId: "T")
        try repo.setAutoTags(["Newsletter"], account: "me@example.com", messageId: "1")
        try repo.setAutoTags([], account: "me@example.com", messageId: "1")
        #expect(repo.tags(account: "me@example.com", messageId: "1") == ["Personal"])

        try repo.toggleTag("Personal", account: "me@example.com", threadId: "T")
        #expect(repo.tags(account: "me@example.com", messageId: "1").isEmpty)
    }

    @Test func untaggedQueueSkipsSentMailAndResets() throws {
        try repo.upsert([
            .fixture(id: "in", minutesAgo: 10),
            .fixture(id: "new", minutesAgo: 1),
            .fixture(id: "out", labels: [SystemLabel.sent]),
        ])
        #expect(repo.untaggedMessages(limit: 10).map(\.id) == ["new", "in"])

        try repo.setAutoTags([], account: "me@example.com", messageId: "new")
        #expect(repo.untaggedCount() == 1)
        try repo.resetAutoTags()
        #expect(repo.untaggedCount() == 2)
    }

    @Test func savingTagsDropsAssignmentsForRemovedTags() throws {
        try repo.upsert([.fixture(id: "1")])
        try repo.setAutoTags(["Receipt", "Finance"], account: "me@example.com", messageId: "1")
        try repo.saveTags([Tag(name: "Finance", description: "Money", colorIndex: 2, isSplit: true)])
        #expect(repo.tags() == [Tag(name: "Finance", description: "Money", colorIndex: 2, isSplit: true)])
        #expect(repo.tags(account: "me@example.com", messageId: "1") == ["Finance"])
    }

    @Test func unreadCountsArePerAccountAndPerThread() throws {
        try repo.upsert([
            .fixture(id: "1", thread: "T", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "2", thread: "T", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "3", account: "work@example.com", labels: [SystemLabel.inbox, SystemLabel.unread]),
            .fixture(id: "4", labels: [SystemLabel.unread]),
        ])
        #expect(repo.unreadInboxCounts() == ["me@example.com": 1, "work@example.com": 1])
    }

    @Test func removingAnAccountDeletesItsMail() throws {
        try repo.upsert([.fixture(id: "1", account: "work@example.com", subject: "secret plan")])
        try repo.setAutoTags(["Finance"], account: "work@example.com", messageId: "1")
        try repo.removeAccount("work@example.com")

        #expect(repo.accounts().map(\.email) == ["me@example.com"])
        #expect(repo.threads(ThreadQuery(mailbox: .all)).isEmpty)
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("secret"))).isEmpty)
        #expect(repo.tags(account: "work@example.com", messageId: "1").isEmpty)
    }

    @Test func deletingMessagesAlsoClearsSearchIndex() throws {
        try repo.upsert([.fixture(id: "1", subject: "findme")])
        try repo.deleteMessages(account: "me@example.com", ids: ["1"])
        #expect(repo.threads(ThreadQuery(search: SearchQuery.parse("findme"))).isEmpty)
    }

    @Test func persistsAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let repo = MailRepository(db: try Database(path: url.path))
            try repo.addAccount(email: "me@example.com", name: "Me")
            try repo.upsert([.fixture(id: "1")])
            try repo.setHistoryId("42", for: "me@example.com")
        }
        let reopened = MailRepository(db: try Database(path: url.path))
        #expect(reopened.account("me@example.com")?.historyId == "42")
        #expect(reopened.threads(ThreadQuery()).count == 1)
        #expect(reopened.tags().count == Tag.defaults.count)
    }
}
