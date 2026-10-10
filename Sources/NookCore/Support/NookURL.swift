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
        default:
            return nil
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
        }
        components.queryItems = items
        // URLComponents leaves "+" alone, which some parsers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
