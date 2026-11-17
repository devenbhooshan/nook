import Foundation
import Testing
import WebKit
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
        #expect(draft.body.isEmpty)
        #expect(draft.quoted.contains("Anna wrote:\n> Line one\n> Line two"))
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
        #expect(draft.quoted.contains("From: Anna <anna@x.com>"))
        #expect(draft.quoted.hasSuffix("See attached"))
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

/// Renders documents in WebKit and reads the colour each link ends up with.
@Suite("EmailHTML links")
@MainActor
struct EmailHTMLLinkTests {
    /// The Supergrow review email (sent with Loops): its stylesheet resets every link to the colour of the text.
    static let loopsBody = """
    <html><head><style type="text/css">
    a { text-decoration: none; color: inherit; }
    @media (prefers-color-scheme: dark) { a { color: inherit; } }
    .button a { color: rgb(1, 2, 3); }
    a.brand { color: rgb(4, 5, 6); }
    </style></head><body><div style="color: rgb(0, 0, 0)">
    <a id="plain" href="https://app.supergrow.ai/review/x">Open the post to review and approve it</a>
    <a id="inline" href="https://x.example" style="color: rgb(200, 0, 0)">red</a>
    <span class="button"><a id="classed" href="https://x.example">button</a></span>
    <a id="own" class="brand" href="https://x.example">brand</a>
    <a id="anchor" name="top">not a link</a>
    </div></body></html>
    """

    @Test func linksGetALinkColourUnlessTheEmailColoursThemItself() async throws {
        var message = MailMessage.fixture(id: "1")
        message.bodyHTML = Self.loopsBody
        let colours = try await Self.linkColours(in: EmailHTML.document(for: message, allowRemoteContent: false))
        #expect(colours["plain"] == "rgb(11, 87, 208)")    // #0b57d0
        #expect(colours["inline"] == "rgb(200, 0, 0)")
        #expect(colours["classed"] == "rgb(1, 2, 3)")
        #expect(colours["own"] == "rgb(4, 5, 6)")
        #expect(colours["anchor"] == "rgb(0, 0, 0)")
    }

    static func linkColours(in document: String) async throws -> [String: String] {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let loaded = LoadWaiter()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(document, baseURL: nil)
        try await loaded.wait()
        let result = try await webView.evaluateJavaScript(
            "JSON.stringify(Object.fromEntries([...document.querySelectorAll('a[id]')].map(a => [a.id, getComputedStyle(a).color])))"
        )
        return try JSONDecoder().decode([String: String].self, from: Data((result as? String ?? "{}").utf8))
    }

    final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func wait() async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finished = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
