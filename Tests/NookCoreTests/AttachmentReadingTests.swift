import AppKit
import Foundation
import Testing
@testable import NookCore

@Suite("Reading attachments over MCP")
struct AttachmentReadingTests {
    static let account = "me@example.com"
    let repo: MailRepository
    let gmail = FakeGmail()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-tests-\(UUID().uuidString)")
    let server: MCPServer

    init() throws {
        repo = try makeRepository()
        try repo.addAccount(email: Self.account, name: "Me")
        var message = MailMessage.fixture(id: "1", thread: "T", subject: "Contracts")
        message.attachments = [
            Attachment(partId: "1", filename: "notes.txt", mimeType: "text/plain", size: 5, attachmentId: "a-notes"),
            Attachment(partId: "2", filename: "photo.bin", mimeType: "application/octet-stream", size: 3, attachmentId: "a-photo"),
            Attachment(partId: "3", filename: "same.txt", mimeType: "text/plain", size: 1, attachmentId: "a-one"),
            Attachment(partId: "4", filename: "same.txt", mimeType: "text/plain", size: 1, attachmentId: "a-two"),
        ]
        try repo.upsert([message])
        let gmail = gmail
        let root = root
        server = MCPServer(
            repo: repo, version: "test", isEnabled: { true }, openURL: { _ in }, makeGmail: { _ in gmail },
            attachmentCache: { AttachmentCache(root: root) }, createdDrafts: CreatedDrafts(defaults: UserDefaults(suiteName: "nook-tests-\(UUID().uuidString)")!)
        )
    }

    func read(_ filename: String, part: String? = nil, message: String = "1") throws -> (result: [String: Any], isError: Bool) {
        var arguments: [String: Any] = ["account": Self.account, "thread_id": "T", "message_id": message, "filename": filename]
        if let part { arguments["part_id"] = part }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_attachment", "arguments": arguments]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try #require(decoded["result"] as? [String: Any])
        return (result["structuredContent"] as? [String: Any] ?? [:], result["isError"] as? Bool ?? false)
    }

    @Test func getThreadGivesTheMessageId() throws {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_thread", "arguments": ["account": Self.account, "thread_id": "T"]]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        #expect(response.contains(#""id":"1""#))
        #expect(response.contains(#""part_id":"3""#))
    }

    @Test func aStoredFileNeverGoesToGmail() throws {
        try repo.storeAttachments(account: Self.account, messageId: "1", files: [("1", Data("from the store".utf8))])
        #expect(try read("notes.txt").result["text"] as? String == "from the store")
    }

    @Test func fallsBackToGmailWhenNotStored() async throws {
        await gmail.setAttachment("a-notes", data: Data("from gmail".utf8))
        #expect(try read("notes.txt").result["text"] as? String == "from gmail")
    }

    @Test func binaryFilesAreSavedNotInlined() throws {
        try repo.storeAttachments(account: Self.account, messageId: "1", files: [("2", Data([0, 1, 2]))])
        let result = try read("photo.bin").result
        #expect(result["text"] == nil)
        let path = try #require(result["path"] as? String)
        #expect(FileManager.default.contents(atPath: path) == Data([0, 1, 2]))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aRepeatedNameNeedsThePartId() throws {
        try repo.storeAttachments(account: Self.account, messageId: "1", files: [("3", Data("one".utf8)), ("4", Data("two".utf8))])
        #expect(try read("same.txt").isError)
        #expect(try read("same.txt", part: "4").result["text"] as? String == "two")
    }

    @Test func refusesWhatIsntThere() throws {
        #expect(try read("missing.pdf").isError)
        #expect(try read("notes.txt", message: "2").isError)
    }

    @Test func readsPDFText() throws {
        let attachment = Attachment(partId: "1", filename: "a.pdf", mimeType: "application/pdf", size: 0)
        let extraction = AttachmentReader.read(Self.pdf(text: "Invoice total 1234"), attachment: attachment)
        #expect(extraction.text?.contains("Invoice total 1234") == true)
        #expect(extraction.pages == 1)
    }

    @Test func aPDFWithoutTextSaysSo() {
        let attachment = Attachment(partId: "1", filename: "a.pdf", mimeType: "application/pdf", size: 0)
        let extraction = AttachmentReader.read(Self.pdf(text: ""), attachment: attachment)
        #expect(extraction.text == nil)
        #expect(extraction.note?.contains("no text layer") == true)
    }

    @Test func longTextIsCutShort() {
        let attachment = Attachment(partId: "1", filename: "a.txt", mimeType: "text/plain", size: 0)
        let extraction = AttachmentReader.read(Data(String(repeating: "x", count: 100_001).utf8), attachment: attachment)
        #expect(extraction.truncated)
        #expect(extraction.text?.count == AttachmentReader.maxTextCharacters)
    }

    @Test(arguments: [
        ("../../etc/passwd", "_.._etc_passwd"), ("..hidden", "hidden"), ("a/b\\c:d.pdf", "a_b_c_d.pdf"),
        ("", "attachment"), ("...", "attachment"), ("line\nbreak.txt", "line_break.txt"),
    ])
    func sanitisesFilenames(name: String, expected: String) {
        #expect(AttachmentCache.safeFilename(name) == expected)
    }

    @Test func longFilenamesKeepTheirExtension() {
        let safe = AttachmentCache.safeFilename(String(repeating: "a", count: 300) + ".pdf")
        #expect(safe.utf8.count == 120)
        #expect(safe.hasSuffix(".pdf"))
    }

