import Foundation

/// A parsed search string. Supports free text plus Gmail-style operators:
///
///     from:anna  to:me  tag:receipt  is:unread  is:starred  in:sent  account:work  "exact phrase"
public struct SearchQuery: Equatable, Sendable {
    public var terms: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var tags: [String] = []
    public var accounts: [String] = []
    public var isUnread: Bool?
    public var isStarred: Bool?
    public var mailbox: Mailbox?

    public init() {}

    public var isEmpty: Bool { self == SearchQuery() }

    /// Returns `nil` for blank input.
    public static func parse(_ input: String) -> SearchQuery? {
        var query = SearchQuery()
        for token in tokenize(input) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                query.terms.append(token)
                continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            guard !value.isEmpty else {
                query.terms.append(token)
                continue
            }

            switch key {
            case "from": query.from.append(value)
            case "to": query.to.append(value)
            case "tag", "label": query.tags.append(value)
            case "account": query.accounts.append(value)
            case "is":
                switch value.lowercased() {
                case "unread": query.isUnread = true
                case "read": query.isUnread = false
                case "starred": query.isStarred = true
                default: query.terms.append(token)
                }
            case "in":
                if let mailbox = Mailbox.allCases.first(where: { $0.rawValue == value.lowercased() || $0.title.lowercased() == value.lowercased() }) {
                    query.mailbox = mailbox
                } else if value.lowercased() == "anywhere" {
                    query.mailbox = .all
                } else {
                    query.terms.append(token)
                }
            default:
                query.terms.append(token)
            }
        }
        return query.isEmpty ? nil : query
    }

    /// Splits on whitespace while keeping `"quoted phrases"` (and `from:"Jane Doe"`) together.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in input {
            if character == "\"" {
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The free-text terms as an FTS5 `MATCH` expression: every term must match, as a prefix.
    public var ftsExpression: String? {
        let parts = terms.compactMap { term -> String? in
            let cleaned = term.replacingOccurrences(of: "\"", with: "")
            guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return "\"\(cleaned)\"*"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
