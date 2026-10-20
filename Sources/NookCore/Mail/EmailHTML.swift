import Foundation

/// Prepares message bodies for display in a web view.
///
/// Privacy rules:
/// - A Content-Security-Policy blocks every network request unless the user allows remote content,
///   so tracking pixels and remote fonts can't report that a message was opened.
/// - The web view runs with JavaScript disabled. See `EmailWebView` in the app.
public enum EmailHTML {
    public static func document(for message: MailMessage, allowRemoteContent: Bool) -> String {
        let csp = allowRemoteContent
            ? "default-src 'none'; img-src * data: cid:; style-src 'unsafe-inline' *; font-src * data:; media-src *"
            : "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:"
        let head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        """

        if message.bodyHTML.isEmpty {
            return """
            <!doctype html><html><head>\(head)<style>\(plainTextStyle)</style></head>
            <body><div class="nook-plain">\(plainBody(message.bodyText))</div></body></html>
            """
        }
        // The CSP meta tag goes first so the parser places it in <head> before any remote reference.
        return head + "<style>\(htmlStyle)</style>" + message.bodyHTML
    }

    /// Plain text as HTML, with a trailing quote ("On … wrote:" and the "> " lines after it) marked so the reader
    /// can fold it away.
    static func plainBody(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        var start = lines.count
        while start > 0 {
            let line = lines[start - 1].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(">") || line.isEmpty else { break }
            start -= 1
        }
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        guard start < lines.count else { return linkify(escape(text)) }
        // Take the "On … wrote:" line (sometimes wrapped onto two) along with the quote.
        if start > 0, lines[start - 1].hasSuffix("wrote:") {
            start -= 1
            if start > 0, lines[start - 1].hasPrefix("On "), !lines[start].hasPrefix("On ") { start -= 1 }
        }
        let own = lines[..<start].joined(separator: "\n")
        let quote = lines[start...].joined(separator: "\n")
        guard !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return linkify(escape(text)) }
        return linkify(escape(own)) + "<div class=\"nook-quote\">" + linkify(escape(quote)) + "</div>"
    }

    /// Whether the HTML would load anything from the network.
    public static func containsRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(?i)(src|background)\s*=\s*["']?\s*(https?:)?//"#, options: .regularExpression) != nil
            || html.range(of: #"(?i)url\(\s*["']?\s*(https?:)?//"#, options: .regularExpression) != nil
            || html.range(of: #"(?i)<link[^>]+href\s*=\s*["']?\s*(https?:)?//"#, options: .regularExpression) != nil
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Wraps bare URLs in already-escaped text in anchors.
    static func linkify(_ escaped: String) -> String {
        escaped.replacingOccurrences(
            of: #"(https?://[^\s<>"]+[^\s<>".,;:!?)\]])"#,
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression
        )
    }

    private static let plainTextStyle = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: transparent; }
    body { font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; color: CanvasText; overflow-wrap: anywhere; }
    .nook-plain { white-space: pre-wrap; }
    a { color: LinkText; }
    """

    private static let htmlStyle = """
    html, body { margin: 0; padding: 0; }
    /* The view is as tall as the message, so a page as tall as the view would grow forever. Specific enough to beat
       the "html, body { height: 100% !important }" that marketing templates use. */
    html:root, html:root > body { height: auto !important; min-height: 0 !important; }
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
    img { max-width: 100%; height: auto; }
    table { max-width: 100% !important; }
    """
}
