import Foundation
import Testing
@testable import NookCore

/// Bodies are kept compressed and the search index keeps only words, which took a big store from 7.6 GB toward 2.
@Suite("Store slimming")
struct StoreSlimmingTests {
    let account = "me@example.com"
    let longHTML = "<div>" + String(repeating: "<p>Quarterly report: revenue grew and churn fell. </p>", count: 400) + "</div>"

    func search(_ repo: MailRepository, _ text: String) -> [String] {
        repo.threads(ThreadQuery(search: SearchQuery.parse(text), limit: 50)).map(\.threadId).sorted()
    }

    @Test func bodiesAreStoredCompressedAndReadBackExactly() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        var message = MailMessage.fixture(id: "1", thread: "T", body: "plain text body " + String(repeating: "words ", count: 200))
        message.bodyHTML = longHTML
        try repo.upsert([message, .fixture(id: "2", thread: "U", body: "short")])

        let stored = try repo.db.query("SELECT body_html, body_text FROM message_bodies WHERE id = '1'")[0]
        let packed = try #require(stored.data("body_html"))
        #expect(packed.count < longHTML.utf8.count / 5, "compressed \(longHTML.utf8.count) → \(packed.count) bytes")
        #expect(repo.message(account: account, id: "1")?.bodyHTML == longHTML)
        #expect(repo.message(account: account, id: "1")?.bodyText == message.bodyText)
        // Short bodies stay text.
        #expect(try repo.db.query("SELECT body_text FROM message_bodies WHERE id = '2'")[0].string("body_text") == "short")
    }

    @Test func aNewStoreUsesTheLeanIndex() throws {
        let repo = try makeRepository()
        #expect(repo.searchIndexIsLean)
        try repo.addAccount(email: account, name: "Me")
        try repo.upsert([.fixture(id: "1", thread: "T", subject: "Invoice for March")])
        #expect(search(repo, "invoice") == ["T"])
        try repo.deleteMessages(account: account, ids: ["1"])
        #expect(search(repo, "invoice").isEmpty)
    }

    /// A store from before: text bodies and the old index that kept a copy of the text.
    func oldStyleStore() throws -> MailRepository {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        try repo.db.run("""
        DROP TABLE messages_fts;
        CREATE VIRTUAL TABLE messages_fts USING fts5(account UNINDEXED, id UNINDEXED, subject, sender, body, tokenize = 'unicode61 remove_diacritics 2');
        \(SearchIndex.createLean(named: SearchIndex.leanName));
        """)
        #expect(!repo.searchIndexIsLean)
        try repo.upsert((0..<30).map { .fixture(id: "m\($0)", thread: "t\($0)", subject: $0 % 3 == 0 ? "Invoice \($0)" : "Hello \($0)") })
        // Bodies as they used to be stored: text.
        try repo.db.execute("UPDATE message_bodies SET body_html = ?, body_text = 'old body'", [longHTML])
        return repo
    }

    @Test func anOldStoreIsSlimmedInTheBackgroundWithoutLosingAnything() throws {
        let repo = try oldStyleStore()
        let before = search(repo, "invoice")
        #expect(before.count == 10)

        var cursor = 0
        while let next = try repo.compressBodies(after: cursor, limit: 7) { cursor = next }
        #expect(try repo.db.query("SELECT 1 AS x FROM message_bodies WHERE typeof(body_html) = 'text' AND length(body_html) > 256").isEmpty)
        #expect(repo.message(account: account, id: "m4")?.bodyHTML == longHTML)

        cursor = 0
        var steps = 0
        while let next = try repo.slimSearchIndex(after: cursor, limit: 8) {
            cursor = next
            steps += 1
            // Mail keeps arriving and going while the index is copied.
            if steps == 2 {
                try repo.deleteMessages(account: account, ids: ["m0"])
                try repo.upsert([.fixture(id: "late", thread: "late", subject: "Invoice late")])
            }
            #expect(search(repo, "hello").count == 20, "search works throughout")
        }
        #expect(repo.searchIndexIsLean)
        #expect(search(repo, "invoice") == (before.filter { $0 != "t0" } + ["late"]).sorted())
        // New mail after the switch goes into the lean index.
        try repo.upsert([.fixture(id: "after", thread: "after", subject: "Invoice after")])
        #expect(search(repo, "invoice").contains("after"))
    }
}
