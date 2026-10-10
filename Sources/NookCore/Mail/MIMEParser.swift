import Foundation

/// Turns Gmail API message payloads into `MailMessage`s.
public enum MIMEParser {
    public static func message(from gmail: GmailMessage, account: String) -> MailMessage {
        let headers = gmail.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }

        var html: String?
        var text: String?
        if let payload = gmail.payload { collectBodies(payload, html: &html, text: &text) }

        let from = Addresses.parse(header("From"))
        let bodyText = text ?? html.map(plainText(fromHTML:)) ?? ""
        let date = Double(gmail.internalDate ?? "").map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

        return MailMessage(
            id: gmail.id,
            account: account,
            threadId: gmail.threadId ?? gmail.id,
            fromName: from.name,
            fromEmail: from.email,
            replyTo: header("Reply-To"),
            to: header("To"),
            cc: header("Cc"),
            subject: header("Subject"),
            snippet: decodeEntities(gmail.snippet ?? ""),
            bodyHTML: html ?? "",
            bodyText: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date,
            labels: Set(gmail.labelIds ?? []),
            messageIdHeader: header("Message-ID"),
            references: header("References")
        )
    }

    /// Walks the MIME tree and keeps the first HTML and plain-text bodies, skipping attachments.
    static func collectBodies(_ part: GmailMessagePart, html: inout String?, text: inout String?) {
        let mimeType = part.mimeType?.lowercased() ?? ""
        // Attachments, including attached emails (message/rfc822, which have parts of their own), aren't the body.
        // Checking before recursing keeps a forwarded email's text from standing in for this message's.
        if let filename = part.filename, !filename.isEmpty { return }
        if mimeType == "message/rfc822" { return }
        let disposition = part.headers?.first { $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame }?.value ?? ""
        if disposition.lowercased().hasPrefix("attachment") { return }
        if mimeType.hasPrefix("multipart/") || part.parts?.isEmpty == false {
            for child in part.parts ?? [] { collectBodies(child, html: &html, text: &text) }
            return
        }
        guard let encoded = part.body?.data, let data = decodeBase64URL(encoded) else { return }

        let contentType = part.headers?.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? ""
        let string = decode(data, charset: charset(in: contentType))

        if mimeType == "text/html", html == nil {
            html = string
        } else if mimeType == "text/plain", text == nil {
            text = string
        }
    }

    public static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    /// Reads `charset=` out of a Content-Type header.
    static func charset(in contentType: String) -> String? {
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let value = contentType[range.upperBound...]
            .prefix { $0 != ";" && !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value.lowercased()
    }

    /// Decodes body bytes in their declared charset. Gmail returns bodies in the sender's original encoding.
    static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = charset.flatMap(encoding(forCharset:)), let string = String(data: data, encoding: encoding) {
            return string
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        // Undeclared and not UTF-8: Windows-1252 maps every byte, so nothing turns into replacement characters.
        if let string = String(data: data, encoding: .windowsCP1252) { return string }
        return String(decoding: data, as: UTF8.self)
    }

    /// Any charset name macOS knows (IANA names like iso-8859-2, windows-1251, koi8-r, gb18030, big5, euc-kr).
    static func encoding(forCharset charset: String) -> String.Encoding? {
        let name = charset.lowercased() == "latin1" || charset.lowercased() == "latin-1" ? "iso-8859-1" : charset
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// A readable plain-text version of an HTML body, for search and for the tagger.
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in ["(?is)<(style|script|head)[^>]*>.*?</\\1>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</(p|div|tr|li|h[1-6])>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "zwnj": "",
    ]

    /// Decodes named (`&amp;`) and numeric (`&#39;`, `&#x27;`) HTML entities.
    public static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            guard character == "&",
                  let semicolon = string[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = string.index(after: index)
                continue
            }
            let entity = string[string.index(after: index)..<semicolon]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[entity.lowercased()]
            }
            if let replacement {
                result += replacement
                index = string.index(after: semicolon)
            } else {
                result.append(character)
                index = string.index(after: index)
            }
        }
        return result
    }
}
