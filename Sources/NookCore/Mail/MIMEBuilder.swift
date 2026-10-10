import Foundation

/// Builds RFC 5322 messages for Gmail's `messages.send`.
public enum MIMEBuilder {
    /// The complete message as text.
    public static func rfc822(_ draft: Draft, fromName: String, date: Date = Date()) -> String {
        var headers = [
            "From: \(EmailAddress(name: encodeHeader(fromName), email: draft.from).formatted)",
            "To: \(draft.to)",
        ]
        if !draft.cc.trimmingCharacters(in: .whitespaces).isEmpty { headers.append("Cc: \(draft.cc)") }
        headers.append("Subject: \(encodeHeader(draft.subject))")
        headers.append("Date: \(rfc2822Date(date))")

        if let inReplyTo = draft.inReplyTo, !inReplyTo.isEmpty {
            headers.append("In-Reply-To: \(inReplyTo)")
            let references = [draft.references ?? "", inReplyTo]
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
