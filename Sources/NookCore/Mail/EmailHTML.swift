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
            <body><div class="nook-plain">\(linkify(escape(message.bodyText)))</div></body></html>
            """
        }
        // The CSP meta tag goes first so the parser places it in <head> before any remote reference.
        return head + "<style>\(htmlStyle)</style>" + message.bodyHTML
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
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
    img { max-width: 100%; height: auto; }
    table { max-width: 100% !important; }
    """
}