    static func pdf(text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        (text as NSString).draw(at: CGPoint(x: 20, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

@Suite("Storing attachments")
struct AttachmentStorageTests {
    let repo: MailRepository
    let account = "me@example.com"

    init() throws {
        repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
    }

    func addMessage(_ id: String, minutesAgo: Double, size: Int = 10, inline: Bool = false, attachmentId: String? = nil) throws {
        var message = MailMessage.fixture(id: id, minutesAgo: minutesAgo)
        message.attachments = [Attachment(partId: "1", filename: "\(id).pdf", mimeType: "application/pdf", size: size, attachmentId: attachmentId ?? "a-\(id)", isInline: inline)]
        try repo.upsert([message])
    }

    @Test func storesBlobsAndForgetsThemWithTheMessage() throws {
        try addMessage("1", minutesAgo: 1)
        try repo.storeAttachments(account: account, messageId: "1", files: [("1", Data([1, 2, 3]))])
        #expect(repo.storedAttachment(account: account, messageId: "1", partId: "1") == Data([1, 2, 3]))
        #expect(repo.messagesAwaitingAttachments(account: account, budget: 1000, limit: 10).isEmpty)
        try repo.deleteMessages(account: account, ids: ["1"])
        #expect(repo.storedAttachment(account: account, messageId: "1", partId: "1") == nil)
    }

    @Test func removingAnAccountRemovesItsFiles() throws {
        try addMessage("1", minutesAgo: 1)
        try repo.storeAttachments(account: account, messageId: "1", files: [("1", Data([1]))])
        try repo.removeAccount(account)
        #expect(repo.storedAttachment(account: account, messageId: "1", partId: "1") == nil)
    }

    @Test func newestMailComesFirst() throws {
        try addMessage("old", minutesAgo: 100)
        try addMessage("new", minutesAgo: 1)
        #expect(repo.messagesAwaitingAttachments(account: account, budget: 1000, limit: 10) == ["new", "old"])
    }

    @Test func overBudgetDropsTheOldestAndStopsReachingBack() throws {
        try addMessage("older", minutesAgo: 300)
        try addMessage("old", minutesAgo: 200)
        try addMessage("mid", minutesAgo: 100)
        try addMessage("new", minutesAgo: 1)
        try repo.storeAttachments(account: account, messageId: "old", files: [("1", Data(count: 60))])
        try repo.storeAttachments(account: account, messageId: "mid", files: [("1", Data(count: 60))])
        try repo.trimStoredAttachments(toBudget: 100)
        #expect(repo.storedAttachment(account: account, messageId: "old", partId: "1") == nil)
        #expect(repo.storedAttachment(account: account, messageId: "mid", partId: "1") != nil)
        // `mid` alone is at a 60-byte budget, so only mail newer than it is worth fetching.
        #expect(repo.messagesAwaitingAttachments(account: account, budget: 60, limit: 10) == ["new"])
    }

    @Test func theLimitComesFromSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "nook-tests-\(UUID().uuidString)"))
        #expect(AttachmentStorage.limit(in: defaults) == AttachmentStorage.bytes(gigabytes: 50))
        defaults.set(10, forKey: AttachmentStorage.limitKey)
        #expect(AttachmentStorage.limit(in: defaults) == AttachmentStorage.bytes(gigabytes: 10))
    }

    @Test func aLowerLimitTakesEffectOnTheNextRun() async throws {
        try addMessage("old", minutesAgo: 100)
        try addMessage("new", minutesAgo: 1)
        try repo.storeAttachments(account: account, messageId: "old", files: [("1", Data(count: 60))])
        try repo.storeAttachments(account: account, messageId: "new", files: [("1", Data(count: 60))])
        try repo.setHistoryId("100", for: account)
        let engine = SyncEngine(repo: repo, makeService: { _ in FakeGmail() }, attachmentBudget: { 100 })
        try await engine.sync(account)
        await engine.forget(account)
        #expect(repo.storedAttachment(account: account, messageId: "old", partId: "1") == nil)
        #expect(repo.storedAttachment(account: account, messageId: "new", partId: "1") != nil)
    }

    @Test func aHigherLimitBringsDroppedFilesBack() throws {
        try addMessage("old", minutesAgo: 100)
        try addMessage("new", minutesAgo: 1)
        try repo.storeAttachments(account: account, messageId: "old", files: [("1", Data(count: 60))])
        try repo.storeAttachments(account: account, messageId: "new", files: [("1", Data(count: 60))])
        try repo.trimStoredAttachments(toBudget: 100)
        #expect(repo.messagesAwaitingAttachments(account: account, budget: 1000, limit: 10).isEmpty)
        try repo.retrySkippedAttachments()
        #expect(repo.messagesAwaitingAttachments(account: account, budget: 1000, limit: 10) == ["old"])
    }

    @Test func syncDownloadsFilesInTheBackground() async throws {
        let gmail = FakeGmail()
        await gmail.setAttachment("a-big", data: Data("stored".utf8))
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail }, onChange: {})
        try addMessage("1", minutesAgo: 1, attachmentId: "a-big")
        try addMessage("huge", minutesAgo: 2, size: SyncEngine.largestStoredAttachment + 1)
        try addMessage("inline", minutesAgo: 3, inline: true)
        try repo.setHistoryId("100", for: account)
        try await engine.sync(account)
        for _ in 0..<100 where !repo.messagesAwaitingAttachments(account: account, budget: 1 << 40, limit: 1).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        await engine.forget(account)
        #expect(repo.storedAttachment(account: account, messageId: "1", partId: "1") == Data("stored".utf8))
        #expect(repo.storedAttachment(account: account, messageId: "huge", partId: "1") == nil)
        #expect(repo.storedAttachment(account: account, messageId: "inline", partId: "1") == nil)
        #expect(repo.messagesAwaitingAttachments(account: account, budget: 1 << 40, limit: 10).isEmpty)
    }
}
