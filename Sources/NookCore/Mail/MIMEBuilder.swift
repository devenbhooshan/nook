import Foundation

/// Builds RFC 5322 messages for Gmail's `messages.send`.
public enum MIMEBuilder {
    /// The complete message as text.
    ///
    /// Attachments must already hold their bytes (`.data`); ones still in Gmail are fetched before building.
    public static func rfc822(_ draft: Draft, fromName: String, date: Date = Date(), boundary: String = "nook-\(UUID().uuidString)") -> String {
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

        headers.append("MIME-Version: 1.0")
        let textHeaders = ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"]
        let text = base64Lines(Data(draft.fullBody.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8))

        let files = draft.attachments.compactMap { attachment in attachment.data.map { (attachment, $0) } }
        guard !files.isEmpty else {
            return (headers + textHeaders).joined(separator: "\r\n") + "\r\n\r\n" + text
        }

        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var parts = [textHeaders.joined(separator: "\r\n") + "\r\n\r\n" + text]
        for (attachment, data) in files {
            let name = singleLine(attachment.filename).replacingOccurrences(of: "\"", with: "'")
            let type = singleLine(attachment.mimeType).filter { !$0.isWhitespace && $0 != ";" }
            parts.append([
                "Content-Type: \(type.isEmpty ? "application/octet-stream" : type); name=\"\(encodeHeader(name))\"",
                "Content-Disposition: attachment; \(filenameParameter(name))",
                "Content-Transfer-Encoding: base64",
            ].joined(separator: "\r\n") + "\r\n\r\n" + base64Lines(data))
        }
        let body = parts.map { "--\(boundary)\r\n\($0)\r\n" }.joined() + "--\(boundary)--\r\n"
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// `filename="..."`, or the RFC 2231 form for names that aren't plain ASCII.
    static func filenameParameter(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { !$0.isASCII }) else { return "filename=\"\(name)\"" }
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return "filename*=UTF-8''\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)"
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
