import Foundation
import Testing
@testable import NookCore

@Suite("MIME parsing")
struct MIMEParserTests {
    private func encoded(_ string: String, encoding: String.Encoding = .utf8) -> String {
        MIMEBuilder.base64URL(string.data(using: encoding)!)
    }

    @Test func parsesHeadersBodiesAndLabels() {
        let gmail = GmailMessage(
            id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], snippet: "It&#39;s &amp; ok",
            internalDate: "1700000000000",
            payload: GmailMessagePart(
                mimeType: "multipart/alternative",
                headers: [
                    GmailHeader(name: "From", value: "\"Doe, Jane\" <jane@example.com>"),
                    GmailHeader(name: "to", value: "me@example.com"),
                    GmailHeader(name: "Cc", value: "a@example.com, b@example.com"),
                    GmailHeader(name: "Reply-To", value: "list@example.com"),
                    GmailHeader(name: "Subject", value: "Café ☕️"),
                    GmailHeader(name: "Message-Id", value: "<abc@example.com>"),
                    GmailHeader(name: "References", value: "<root@example.com>"),
                ],
                parts: [
                    GmailMessagePart(mimeType: "text/plain", body: GmailBody(data: encoded("Plain ☕️"))),
                    GmailMessagePart(mimeType: "text/html", body: GmailBody(data: encoded("<p>Rich ☕️</p>"))),
                ]
            )
        )

        let message = MIMEParser.message(from: gmail, account: "me@example.com")
        #expect(message.fromName == "Doe, Jane")
        #expect(message.fromEmail == "jane@example.com")
        #expect(message.to == "me@example.com")
        #expect(message.cc == "a@example.com, b@example.com")
        #expect(message.replyTo == "list@example.com")
        #expect(message.subject == "Café ☕️")
        #expect(message.snippet == "It's & ok")
        #expect(message.bodyText == "Plain ☕️")
        #expect(message.bodyHTML == "<p>Rich ☕️</p>")
        #expect(message.messageIdHeader == "<abc@example.com>")
        #expect(message.references == "<root@example.com>")
        #expect(message.labels == ["INBOX", "UNREAD"])
        #expect(message.isUnread)
        #expect(message.date == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func walksNestedMultipartAndSkipsAttachments() {
        let payload = GmailMessagePart(mimeType: "multipart/mixed", parts: [
            GmailMessagePart(mimeType: "multipart/related", parts: [
                GmailMessagePart(mimeType: "multipart/alternative", parts: [
                    GmailMessagePart(mimeType: "text/html", body: GmailBody(data: encoded("<b>Hi</b>"))),
                ]),
            ]),
            GmailMessagePart(mimeType: "text/plain", filename: "notes.txt", body: GmailBody(data: encoded("attachment text"))),
        ])
        let message = MIMEParser.message(from: GmailMessage(id: "1", payload: payload), account: "a")
        #expect(message.bodyHTML == "<b>Hi</b>")
        // With no text/plain part, the text comes from the HTML.
        #expect(message.bodyText == "Hi")
        #expect(message.threadId == "1")
    }

    @Test func honorsCharsets() {
        let part = GmailMessagePart(
            mimeType: "text/plain",
            headers: [GmailHeader(name: "Content-Type", value: "text/plain; charset=\"ISO-8859-1\"")],
            body: GmailBody(data: encoded("Grüße", encoding: .isoLatin1))
        )
        #expect(MIMEParser.message(from: GmailMessage(id: "1", payload: part), account: "a").bodyText == "Grüße")
        #expect(MIMEParser.charset(in: "text/html; charset=UTF-8; format=flowed") == "utf-8")
        #expect(MIMEParser.charset(in: "text/html") == nil)
    }

    @Test func decodesUnpaddedBase64URL() {
        // "subjects?" encodes to base64 with "/" and padding; base64url swaps and drops them.
        #expect(MIMEParser.decodeBase64URL("c3ViamVjdHM_") == Data("subjects?".utf8))
        #expect(MIMEParser.decodeBase64URL("YQ") == Data("a".utf8))
    }

    @Test func plainTextFromHTML() {
        let html = """
        <html><head><style>p { color: red }</style><title>x</title></head>
        <body><p>Hello&nbsp;<b>world</b></p><script>alert(1)</script><!-- hidden --><div>Line&nbsp;2 &mdash; ok</div></body></html>
        """
        #expect(MIMEParser.plainText(fromHTML: html) == "Hello world\nLine 2 — ok")
    }

    @Test func decodesEntities() {
        #expect(MIMEParser.decodeEntities("&lt;a&gt; &amp; &#39;b&#x27; &unknown; & alone") == "<a> & 'b' &unknown; & alone")
        #expect(MIMEParser.decodeEntities("&#128512;") == "😀")
    }
}

