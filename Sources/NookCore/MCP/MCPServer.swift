import Foundation

/// A Model Context Protocol server over Nook's local mail store (https://modelcontextprotocol.io).
///
/// It speaks JSON-RPC 2.0, one message per line, over stdio, so only processes on this Mac that
/// launch `nook-mcp` can reach it. It never opens a network port and never talks to Gmail.
/// Tools can read and search mail. They can't send anything: drafting tools only open a draft
/// in Nook, where a person decides whether to send it.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let maxBodyCharacters = 20_000

    private let repo: MailRepository
    private let isEnabled: () -> Bool
    private let openURL: (URL) -> Void
    private let version: String

    /// - Parameters:
    ///   - isEnabled: Checked on every tool call, so turning access off in Nook takes effect right away.
    ///   - openURL: Opens `nook://` links, which hand drafts to the app.
    public init(repo: MailRepository, version: String = "0.1.0", isEnabled: @escaping () -> Bool, openURL: @escaping (URL) -> Void) {
        self.repo = repo
        self.version = version
        self.isEnabled = isEnabled
        self.openURL = openURL
    }

    /// Reads requests from `input` until it closes, writing responses to `output`.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line: line) else { continue }
            output.write(Data((response + "\n").utf8))
        }
    }

    /// Handles one JSON-RPC message. Returns the response line, or `nil` for notifications.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get a response.
        guard let id else { return nil }

        do {
            let result = try respond(to: method, params: params)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]])
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
        static func invalidParams(_ message: String) -> RPCError { RPCError(code: -32602, message: message) }
    }

    private func respond(to method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nook", "title": "Nook Mail", "version": version],
                "instructions": """
                Read-only access to the user's email, stored locally by the Nook mail app. Use search_threads to find \
                conversations (it accepts operators like from:, tag:, is:unread, in:sent), then get_thread to read one. \
                You can't send email. To help the user write, use draft_reply or compose_draft, which open a draft in \
                Nook for the user to review and send.
                """,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return callTool(name, arguments)
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        guard isEnabled() else {
            return toolError("Nook's MCP access is turned off. The user can turn it on in Nook → Settings → Integrations.")
        }
        do {
            switch name {
            case "list_accounts": return toolResult(listAccounts())
            case "list_tags": return toolResult(listTags(arguments))
            case "search_threads": return toolResult(try searchThreads(arguments))
            case "get_thread": return toolResult(try getThread(arguments))
            case "draft_reply": return toolResult(try draftReply(arguments))
            case "compose_draft": return toolResult(try composeDraft(arguments))
            default: return toolError("Unknown tool: \(name)")
            }
        } catch let error as RPCError {
            return toolError(error.message)
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func listAccounts() -> [String: Any] {
        let unread = repo.unreadInboxCounts()
        return ["accounts": repo.accounts().map { account -> [String: Any] in
            [
                "email": account.email,
                "name": account.name,
                "unread_inbox_threads": unread[account.email] ?? 0,
                "last_synced": account.lastSync.map(Self.iso8601) ?? NSNull(),
            ]
        }]
    }

    private func listTags(_ arguments: [String: Any]) -> [String: Any] {
        let counts = repo.splitCounts(account: arguments["account"] as? String)
        return ["tags": repo.tags().map { tag -> [String: Any] in
            [
                "name": tag.name,
                "description": tag.description,
                "is_inbox_tab": tag.isSplit,
                "inbox_threads": counts.tags[tag.name] ?? 0,
            ]
        }]
    }

    private func searchThreads(_ arguments: [String: Any]) throws -> [String: Any] {
        let mailboxName = (arguments["mailbox"] as? String)?.lowercased() ?? "inbox"
        guard let mailbox = Mailbox(rawValue: mailboxName) else {
            throw RPCError.invalidParams("mailbox must be one of: \(Mailbox.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 100)
        let split: InboxSplit = (arguments["tag"] as? String).map { .tag($0) } ?? .everything
        let query = ThreadQuery(
            account: arguments["account"] as? String,
            mailbox: mailbox,
            split: split,
            search: (arguments["query"] as? String).flatMap(SearchQuery.parse),
            limit: limit
        )
        let threads = repo.threads(query)
        return [
            "count": threads.count,
            "threads": threads.map { thread -> [String: Any] in
                [
                    "account": thread.account,
                    "thread_id": thread.threadId,
                    "from": EmailAddress(name: thread.fromName, email: thread.fromEmail).formatted,
                    "subject": thread.subject,
                    "snippet": thread.snippet,
                    "date": Self.iso8601(thread.date),
                    "messages": thread.messageCount,
                    "unread": thread.isUnread,
                    "starred": thread.isStarred,
                    "tags": thread.tags,
                ]
            },
        ]
    }

    private func getThread(_ arguments: [String: Any]) throws -> [String: Any] {
        let (account, threadId) = try threadArguments(arguments)
        let messages = repo.threadMessages(account: account, threadId: threadId)
        guard !messages.isEmpty else { throw RPCError.invalidParams("No thread \(threadId) in \(account).") }
        return [
            "account": account,
            "thread_id": threadId,
            "subject": messages.last?.subject ?? "",
            "messages": messages.map { message -> [String: Any] in
                let body = message.bodyText
                return [
                    "from": EmailAddress(name: message.fromName, email: message.fromEmail).formatted,
                    "to": message.to,
                    "cc": message.cc,
                    "date": Self.iso8601(message.date),
                    "subject": message.subject,
                    "body": body.count > Self.maxBodyCharacters ? String(body.prefix(Self.maxBodyCharacters)) + "\n[truncated]" : body,
                    "unread": message.isUnread,
                    "tags": repo.tags(account: account, messageId: message.id),
                ]
            },
        ]
    }

    private func draftReply(_ arguments: [String: Any]) throws -> [String: Any] {
        let (account, threadId) = try threadArguments(arguments)
        guard !repo.threadMessages(account: account, threadId: threadId).isEmpty else {
            throw RPCError.invalidParams("No thread \(threadId) in \(account).")
        }
        let body = arguments["body"] as? String ?? ""
        openURL(NookURL.reply(account: account, threadId: threadId, body: body, all: arguments["reply_all"] as? Bool ?? false).url)
        return ["status": "A reply draft is open in Nook for the user to review. It has not been sent."]
    }

    private func composeDraft(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let to = arguments["to"] as? String, !to.isEmpty else { throw RPCError.invalidParams("`to` is required.") }
        if let from = arguments["from"] as? String, !repo.accounts().contains(where: { $0.email == from }) {
            throw RPCError.invalidParams("\(from) isn't an account in Nook.")
        }
        openURL(NookURL.compose(
            from: arguments["from"] as? String, to: to, cc: arguments["cc"] as? String ?? "",
            subject: arguments["subject"] as? String ?? "", body: arguments["body"] as? String ?? ""
        ).url)
        return ["status": "A new draft is open in Nook for the user to review. It has not been sent."]
    }

    private func threadArguments(_ arguments: [String: Any]) throws -> (String, String) {
        guard let account = arguments["account"] as? String, let threadId = arguments["thread_id"] as? String else {
            throw RPCError.invalidParams("`account` and `thread_id` are required. Get them from search_threads.")
        }
        return (account, threadId)
    }

    // MARK: Encoding

    private func toolResult(_ value: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": encode(value, pretty: true)]], "structuredContent": value, "isError": false]
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func encode(_ value: [String: Any], pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: options)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: Tool definitions

    static let tools: [[String: Any]] = [
        [
            "name": "list_accounts",
            "title": "List accounts",
            "description": "The email accounts connected to Nook, with unread inbox counts.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_tags",
            "title": "List tags",
            "description": "The user's tags, what each means, and how many inbox conversations carry it. Tags are applied by an on-device model.",
            "inputSchema": [
                "type": "object",
                "properties": ["account": ["type": "string", "description": "Only count this account's mail."]],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "search_threads",
            "title": "Search conversations",
            "description": """
            Find email conversations. Newest first. `query` supports free text plus operators: from:, to:, tag:, \
            is:unread, is:read, is:starred, in:inbox|starred|sent|all|trash, account:, and "quoted phrases". \
            With a query, all mail is searched unless the query says in:.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search text and operators, e.g. `from:anna is:unread invoice`."],
                    "mailbox": ["type": "string", "enum": Mailbox.allCases.map(\.rawValue), "description": "Mailbox to list when there's no query. Defaults to inbox."],
                    "tag": ["type": "string", "description": "Only conversations with this tag."],
                    "account": ["type": "string", "description": "Only this account (email address)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Defaults to 20."],
                ],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_thread",
            "title": "Read a conversation",
            "description": "Every message in a conversation, oldest first, as plain text.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "account": ["type": "string", "description": "From search_threads."],
                    "thread_id": ["type": "string", "description": "From search_threads."],
                ],
                "required": ["account", "thread_id"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "draft_reply",
            "title": "Draft a reply",
            "description": "Opens a reply in Nook with the given text, quoted original included, for the user to review and send. Never sends.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "account": ["type": "string"],
                    "thread_id": ["type": "string"],
                    "body": ["type": "string", "description": "The reply text, plain text."],
                    "reply_all": ["type": "boolean", "description": "Copy everyone on the thread. Defaults to false."],
                ],
                "required": ["account", "thread_id", "body"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "compose_draft",
            "title": "Draft a new email",
            "description": "Opens a new message in Nook for the user to review and send. Never sends.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Comma-separated recipients."],
                    "cc": ["type": "string"],
                    "subject": ["type": "string"],
                    "body": ["type": "string", "description": "Plain text."],
                    "from": ["type": "string", "description": "Which account to send from. Defaults to the first."],
                ],
                "required": ["to"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
        ],
    ]
}

/// Where Nook keeps the MCP switch. The app writes it; `nook-mcp` reads it.
public enum MCPSettings {
    public static let enabledKey = "mcp.enabled"
    public static let appDefaultsDomain = "com.devenbhooshan.nook"

    /// In debug builds, `NOOK_MCP_ENABLED=1` overrides the app setting, for development. Release builds ignore it:
    /// otherwise anything that launches nook-mcp could set it and read mail with access turned off.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        #if DEBUG
        if let override = environment["NOOK_MCP_ENABLED"] { return override == "1" || override.lowercased() == "true" }
        #endif
        return appDefaults(bundleIdentifier: bundleIdentifier)?.bool(forKey: enabledKey) ?? false
    }

    /// The app's settings. Inside Nook.app, `nook-mcp` shares the app's bundle identifier, and macOS refuses a
    /// suite named after your own bundle, so there the standard defaults are the app's. Elsewhere, such as
    /// `swift run`, read the app's domain by name.
    static func appDefaults(bundleIdentifier: String?) -> UserDefaults? {
        bundleIdentifier == appDefaultsDomain ? .standard : UserDefaults(suiteName: appDefaultsDomain)
    }
}
