import Foundation
import Testing
@testable import NookCore

@Suite("ReplyComposer")
struct ReplyComposerTests {
    let me = "me@example.com"

    @Test func replyGoesToTheSenderWithThreading() {
        var message = MailMessage.fixture(id: "1", thread: "T", from: "anna@x.com", fromName: "Anna", subject: "Plans", body: "Line one\nLine two")
        message.references = "<root@x>"
        let draft = ReplyComposer.draft(.reply, to: message, account: me)

        #expect(draft.from == me)
        #expect(draft.to == "Anna <anna@x.com>")
        #expect(draft.cc.isEmpty)
        #expect(draft.subject == "Re: Plans")
        #expect(draft.threadId == "T")
        #expect(draft.inReplyTo == "<1@mail.example.com>")
        #expect(draft.references == "<root@x>")
        #expect(draft.body.contains("Anna wrote:\n> Line one\n> Line two"))
    }

    @Test func replyHonorsReplyTo() {
        var message = MailMessage.fixture(id: "1", from: "noreply@x.com")
        message.replyTo = "Support <help@x.com>"
        #expect(ReplyComposer.draft(.reply, to: message, account: me).to == "Support <help@x.com>")
    }

    @Test func replyAllCopiesEveryoneExceptMe() {
        let message = MailMessage.fixture(id: "1", from: "anna@x.com", to: "ME@example.com, Ben <ben@x.com>", cc: "cy@x.com, anna@x.com")
        let draft = ReplyComposer.draft(.replyAll, to: message, account: me)
        #expect(draft.to == "Anna <anna@x.com>")
        #expect(draft.cc == "Ben <ben@x.com>, cy@x.com")
    }

    @Test func replyingToMyOwnMessageTargetsItsRecipients() {
        let message = MailMessage.fixture(id: "1", from: me, fromName: "Me", to: "Ben <ben@x.com>")
        #expect(ReplyComposer.draft(.reply, to: message, account: me).to == "Ben <ben@x.com>")
    }

    @Test func doesNotStackPrefixes() {
        #expect(ReplyComposer.prefixed("RE: Plans", with: "Re:") == "RE: Plans")
        #expect(ReplyComposer.prefixed("Fwd: x", with: "Fwd:") == "Fwd: x")
        #expect(ReplyComposer.prefixed("", with: "Re:") == "Re:")
    }

    @Test func forwardIncludesOriginalHeadersAndStartsANewThread() {
        let message = MailMessage.fixture(id: "1", from: "anna@x.com", fromName: "Anna", subject: "Deck", body: "See attached")
        let draft = ReplyComposer.draft(.forward, to: message, account: me)
        #expect(draft.to.isEmpty)
        #expect(draft.subject == "Fwd: Deck")
        #expect(draft.threadId == nil)
        #expect(draft.body.contains("From: Anna <anna@x.com>"))
        #expect(draft.body.hasSuffix("See attached"))
    }
}

@Suite("EmailHTML")
struct EmailHTMLTests {
    @Test func blocksRemoteContentByDefault() {
        let message = MailMessage.fixture(id: "1")
        var html = message
        html.bodyHTML = "<img src=\"https://tracker.example/p.gif\">"

        let blocked = EmailHTML.document(for: html, allowRemoteContent: false)
        #expect(blocked.contains("img-src data: cid:;"))
        #expect(!blocked.contains("img-src *"))
        #expect(blocked.hasPrefix("<meta charset"))

        let allowed = EmailHTML.document(for: html, allowRemoteContent: true)
        #expect(allowed.contains("img-src * data: cid:"))
    }

    @Test func plainTextIsEscapedAndLinked() {
        let message = MailMessage.fixture(id: "1", body: "<script>x</script> see https://example.com/a?b=1&c=2.")
        let document = EmailHTML.document(for: message, allowRemoteContent: false)
        #expect(document.contains("&lt;script&gt;x&lt;/script&gt;"))
        #expect(document.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a>."))
    }

    @Test(arguments: [
        ("<img src=\"https://t.co/x.gif\">", true),
        ("<img src='//cdn.example/x.png'>", true),
        ("<td background=\"http://x/bg.png\">", true),
        ("<div style=\"background:url('https://x/y.png')\">", true),
        ("<link rel=stylesheet href=\"https://fonts.example/x.css\">", true),
        ("<img src=\"cid:logo\"><a href=\"https://example.com\">link</a>", false),
        ("<img src=\"data:image/png;base64,AAAA\">", false),
    ])
    func detectsRemoteContent(html: String, expected: Bool) {
        #expect(EmailHTML.containsRemoteContent(html) == expected)
    }
}
