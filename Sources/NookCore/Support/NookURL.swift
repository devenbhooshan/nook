import Foundation

/// `nook://` links, used by the MCP server (and anything else on the Mac) to open drafts in Nook.
/// Links only ever *open* a draft for a person to review. Nothing is sent without them.
public enum NookURL: Equatable, Sendable {
    /// `nook://compose?from=&to=&cc=&subject=&body=`
    case compose(from: String?, to: String, cc: String, subject: String, body: String)
    /// `nook://reply?account=&thread=&body=&all=1`
    case reply(account: String, threadId: String, body: String, all: Bool)
    /// `nook://open?account=&thread=`
    case open(account: String, threadId: String)
    /// `nook://draft?account=&message=&draft=`: a saved Gmail draft, by the message it holds now. The draft id stays
    /// the same when the draft is updated (the message id doesn't), so it tells Nook which open draft changed.
    case draft(account: String, messageId: String, draftId: String? = nil)
    /// `nook://event?account=&title=&start=&end=&tz=&attendees=&meet=1&notes=`: an invite to review and send.
    /// Times are ISO 8601 with their offset.
    case event(EventInvite)

    public static let scheme = "nook"

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        switch url.host()?.lowercased() {
        case "compose":
            self = .compose(
                from: query["from"].flatMap { $0.isEmpty ? nil : $0 },
                to: query["to"] ?? "", cc: query["cc"] ?? "",
                subject: query["subject"] ?? "", body: query["body"] ?? ""
            )
        case "reply":
            guard let account = query["account"], let thread = query["thread"], !account.isEmpty, !thread.isEmpty else { return nil }
            self = .reply(account: account, threadId: thread, body: query["body"] ?? "", all: query["all"] == "1")
        case "open":
            guard let account = query["account"], let thread = query["thread"], !account.isEmpty, !thread.isEmpty else { return nil }
            self = .open(account: account, threadId: thread)
        case "draft":
            guard let account = query["account"], let message = query["message"], !account.isEmpty, !message.isEmpty else { return nil }
            self = .draft(account: account, messageId: message, draftId: query["draft"].flatMap { $0.isEmpty ? nil : $0 })
        case "event":
            let zone = TimeZone(identifier: query["tz"] ?? "") ?? .current
            guard let account = query["account"], !account.isEmpty,
                  let start = query["start"].flatMap({ EventInvite.date($0, in: zone) }),
                  let end = query["end"].flatMap({ EventInvite.date($0, in: zone) }) else { return nil }
            self = .event(EventInvite(
                account: account, title: query["title"] ?? "", start: start, end: end, timeZone: zone.identifier,
                attendees: query["attendees"] ?? "", addMeet: query["meet"] == "1", notes: query["notes"] ?? ""
            ))
        default:
            return nil
        }
    }

    public static func == (lhs: NookURL, rhs: NookURL) -> Bool {
        switch (lhs, rhs) {
        case let (.event(a), .event(b)):
            // An invite's id is only for showing it; two links for the same invite are equal.
            var b = b
            b.id = a.id
            return a == b
        case let (.compose(a1, a2, a3, a4, a5), .compose(b1, b2, b3, b4, b5)): return (a1, a2, a3, a4, a5) == (b1, b2, b3, b4, b5)
        case let (.reply(a1, a2, a3, a4), .reply(b1, b2, b3, b4)): return (a1, a2, a3, a4) == (b1, b2, b3, b4)
        case let (.open(a1, a2), .open(b1, b2)): return (a1, a2) == (b1, b2)
        case let (.draft(a1, a2, a3), .draft(b1, b2, b3)): return (a1, a2, a3) == (b1, b2, b3)
        default: return false
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        var items: [URLQueryItem] = []
        switch self {
        case let .compose(from, to, cc, subject, body):
            components.host = "compose"
            if let from { items.append(URLQueryItem(name: "from", value: from)) }
            items += [
                URLQueryItem(name: "to", value: to), URLQueryItem(name: "cc", value: cc),
                URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body),
            ]
        case let .reply(account, threadId, body, all):
            components.host = "reply"
            items = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "thread", value: threadId), URLQueryItem(name: "body", value: body)]
            if all { items.append(URLQueryItem(name: "all", value: "1")) }
        case let .open(account, threadId):
            components.host = "open"
            items = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "thread", value: threadId)]
        case let .draft(account, messageId, draftId):
            components.host = "draft"
            items = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "message", value: messageId)]
            if let draftId { items.append(URLQueryItem(name: "draft", value: draftId)) }
        case let .event(invite):
            components.host = "event"
            let zone = TimeZone(identifier: invite.timeZone) ?? .current
            items = [
                URLQueryItem(name: "account", value: invite.account), URLQueryItem(name: "title", value: invite.title),
                URLQueryItem(name: "start", value: EventInvite.string(invite.start, in: zone)),
                URLQueryItem(name: "end", value: EventInvite.string(invite.end, in: zone)),
                URLQueryItem(name: "tz", value: zone.identifier), URLQueryItem(name: "attendees", value: invite.attendees),
                URLQueryItem(name: "meet", value: invite.addMeet ? "1" : "0"), URLQueryItem(name: "notes", value: invite.notes),
            ]
        }
        components.queryItems = items
        // URLComponents leaves "+" alone, which some parsers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
