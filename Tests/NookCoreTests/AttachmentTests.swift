import Foundation
import Testing
@testable import NookCore

@Suite("Attachments")
struct AttachmentTests {
    private func encoded(_ string: String) -> String { MIMEBuilder.base64URL(Data(string.utf8)) }

    /// A reply with a PDF, an inline logo the HTML shows, an unreferenced image and an attached email.
    private func gmailWithFiles() -> GmailMessage {
        GmailMessage(
            id: "m1", threadId: "t1", labelIds: ["INBOX"], internalDate: "1700000000000",
            payload: GmailMessagePart(
                partId: "", mimeType: "multipart/mixed",
                headers: [GmailHeader(name: "From", value: "Anna <anna@x.com>"), GmailHeader(name: "Subject", value: "Files")],
                parts: [
                    GmailMessagePart(partId: "0", mimeType: "multipart/related", parts: [
                        GmailMessagePart(partId: "0.0", mimeType: "text/html", body: GmailBody(data: encoded("<p>Hi</p><img src=\"cid:LOGO@x\">"))),
                        GmailMessagePart(
                            partId: "0.1", mimeType: "image/png", filename: "logo.png",
                            headers: [GmailHeader(name: "Content-ID", value: "<logo@x>")],
                            body: GmailBody(size: 120, data: encoded("png"))
                        ),
                    ]),
                    GmailMessagePart(partId: "1", mimeType: "application/pdf", filename: "Invoice 42.pdf", body: GmailBody(size: 52_000, attachmentId: "att-1")),
                    GmailMessagePart(
                        partId: "2", mimeType: "image/jpeg", filename: "photo.jpg",
                        headers: [GmailHeader(name: "Content-ID", value: "<unused@x>")],
                        body: GmailBody(size: 900_000, attachmentId: "att-2")
                    ),
                    GmailMessagePart(partId: "3", mimeType: "message/rfc822", body: GmailBody(size: 3000, attachmentId: "att-3"), parts: [
                        GmailMessagePart(partId: "3.0", mimeType: "text/plain", body: GmailBody(data: encoded("Forwarded body"))),
                        GmailMessagePart(partId: "3.1", mimeType: "application/zip", filename: "nested.zip", body: GmailBody(size: 10, attachmentId: "att-4")),
                    ]),
                ]
            )
        )
    }

    @Test func parsesFilesAndMarksImagesTheBodyShows() throws {
        let message = MIMEParser.message(from: gmailWithFiles(), account: "me@x.com")
        #expect(message.attachments.map(\.filename) == ["logo.png", "Invoice 42.pdf", "photo.jpg", "Attached message.eml"])
        #expect(message.listedAttachments.map(\.filename) == ["Invoice 42.pdf", "photo.jpg", "Attached message.eml"])
        let logo = try #require(message.attachments.first)
        #expect(logo.isInline && logo.contentId == "logo@x" && logo.attachmentId == nil)
        #expect(message.attachments[1].attachmentId == "att-1" && message.attachments[1].size == 52_000)
        // The body is still this message's HTML, not the attached email's text.
        #expect(message.bodyHTML.contains("<p>Hi</p>"))
        #expect(MIMEParser.inlineData(partId: "0.1", in: gmailWithFiles()) == Data("png".utf8))
    }

    @Test func storesAttachmentsAndFindsThemInSearch() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@x.com", name: "Me")
        let withFiles = MIMEParser.message(from: gmailWithFiles(), account: "me@x.com")
        try repo.upsert([withFiles, MailMessage.fixture(id: "plain", account: "me@x.com")])

        let stored = try #require(repo.message(account: "me@x.com", id: "m1"))
        #expect(stored.attachments == withFiles.attachments)
        #expect(repo.threads(ThreadQuery(account: "me@x.com")).first { $0.threadId == "t1" }?.hasAttachments == true)
        #expect(repo.threads(ThreadQuery(account: "me@x.com")).first { $0.threadId == "plain" }?.hasAttachments == false)