@Suite("MIME building")
struct MIMEBuilderTests {
    @Test func buildsAReplyWithThreadingHeaders() throws {
        let draft = Draft(
            from: "me@example.com", to: "Anna <anna@example.com>", cc: "ben@example.com", subject: "Re: Plans",
            body: "Sounds good\nSee you", threadId: "t1", inReplyTo: "<m2@x>", references: "<m1@x>"
        )
        let raw = MIMEBuilder.rfc822(draft, fromName: "Me Myself", date: Date(timeIntervalSince1970: 0))
        let (head, body) = try #require(split(raw))

        #expect(head.contains("From: Me Myself <me@example.com>"))
        #expect(head.contains("To: Anna <anna@example.com>"))
        #expect(head.contains("Cc: ben@example.com"))
        #expect(head.contains("Subject: Re: Plans"))
        #expect(head.contains("In-Reply-To: <m2@x>"))
        #expect(head.contains("References: <m1@x> <m2@x>"))
        #expect(head.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(String(data: Data(base64Encoded: body, options: .ignoreUnknownCharacters)!, encoding: .utf8) == "Sounds good\r\nSee you")
    }

    @Test func omitsEmptyOptionalHeaders() {
        let raw = MIMEBuilder.rfc822(Draft(from: "me@example.com", to: "a@b.c", subject: "Hi"), fromName: "")
        #expect(!raw.contains("Cc:"))
        #expect(!raw.contains("In-Reply-To:"))
        #expect(raw.contains("From: me@example.com\r\n"))
    }

    @Test func encodesNonASCIIHeaders() {
        #expect(MIMEBuilder.encodeHeader("Hello") == "Hello")
        #expect(MIMEBuilder.encodeHeader("Café") == "=?UTF-8?B?Q2Fmw6k=?=")
    }

    @Test func gmailRawIsBase64URLWithoutPadding() {
        let raw = MIMEBuilder.gmailRaw(Draft(from: "me@example.com", to: "a@b.c", subject: "??>>", body: "ÿÿÿ"), fromName: "Me")
        #expect(!raw.contains("+") && !raw.contains("/") && !raw.contains("="))
        let decoded = MIMEParser.decodeBase64URL(raw).map { String(decoding: $0, as: UTF8.self) }
        #expect(decoded?.contains("Subject: ??>>") == true)
    }

    private func split(_ raw: String) -> (String, String)? {
        guard let range = raw.range(of: "\r\n\r\n") else { return nil }
        return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
    }
}

@Suite("Addresses")
struct AddressTests {
    @Test func parsesSingleAddresses() {
        #expect(Addresses.parse("Jane <jane@x.com>") == EmailAddress(name: "Jane", email: "jane@x.com"))
        #expect(Addresses.parse("\"Doe, Jane\" <jane@x.com>") == EmailAddress(name: "Doe, Jane", email: "jane@x.com"))
        #expect(Addresses.parse("<jane@x.com>") == EmailAddress(name: "jane@x.com", email: "jane@x.com"))
        #expect(Addresses.parse(" jane@x.com ") == EmailAddress(name: "jane@x.com", email: "jane@x.com"))
    }

    @Test func splitsListsRespectingQuotes() {
        let list = Addresses.parseList("\"Doe, Jane\" <jane@x.com>, bob@y.com; Carl <carl@z.com>,")
        #expect(list.map(\.email) == ["jane@x.com", "bob@y.com", "carl@z.com"])
        #expect(list.first?.name == "Doe, Jane")
        #expect(Addresses.parseList("").isEmpty)
    }

    @Test func formatsForHeaders() {
        #expect(EmailAddress(name: "Jane", email: "j@x.com").formatted == "Jane <j@x.com>")
        #expect(EmailAddress(name: "Doe, Jane", email: "j@x.com").formatted == "\"Doe, Jane\" <j@x.com>")
        #expect(EmailAddress(name: "j@x.com", email: "j@x.com").formatted == "j@x.com")
    }

    @Test func displayNamesAndInitials() {
        #expect(Addresses.displayName(name: "", email: "jane.doe@x.com") == "jane.doe")
        #expect(Addresses.initials(name: "Jane Doe", email: "") == "JD")
        #expect(Addresses.initials(name: "", email: "jane.doe@x.com") == "JD")
        #expect(Addresses.initials(name: "", email: "") == "?")
        #expect(Addresses.initials(name: "Deven at WarmDogo", email: "") == "DW")
        #expect(Addresses.initials(name: "Priya K Natarajan", email: "") == "PN")
        #expect(Addresses.initials(name: "The Margin", email: "") == "M")
        #expect(Addresses.initials(name: "Stripe", email: "") == "S")
    }
}
