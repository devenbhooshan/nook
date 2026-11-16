import Foundation
import Testing
@testable import NookCore

/// Drafts with links, bold and lists: an assistant writes HTML, Gmail gets text and HTML, Nook can edit it.
extension MCPDraftTests {
    static let linked = #"<p>Hi Greg,</p><p>Here's <a href="https://example.com/jane">Jane Doe</a>, who runs <b>GIS</b>:</p><ul><li>Sysco</li><li>PNC &amp; Merck</li></ul>"#

    /// The message as Gmail stores it.
    func raw(_ draftId: String) async throws -> String {
        let drafts = await gmail.savedDrafts
        let saved = try #require(drafts[draftId]?.0)
        var base64 = saved.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
    }

    func part(_ type: String, of message: String) throws -> String {
        // Each part is base64 after its headers.
        let pattern = "Content-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n([A-Za-z0-9+/=\r\n]+)"
        let range = try #require(message.range(of: pattern, options: .regularExpression))
        let encoded = String(message[range]).components(separatedBy: "\r\n\r\n").last!.replacingOccurrences(of: "\r\n", with: "")
        return String(decoding: try #require(Data(base64Encoded: encoded)), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    @Test func aNewDraftCanLinkANameAndKeepsAPlainTextTwin() async throws {
        let made = try tool("compose_draft", ["to": "greg@esri.example", "subject": "Intro", "html": Self.linked])
        #expect(!made.isError, "\(made.text)")
        let id = try #require(made.result["draft_id"] as? String)

        let message = try await raw(id)
        #expect(message.contains("Content-Type: multipart/alternative"))
        let html = try part("text/html", of: message)
        #expect(html.contains(#"<a href="https://example.com/jane">Jane Doe</a>"#))
        #expect(html.contains("<b>GIS</b>") && html.contains("<li>Sysco</li>"))
        let text = try part("text/plain", of: message)
        #expect(text.contains("Jane Doe (https://example.com/jane)"), "the address survives in the text part: \(text)")
        #expect(text.contains("• Sysco\n• PNC & Merck"))

        // Read back: the text, and the formatting for an assistant that wants to edit it.
        let draft = try tool("get_draft", ["account": Self.account, "draft_id": id]).result
        #expect((draft["html"] as? String)?.contains(#"href="https://example.com/jane""#) == true)
        #expect((draft["body"] as? String)?.contains("Jane Doe") == true)
    }

    @Test func aFormattedReplyKeepsTheQuotedOriginal() async throws {
        let made = try tool("draft_reply", ["account": Self.account, "thread_id": "T", "html": Self.linked])
        #expect(!made.isError, "\(made.text)")
        let id = try #require(made.result["draft_id"] as? String)

        let message = try await raw(id)
        let html = try part("text/html", of: message)
        #expect(html.contains(#"class="gmail_quote""#))
        #expect(html.contains("<blockquote") && html.contains("Please send the statements."))
        #expect(try part("text/plain", of: message).contains("> Please send the statements."))
    }

    @Test func changingOtherFieldsKeepsTheFormattingAndPlainTextDropsIt() async throws {
        let id = try #require(try tool("draft_reply", ["account": Self.account, "thread_id": "T", "html": Self.linked]).result["draft_id"] as? String)

        _ = try tool("update_draft", ["account": Self.account, "draft_id": id, "subject": "Re: Tax documents (v2)"])
        var html = try part("text/html", of: try await raw(id))
        #expect(html.contains(#"<a href="https://example.com/jane">Jane Doe</a>"#), "still formatted")
        #expect(html.components(separatedBy: "gmail_quote\"").count == 3, "one quote, not a quote of a quote: \(html)")

        _ = try tool("update_draft", ["account": Self.account, "draft_id": id, "html": #"<p>Now <a href="https://example.com/b">Bea</a></p>"#])
        html = try part("text/html", of: try await raw(id))
        #expect(html.contains("Bea") && !html.contains("Jane Doe"))
        #expect(html.contains("Please send the statements."), "the reply keeps its quote")

        _ = try tool("update_draft", ["account": Self.account, "draft_id": id, "body": "Plain again."])
        let message = try await raw(id)
        #expect(!message.contains("text/html"))
        #expect(try tool("get_draft", ["account": Self.account, "draft_id": id]).result["html"] == nil)
    }

    @Test func htmlNookCouldNotEditIsRefused() throws {
        let made = try tool("compose_draft", ["to": "a@b.example", "html": "<table><tr><td>x</td></tr></table>"])
        #expect(made.isError)
        #expect(made.text.contains("can use only these tags"))
        #expect(try tool("draft_reply", ["account": Self.account, "thread_id": "T"]).isError, "a reply needs body or html")
    }
}

@Suite("Rich text")
struct RichTextTests {
    @Test func plainTextKeepsLinksListsAndParagraphs() {
        let text = RichText.plainText(fromHTML: #"<div>Hi,</div><div><br></div><p>See <a href="https://x.example/a">the doc</a> and <a href="https://x.example">https://x.example</a>.</p><ol><li>One</li><li><b>Two</b></li></ol><p>Thanks</p>"#)
        #expect(text == "Hi,\n\nSee the doc (https://x.example/a) and https://x.example.\n\n• One\n• Two\n\nThanks")
    }

    @Test func aGmailDraftSplitsIntoYourTextAndTheQuote() {
        let html = #"<div dir="ltr">Thanks <b>both</b></div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, A wrote:<br></div><blockquote class="gmail_quote">Hello</blockquote></div>"#
        let (mine, quote) = RichText.splitQuote(html)
        #expect(mine == "Thanks <b>both</b>")
        #expect(quote?.hasPrefix(#"<div class="gmail_quote">"#) == true)
        #expect(RichText.isEditable(mine))
        #expect(!RichText.isEditable(#"Hi<img src="cid:logo">"#))
    }
}
