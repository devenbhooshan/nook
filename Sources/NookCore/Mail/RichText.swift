import Foundation

/// Formatted draft bodies: links, bold, italics and bullet lists, sent as HTML with a plain-text twin.
///
/// A rich draft keeps what you write (`Draft.bodyHTML`) apart from the message it replies to (`Draft.quotedHTML`),
/// the way Gmail does: the quote is a `gmail_quote` block after your text, carried along untouched.
public enum RichText {
    /// Tags Nook can show and edit without losing anything that matters. HTML with anything else (tables, images,
    /// fonts from a signature) opens as plain text, as before.
    static let editableTags: Set<String> = ["a", "b", "strong", "i", "em", "u", "br", "p", "div", "span", "ul", "ol", "li"]

    /// The plain-text version, for the text/plain part, search and get_draft. Links keep their address.
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in ["(?is)<(style|script|head)[^>]*>.*?</\\1>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        text = linksAsText(text)
        text = text.replacingOccurrences(of: "(?i)<li[^>]*>", with: "\n• ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(ul|ol)>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(div|blockquote|h[1-6])>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = MIMEParser.decodeEntities(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<a href="https://x">Jane</a>` → `Jane (https://x)`; a link whose text is its address stays as it is.
    private static func linksAsText(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#) else { return html }
        var result = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let whole = Range(match.range, in: html), let hrefRange = Range(match.range(at: 1), in: html),
                  let innerRange = Range(match.range(at: 2), in: html) else { continue }
            let href = MIMEParser.decodeEntities(String(html[hrefRange])).trimmingCharacters(in: .whitespaces)
            let inner = String(html[innerRange])
            let label = MIMEParser.decodeEntities(inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespaces)
            let address = href.hasPrefix("mailto:") ? String(href.dropFirst(7)) : href
            let same = address.isEmpty || label == address || label == href
            result.replaceSubrange(whole, with: same ? inner : "\(inner) (\(EmailHTML.escape(address)))")
        }
        return result
    }

    /// Whether Nook's editor can hold this HTML without dropping part of it.
    public static func isEditable(_ html: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"<\s*/?\s*([a-zA-Z][a-zA-Z0-9]*)"#) else { return false }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { return false }
            if !editableTags.contains(html[range].lowercased()) { return false }
        }
        return true
    }

    /// Splits a draft's HTML into what you wrote and the quoted message below it, if any.
    public static func splitQuote(_ html: String) -> (body: String, quote: String?) {
        var body = html
        // Only the draft's own body: the document's <html>/<body> wrapper isn't part of what you wrote.
        if let inner = body.range(of: #"(?is)<body[^>]*>(.*)</body>"#, options: .regularExpression) {
            body = String(body[inner]).replacingOccurrences(of: #"(?is)^<body[^>]*>|</body>$"#, with: "", options: .regularExpression)
        }
        guard let start = body.range(of: #"(?i)<div[^>]*class\s*=\s*["'][^"']*gmail_quote"#, options: .regularExpression) else {
            return (unwrap(body), nil)
        }
        var mine = String(body[..<start.lowerBound])
        mine = mine.replacingOccurrences(of: #"(?i)(<br\s*/?>\s*)+$"#, with: "", options: .regularExpression)
        return (unwrap(mine), String(body[start.lowerBound...]))
    }

    /// Drops the `<div dir="ltr">` that `document` (and Gmail) wrap a body in, so it doesn't nest on every save.
    private static func unwrap(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"(?is)^<div dir="ltr">.*</div>$"#, options: .regularExpression) != nil else { return trimmed }
        let inner = trimmed.replacingOccurrences(of: #"(?is)^<div dir="ltr">"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)</div>$"#, with: "", options: .regularExpression)
        // Only when that outer div is the one wrapping everything, not the first of several.
        let opens = inner.components(separatedBy: "<div").count, closes = inner.components(separatedBy: "</div>").count
        return opens == closes ? inner : trimmed
    }

    /// The HTML for a quote Nook wrote as text (`On …, X wrote:` then `> ` lines), the way Gmail shows one.
    public static func quoteHTML(fromPlain quoted: String) -> String {
        var attribution: [String] = []
        var lines: [String] = []
        for line in quoted.components(separatedBy: "\n") {
            if lines.isEmpty, !line.hasPrefix(">") {
                attribution.append(line)
            } else {
                lines.append(line.hasPrefix("> ") ? String(line.dropFirst(2)) : line.hasPrefix(">") ? String(line.dropFirst()) : line)
            }
        }
        let attr = attribution.map(EmailHTML.escape).joined(separator: "<br>")
        guard !lines.isEmpty else { return "<div class=\"gmail_quote\">\(attr)</div>" }
        let quotedLines = lines.map(EmailHTML.escape).joined(separator: "<br>")
        return "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(attr)</div>"
            + "<blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex\">\(quotedLines)</blockquote></div>"
    }

    /// A saved draft opened for editing keeps its formatting, when Nook can hold all of it: your part becomes
    /// `bodyHTML` and the quote below it is carried as it is. Otherwise the draft stays plain text.
    public static func keepFormatting(of message: MailMessage, in draft: inout Draft) {
        guard !message.bodyHTML.isEmpty else { return }
        let (mine, quote) = splitQuote(message.bodyHTML)
        guard isEditable(mine) else { return }
        draft.setHTML(mine)
        draft.quotedHTML = quote
        draft.quoted = quote.map(plainText(fromHTML:)) ?? ""
    }

    /// The whole HTML part: what you wrote, then the quote.
    public static func document(body: String, quote: String?) -> String {
        "<div dir=\"ltr\">\(body)</div>" + (quote.map { "<br>\($0)" } ?? "")
    }
}