        func search(_ text: String) -> [String] {
            repo.threads(ThreadQuery(account: "me@x.com", search: SearchQuery.parse(text))).map(\.threadId)
        }
        #expect(search("has:attachment") == ["t1"])
        #expect(search("filename:invoice") == ["t1"])
        #expect(search("filename:logo").isEmpty) // Inline images aren't files you'd search for.
        #expect(search("invoice") == ["t1"])
    }

    @Test func mailStoredBeforeAttachmentsIsFoundAndFilledIn() async throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        try repo.upsert([MailMessage.fixture(id: "m1", thread: "t1", labels: [SystemLabel.inbox])])
        // What an upgraded store looks like: no attachment info yet.
        try repo.db.execute("UPDATE message_bodies SET attachments = NULL")
        #expect(repo.messagesMissingAttachments(account: "me@example.com", threadId: "t1") == ["m1"])

        // Gmail's copy has a file, and still says unread; the local labels (read) win.
        var gmail = gmailWithFiles()
        gmail.threadId = "t1"
        gmail.labelIds = ["INBOX", "UNREAD"]
        let fake = FakeGmail(messages: [gmail])
        let engine = SyncEngine(repo: repo, makeService: { _ in fake })
        try await engine.fillInAttachments(account: "me@example.com", ids: ["m1"])

        let message = try #require(repo.message(account: "me@example.com", id: "m1"))
        #expect(message.listedAttachments.count == 3)
        #expect(!message.isUnread)
        #expect(repo.messagesMissingAttachments(account: "me@example.com", threadId: "t1").isEmpty)
    }

    @Test func buildsMultipartMessagesWithFiles() throws {
        var draft = Draft(from: "me@x.com", to: "anna@x.com", subject: "Report", body: "See attached")
        draft.attachments = [
            OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8)),
            OutgoingAttachment(filename: "Résumé \"final\".txt", mimeType: "text/plain", data: Data("cv".utf8)),
        ]
        let raw = MIMEBuilder.rfc822(draft, fromName: "Me", boundary: "B")
        #expect(raw.contains("Content-Type: multipart/mixed; boundary=\"B\""))
        #expect(raw.contains("--B\r\nContent-Type: text/plain; charset=utf-8"))
        #expect(raw.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
        #expect(raw.contains(Data("%PDF".utf8).base64EncodedString()))
        // Non-ASCII names use RFC 2231, and quotes can't break out of the parameter.
        #expect(raw.contains("filename*=UTF-8''R%C3%A9sum%C3%A9%20%27final%27.txt"))
        #expect(raw.hasSuffix("--B--\r\n"))
        // Without files, the message stays a single text part.
        #expect(!MIMEBuilder.rfc822(Draft(from: "me@x.com", to: "a@x.com", body: "Hi"), fromName: "Me").contains("multipart"))
    }

    @Test func sendsTheQuoteBelowWhatYouWrote() {
        var draft = Draft(from: "me@x.com", to: "a@x.com", body: "Sounds good\n\n")
        draft.quoted = "On Mon, Anna wrote:\n> Lunch?"
        #expect(draft.fullBody == "Sounds good\n\nOn Mon, Anna wrote:\n> Lunch?")
        draft.body = ""
        #expect(draft.fullBody == draft.quoted)
    }

    @Test func quotesDropRunsOfBlankLines() {
        #expect(ReplyComposer.tidy("Dear sir,\n\n\n\nThanks  \n\n\n") == "Dear sir,\n\nThanks")
    }

    @Test func marksTheTrailingQuoteInPlainText() {
        let html = EmailHTML.plainBody("Sure.\n\nOn Mon, Anna wrote:\n> Lunch?\n> Noon")
        #expect(html.hasPrefix("Sure."))
        #expect(html.contains("<div class=\"nook-quote\">On Mon, Anna wrote:\n&gt; Lunch?"))
        // All quote and nothing else: nothing to fold.
        #expect(!EmailHTML.plainBody("> just a quote").contains("nook-quote"))
    }

    @Test func searchUnderstandsAttachmentOperators() throws {
        let query = try #require(SearchQuery.parse("has:attachment filename:pdf taxes"))
        #expect(query.hasAttachment && query.filenames == ["pdf"] && query.terms == ["taxes"])
    }
}

@Suite("Gmail uploads")
struct GmailUploadTests {
    @Test func bigMessagesGoThroughTheUploadEndpoint() async throws {
        let transport = StubTransport([.init(200)])
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: nil)
        let big = MIMEBuilder.base64URL(Data(repeating: 65, count: GmailClient.simpleRequestLimit + 10))
        try await client.send(raw: big, threadId: "T")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString.hasPrefix("https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/related; boundary=") == true)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("{\"threadId\":\"T\"}"))
        #expect(body.contains("Content-Type: message/rfc822"))
    }
}

@Suite("Attachment quarantine")
struct AttachmentQuarantineTests {
    private func file(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    @Test("a file from an email is flagged, so Gatekeeper checks it before it runs")
    func flagsTheFile() throws {
        let url = try file("invoice.terminal")
        #expect(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties == nil)

        try AttachmentQuarantine.mark(url)

        let properties = try #require(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(properties["LSQuarantineAgentName"] as? String == "Nook")
    }

    @Test("a file that isn't there is an error, not a silent skip")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try AttachmentQuarantine.mark(url) }
    }
}
