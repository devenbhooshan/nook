import Foundation

/// Senders whose remote images load without asking: whole addresses ("sam@acme.com") or domains ("acme.com",
/// which covers its subdomains too, like "mail.acme.com").
public enum ImageSenders {
    /// The preference they're kept in.
    public static let storageKey = "privacy.imageSenders"

    /// The form an entry is kept in, or nil when it isn't an address or a domain.
    /// Accepts "@acme.com" and "*.acme.com" for a domain, and "Sam <sam@acme.com>" for an address.
    public static func normalize(_ entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        for prefix in ["*.", "@", "."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let domain = parts.last, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              !text.contains(where: { $0.isWhitespace }), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return text
    }

    public static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        return domain.isEmpty ? nil : domain
    }

    public static func matches(_ email: String, in entries: [String]) -> Bool {
        match(email, in: entries) != nil
    }

    /// The entry that lets this sender's images load.
    public static func match(_ email: String, in entries: [String]) -> String? {
        let email = email.lowercased()
        guard let domain = domain(of: email) else { return nil }
        return entries.first { entry in
            entry.contains("@") ? entry == email : domain == entry || domain.hasSuffix("." + entry)
        }
    }

    /// Entries are kept one per line in a single preference.
    public static func parse(_ stored: String) -> [String] {
        stored.split(whereSeparator: \.isNewline).map(String.init)
    }

    public static func adding(_ entry: String, to stored: String) -> String {
        guard let entry = normalize(entry) else { return stored }
        var entries = parse(stored)
        if !entries.contains(entry) { entries.append(entry) }
        return entries.sorted().joined(separator: "\n")
    }

    public static func removing(_ entry: String, from stored: String) -> String {
        parse(stored).filter { $0 != entry }.joined(separator: "\n")
    }
}
