import Foundation

/// Builds RFC 5322 messages for Gmail's `messages.send`.
public enum MIMEBuilder {
    /// The complete message as text.
    public static func rfc822(_ draft: Draft, fromName: String, date: Date = Date()) -> String {
        // Header values come from people, from incoming mail, from nook:// links and from MCP clients. A line break
        // in any of them would start a new header (a hidden Bcc, say), so every value is forced onto one line.
        let to = singleLine(draft.to)
        let cc = singleLine(draft.cc)
        var headers = [
            "From: \(EmailAddress(name: encodeHeader(singleLine(fromName)), email: singleLine(draft.from)).formatted)",
            "To: \(to)",
        ]
        if !cc.trimmingCharacters(in: .whitespaces).isEmpty { headers.append("Cc: \(cc)") }
        headers.append("Subject: \(encodeHeader(singleLine(draft.subject)))")
        headers.append("Date: \(rfc2822Date(date))")

        if let inReplyTo = draft.inReplyTo.map(singleLine), !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            let references = [draft.references.map(singleLine) ?? "", inReplyTo]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            headers.append("References: \(references)")
        }

        headers += [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
        ]

        let body = Data(draft.body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])

        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    /// The message encoded the way the Gmail API wants it: base64url without padding.
    public static func gmailRaw(_ draft: Draft, fromName: String, date: Date = Date()) -> String {
        base64URL(Data(rfc822(draft, fromName: fromName, date: date).utf8))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Replaces line breaks and other control characters with spaces, so a value can't spill into new headers.
    public static func singleLine(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : Character($0) })
    }

    /// RFC 2047 encoded-word for headers that aren't plain ASCII.
    public static func encodeHeader(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { !$0.isASCII }) else { return value }
        return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    static func rfc2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
