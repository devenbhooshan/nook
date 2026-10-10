import Foundation
import Testing
@testable import NookCore

/// Regression tests for the second round of review fixes.
@Suite("Review fixes")
struct ReviewFixTests {
    let account = "me@example.com"

    func setUp(_ messages: [GmailMessage]) throws -> (MailRepository, FakeGmail, SyncEngine) {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        let gmail = FakeGmail(messages: messages)
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail })
        return (repo, gmail, engine)
    }

    // MARK: 1. Expired history

    @Test func anExpiredCursorReconcilesMailOutsideTheListingWindow() async throws {
        let (repo, gmail, engine) = try setUp([
            gmailMessage(id: "new", labels: ["INBOX"], date: Date(timeIntervalSince1970: 300)),
            gmailMessage(id: "old1", labels: ["INBOX"], date: Date(timeIntervalSince1970: 200)),
            gmailMessage(id: "old2", labels: ["INBOX"], date: Date(timeIntervalSince1970: 100)),
        ])
        try await engine.sync(account)

        // A week later the listing window only covers the newest message. Meanwhile, on the phone,
        // old1 was archived and old2 deleted.
        await engine.configure(initialLimit: 1)
        await gmail.relabel("old1", labels: [], historyId: "101")
        await gmail.delete("old2", historyId: "102")
        await gmail.expireHistory()

        try await engine.sync(account)
        #expect(repo.message(account: account, id: "old1")?.labels == [])
        #expect(repo.message(account: account, id: "old2") == nil)
        #expect(repo.threads(ThreadQuery(mailbox: .inbox)).map(\.threadId) == ["new"])
    }

    // MARK: 4. Recent actions vs. a stale sync

    @Test func aSyncDoesntUndoAConversationTheUserJustChanged() async throws {
        let clock = FixedClock()
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        let gmail = FakeGmail(messages: [gmailMessage(id: "1", thread: "T", labels: ["INBOX"])])
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail }, now: { clock.now })
        try await engine.sync(account)

        // The user archives locally; a history record from before that arrives with the old labels.
        try repo.modifyThread(account: account, threadId: "T", add: [], remove: ["INBOX"])
        await engine.protect(account: account, threadId: "T", for: 30)
        await gmail.relabel("1", labels: ["INBOX", "UNREAD"], historyId: "101")
        try await engine.sync(account)
        #expect(repo.message(account: account, id: "1")?.labels == [], "the stale update put it back in the inbox")

        // After the window, updates apply again.
        clock.advance(31)
        await gmail.relabel("1", labels: ["STARRED"], historyId: "102")
        try await engine.sync(account)
        #expect(repo.message(account: account, id: "1")?.labels == ["STARRED"])
    }

    // MARK: 5. No bulk downloads

    @Test func labelChangesOnUnstoredMailOnlyDownloadWhatBecomesVisible() async throws {
        let (repo, gmail, engine) = try setUp([gmailMessage(id: "seen")])
        try await engine.sync(account)
        await gmail.resetCounters()

        // "Mark all as read" on old archived mail Nook never downloaded: nothing to fetch.
        for i in 0..<5 {
            await gmail.add(gmailMessage(id: "archived\(i)", labels: []), historyId: "100")
            await gmail.relabel("archived\(i)", labels: [], historyId: "\(101 + i)")
        }
        // An old message moved back to the inbox: worth fetching.
        await gmail.add(gmailMessage(id: "back", labels: []), historyId: "100")
        await gmail.relabel("back", labels: ["INBOX"], historyId: "110")
        // A draft being written: never stored, so never fetched.
        await gmail.add(gmailMessage(id: "draft", labels: ["DRAFT"]), historyId: "111")

        try await engine.sync(account)
        #expect(await gmail.fullFetches == ["back"])
        #expect(repo.messageIds(account: account) == ["seen", "back"])
    }

    // MARK: 2. Charsets

    @Test(arguments: [
        ("windows-1251", "Привет, мир"),
        ("koi8-r", "Привет"),
        ("iso-8859-2", "Łódź, Kraków"),
        ("gb18030", "你好，世界"),
        ("big5", "你好"),
        ("euc-kr", "안녕하세요"),
        ("shift_jis", "こんにちは"),
    ])
    func decodesCommonCharsets(charset: String, text: String) throws {
        let encoding = try #require(MIMEParser.encoding(forCharset: charset))
        let data = try #require(text.data(using: encoding))
        #expect(MIMEParser.decode(data, charset: charset) == text)
    }

    @Test func undeclaredNonUTF8TextKeepsEveryCharacter() {
        let bytes = Data([0x43, 0x61, 0x66, 0xE9]) // "Café" in Windows-1252, invalid as UTF-8
        #expect(MIMEParser.decode(bytes, charset: nil) == "Café")
    }

    // MARK: 3. Attached emails

    @Test func anAttachedEmailDoesntBecomeTheBody() {
        func encoded(_ s: String) -> String { MIMEBuilder.base64URL(Data(s.utf8)) }
        let payload = GmailMessagePart(mimeType: "multipart/mixed", parts: [
            GmailMessagePart(mimeType: "text/html", body: GmailBody(data: encoded("<p>See the forwarded thread</p>"))),
            GmailMessagePart(mimeType: "message/rfc822", parts: [
                GmailMessagePart(mimeType: "text/plain", body: GmailBody(data: encoded("Text of the attached email"))),
            ]),
            GmailMessagePart(
                mimeType: "text/plain",
                headers: [GmailHeader(name: "Content-Disposition", value: "attachment; filename=\"notes.txt\"")],
                body: GmailBody(data: encoded("Attached notes"))
            ),
        ])
        let message = MIMEParser.message(from: GmailMessage(id: "1", payload: payload), account: "a")
        #expect(message.bodyText == "See the forwarded thread")
    }

    // MARK: 7. Tag renames

    @Test func renamingATagKeepsItsAssignments() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        try repo.upsert([.fixture(id: "1", thread: "T"), .fixture(id: "2", thread: "U")])
        try repo.setAutoTags(["Receipt"], account: account, messageId: "1")
        try repo.toggleTag("Receipt", account: account, threadId: "U") // by hand

        var tags = repo.tags()
        let index = try #require(tags.firstIndex { $0.name == "Receipt" })
        tags[index].name = "Receipts"
        try repo.saveTags(tags, renames: ["Receipt": "Receipts"])

        #expect(repo.tags(account: account, messageId: "1") == ["Receipts"])
        #expect(repo.tags(account: account, messageId: "2") == ["Receipts"])
        #expect(repo.threads(ThreadQuery(split: .tag("Receipts"))).count == 2)
    }

    // MARK: 8. Direct lookup

    @Test func findsAConversationWhereverItIs() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        try repo.upsert([
            .fixture(id: "1", thread: "Archived", labels: []),
            .fixture(id: "2", thread: "Binned", labels: ["TRASH"]),
        ])
        #expect(repo.thread(account: account, threadId: "Archived")?.latestMessageId == "1")
        #expect(repo.thread(account: account, threadId: "Binned")?.latestMessageId == "2")
        #expect(repo.thread(account: account, threadId: "Nope") == nil)
    }

    // MARK: 14. OAuth callback

    @Test func theSignInListenerIgnoresCallbacksForOtherSignIns() async throws {
        let server = LoopbackServer(expectedState: "ours")
        let port = try await server.start()
        defer { server.stop() }
        async let parameters = server.waitForCallback(timeout: .seconds(5))

        let (_, forged) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?error=access_denied&state=other")!)
        #expect((forged as? HTTPURLResponse)?.statusCode == 400)
        let (_, real) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=abc&state=ours")!)
        #expect((real as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await parameters == ["code": "abc", "state": "ours"])
    }

    // MARK: 12. Keyboard layouts and Caps Lock

    @Test func shortcutsIgnoreCapsLockAndAllowLayoutSpecificCharacters() {
        // Caps Lock on: characters is "U", but the key is still "u" (toggle read), not "U" (unread filter).
        #expect(ShortcutInterpreter.shortcutCharacters(characters: "U", ignoringModifiers: "u", option: false) == "u")
        // Shift really held: both say "U".
        #expect(ShortcutInterpreter.shortcutCharacters(characters: "U", ignoringModifiers: "U", option: false) == "U")
        // UK layout: Option-3 types "#".
        #expect(ShortcutInterpreter.shortcutCharacters(characters: "#", ignoringModifiers: "3", option: true) == "#")
        // Other Option combinations aren't shortcuts.
        #expect(ShortcutInterpreter.shortcutCharacters(characters: "é", ignoringModifiers: "e", option: true) == nil)
    }

    // MARK: 16. Remote Ollama

    @Test func onlyLoopbackOllamaAddressesCountAsLocal() {
        #expect(TaggingSettings.isLocal(ollamaURL: "http://localhost:11434"))
        #expect(TaggingSettings.isLocal(ollamaURL: "http://127.0.0.1:11434"))
        #expect(TaggingSettings.isLocal(ollamaURL: "http://[::1]:11434"))
        #expect(TaggingSettings.isLocal(ollamaURL: " http://LOCALHOST:11434 "))
        #expect(!TaggingSettings.isLocal(ollamaURL: "http://192.168.1.20:11434"))
        #expect(!TaggingSettings.isLocal(ollamaURL: "https://ollama.example.com"))
        #expect(!TaggingSettings.isLocal(ollamaURL: "http://localhost.example.com"))
        #expect(!TaggingSettings.isLocal(ollamaURL: "not a url"))
    }
}
