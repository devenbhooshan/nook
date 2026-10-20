import Foundation

/// Builds reply and forward drafts from a thread.
public enum ReplyComposer {
    public enum Kind: Sendable { case reply, replyAll, forward }

    public static func draft(_ kind: Kind, to message: MailMessage, account: String) -> Draft {
        let me = account.lowercased()
        switch kind {
        case .reply, .replyAll:
            let recipients = replyRecipients(for: message, me: me, all: kind == .replyAll)
            var draft = Draft(
                from: account,
                to: recipients.to.map(\.formatted).joined(separator: ", "),
                cc: recipients.cc.map(\.formatted).joined(separator: ", "),
                subject: prefixed(message.subject, with: "Re:"),
                threadId: message.threadId,
                inReplyTo: message.messageIdHeader.isEmpty ? nil : message.messageIdHeader,
                references: message.references.isEmpty ? nil : message.references
            )
            draft.quoted = quoted(message)
            return draft
        case .forward:
            var draft = Draft(from: account, subject: prefixed(message.subject, with: "Fwd:"))
            draft.quoted = forwarded(message)
            return draft
        }
    }

    static func replyRecipients(for message: MailMessage, me: String, all: Bool) -> (to: [EmailAddress], cc: [EmailAddress]) {
        let sentByMe = message.fromEmail.lowercased() == me
        var to: [EmailAddress]
        if sentByMe {
            // Replying to your own message continues the conversation with its recipients.
            to = Addresses.parseList(message.to)
        } else if !message.replyTo.isEmpty {
            to = Addresses.parseList(message.replyTo)
        } else {
            to = [EmailAddress(name: message.fromName, email: message.fromEmail)]
        }

        var cc: [EmailAddress] = []
        if all {
            let others = (sentByMe ? [] : Addresses.parseList(message.to)) + Addresses.parseList(message.cc)
            cc = others
        }

        var seen = Set([me])
        to = to.filter { seen.insert($0.email.lowercased()).inserted }
        cc = cc.filter { seen.insert($0.email.lowercased()).inserted }
        return (to, cc)
    }

    /// Adds `Re:`/`Fwd:` unless the subject already starts with it.
    static func prefixed(_ subject: String, with prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) { return trimmed }
        return trimmed.isEmpty ? prefix : "\(prefix) \(trimmed)"
    }

    static func quoted(_ message: MailMessage) -> String {
        let sender = Addresses.displayName(name: message.fromName, email: message.fromEmail)
        let lines = tidy(message.bodyText).components(separatedBy: .newlines)
        return "On \(longDate(message.date)), \(sender) wrote:\n" + lines.map { "> \($0)" }.joined(separator: "\n")
    }

    static func forwarded(_ message: MailMessage) -> String {
        var lines = [
            "---------- Forwarded message ----------",
            "From: \(EmailAddress(name: message.fromName, email: message.fromEmail).formatted)",
            "Date: \(longDate(message.date))",
            "Subject: \(message.subject)",
            "To: \(message.to)",
        ]
        if !message.cc.isEmpty { lines.append("Cc: \(message.cc)") }
        return lines.joined(separator: "\n") + "\n\n" + tidy(message.bodyText)
    }

    /// Text from HTML mail is full of blank lines (every empty <div> and <br>). Keep at most one in a row.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed.isEmpty ? "" : line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
    }
}
