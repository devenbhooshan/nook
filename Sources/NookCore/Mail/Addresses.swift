import Foundation

public struct EmailAddress: Equatable, Hashable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// `Jane Doe <jane@example.com>`, or just the address when there's no name.
    public var formatted: String {
        guard !name.isEmpty, name != email else { return email }
        let needsQuotes = name.contains { ",;<>\"@".contains($0) }
        return needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: ""))\" <\(email)>" : "\(name) <\(email)>"
    }
}

public enum Addresses {
    /// Parses a single address such as `"Doe, Jane" <jane@example.com>` or `jane@example.com`.
    public static func parse(_ raw: String) -> EmailAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let email = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = trimmed[..<open]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: name.isEmpty ? email : name, email: email)
        }
        return EmailAddress(name: trimmed, email: trimmed)
    }

    /// Splits an address list on commas and semicolons, ignoring separators inside quotes or angle brackets.
    public static func parseList(_ raw: String) -> [EmailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in raw {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "<": inAngle = true; current.append(character)
            case ">": inAngle = false; current.append(character)
            case "," where !inQuotes && !inAngle, ";" where !inQuotes && !inAngle:
                parts.append(current)
                current = ""
            default: current.append(character)
            }
        }
        parts.append(current)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(parse)
    }

    /// Splits an address field into what's already entered and the address being typed after the last separator.
    /// `"Jane <j@x.com>, bo"` gives `("Jane <j@x.com>, ", "bo")`.
    public static func splitTyping(_ raw: String) -> (entered: String, typing: String) {
        var inQuotes = false
        var inAngle = false
        var cut = raw.startIndex
        for index in raw.indices {
            switch raw[index] {
            case "\"": inQuotes.toggle()
            case "<": inAngle = true
            case ">": inAngle = false
            case ",", ";": if !inQuotes && !inAngle { cut = raw.index(after: index) }
            default: break
            }
        }
        let typing = raw[cut...]
        let leading = typing.prefix { $0.isWhitespace }
        return (String(raw[..<cut]) + leading, String(typing.dropFirst(leading.count)))
    }

    /// Replaces the address being typed with a chosen one, ready for the next.
    public static func complete(_ raw: String, with address: EmailAddress) -> String {
        var entered = splitTyping(raw).entered
        if !entered.isEmpty, !entered.hasSuffix(" ") { entered += " " }
        return entered + address.formatted + ", "
    }

    /// A display name for a sender: their name, or the part of the address before the `@`.
    public static func displayName(name: String, email: String) -> String {
        if !name.isEmpty, name != email { return name }
        return email.split(separator: "@").first.map(String.init) ?? email
    }

    /// Up to two initials for an avatar: the first and last words, skipping joiners like "at" and "from".
    /// "Priya K Natarajan" gives PN, "Deven at WarmDogo" gives DW.
    public static func initials(name: String, email: String) -> String {
        let joiners: Set<String> = ["at", "from", "via", "of", "the", "and", "&", "by", "for", "on", "team"]
        let words = displayName(name: name, email: email)
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
            .filter { $0.first?.isLetter == true && !joiners.contains($0.lowercased()) }
        let chosen = words.count > 1 ? [words[0], words[words.count - 1]] : words
        let letters = chosen.compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
