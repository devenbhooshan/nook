import Foundation
import Testing
@testable import NookCore

@Suite("MCP server")
struct MCPServerTests {
    let repo: MailRepository
    let opened = URLLog()
    let enabled = Flag(true)
    let server: MCPServer

    init() throws {
        repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        try repo.upsert([
            .fixture(id: "1", thread: "T", subject: "Invoice for October", body: "Please find the invoice attached.", labels: [SystemLabel.inbox, SystemLabel.unread], minutesAgo: 5),
            .fixture(id: "2", thread: "T", from: "me@example.com", fromName: "Me", subject: "Re: Invoice for October", body: "Thanks!", labels: [SystemLabel.sent]),
            .fixture(id: "3", thread: "U", from: "news@letter.com", subject: "Weekly digest", body: "Top stories", minutesAgo: 60),
        ])
        try repo.setAutoTags(["Receipt"], account: "me@example.com", messageId: "1")
        let opened = opened
        let enabled = enabled
        server = MCPServer(repo: repo, isEnabled: { enabled.value }, openURL: { opened.append($0) })
    }

    /// Sends a request and returns the decoded response.
    func call(_ method: String, _ params: [String: Any] = [:], id: Any = 1) throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        #expect(!response.contains("\n"), "Responses must be a single line")
        return try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func tool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (structured: [String: Any], text: String, isError: Bool) {
        let result = try #require(try call("tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (result["structuredContent"] as? [String: Any] ?? [:], content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    @Test func handshakeNegotiatesTheProtocolVersion() throws {
        let response = try call("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "nook")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)

        let unknown = try #require(try call("initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any])
        #expect(unknown["protocolVersion"] as? String == MCPServer.supportedProtocolVersions[0])
    }

    @Test func notificationsGetNoResponse() {
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handle(line: "   ") == nil)
    }

    @Test func reportsProtocolErrors() throws {
        let parse = try #require(server.handle(line: "{not json"))
        #expect(parse.contains("-32700"))
        let missing = try call("resources/list", id: "abc")
        #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(missing["id"] as? String == "abc")
        #expect(try call("ping")["result"] != nil)
    }

    @Test func listsToolsWithSchemas() throws {
        let result = try #require(try call("tools/list")["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["list_accounts", "list_tags", "search_threads", "get_thread", "draft_reply", "compose_draft"])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
    }

    @Test func listsAccountsAndTags() throws {
        let accounts = try tool("list_accounts").structured["accounts"] as? [[String: Any]]
        #expect(accounts?.first?["email"] as? String == "me@example.com")
        #expect(accounts?.first?["unread_inbox_threads"] as? Int == 1)

        let tags = try #require(try tool("list_tags").structured["tags"] as? [[String: Any]])
        let receipt = try #require(tags.first { $0["name"] as? String == "Receipt" })
        #expect(receipt["inbox_threads"] as? Int == 1)
        #expect(receipt["is_inbox_tab"] as? Bool == true)
    }

    @Test func searchesWithNooksQuerySyntax() throws {
        let inbox = try tool("search_threads").structured
        #expect(inbox["count"] as? Int == 2)

        let found = try tool("search_threads", ["query": "invoice is:unread"]).structured
        let threads = try #require(found["threads"] as? [[String: Any]])
        #expect(threads.map { $0["thread_id"] as? String } == ["T"])
        #expect(threads.first?["tags"] as? [String] == ["Receipt"])
        #expect(threads.first?["unread"] as? Bool == true)

        #expect(try tool("search_threads", ["tag": "Receipt"]).structured["count"] as? Int == 1)
        #expect(try tool("search_threads", ["mailbox": "sent"]).structured["count"] as? Int == 1)
        #expect(try tool("search_threads", ["limit": 1]).structured["count"] as? Int == 1)
        #expect(try tool("search_threads", ["mailbox": "spam"]).isError)
    }

    @Test func readsAWholeThread() throws {
        let thread = try tool("get_thread", ["account": "me@example.com", "thread_id": "T"]).structured
        let messages = try #require(thread["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages.first?["body"] as? String == "Please find the invoice attached.")
        #expect(messages.first?["tags"] as? [String] == ["Receipt"])
        #expect(try tool("get_thread", ["account": "me@example.com", "thread_id": "nope"]).isError)
        #expect(try tool("get_thread", [:]).isError)
    }

    @Test func draftsOpenInNookAndAreNeverSent() throws {
        let reply = try tool("draft_reply", ["account": "me@example.com", "thread_id": "T", "body": "Paid, thanks.", "reply_all": true])
        #expect(!reply.isError)
        #expect(reply.text.contains("not been sent"))
        #expect(opened.urls.compactMap(NookURL.init) == [.reply(account: "me@example.com", threadId: "T", body: "Paid, thanks.", all: true)])

        _ = try tool("compose_draft", ["to": "a@b.com", "subject": "Hi", "body": "Hello"])
        #expect(opened.urls.compactMap(NookURL.init).last == .compose(from: nil, to: "a@b.com", cc: "", subject: "Hi", body: "Hello"))

        #expect(try tool("compose_draft", ["to": "a@b.com", "from": "stranger@x.com"]).isError)
        #expect(try tool("compose_draft", [:]).isError)
        #expect(try tool("draft_reply", ["account": "me@example.com", "thread_id": "missing", "body": "x"]).isError)
        #expect(opened.urls.count == 2)
    }

    @Test func refusesToolCallsWhenTurnedOff() throws {
        enabled.value = false
        let result = try tool("search_threads")
        #expect(result.isError)
        #expect(result.text.contains("Settings → Integrations"))
        // The handshake still works, so clients can show a helpful message.
        #expect(try call("tools/list")["result"] != nil)
    }

    @Test func readsTheAppsSettingsFromInsideTheAppBundle() {
        // Regression: inside Nook.app, a suite named after our own bundle id is refused and always reads false.
        #expect(MCPSettings.appDefaults(bundleIdentifier: MCPSettings.appDefaultsDomain) === UserDefaults.standard)
        #expect(MCPSettings.appDefaults(bundleIdentifier: "com.example.other") !== UserDefaults.standard)
    }

    @Test func settingCanBeOverriddenForDevelopment() {
        #expect(MCPSettings.isEnabled(environment: ["NOOK_MCP_ENABLED": "1"]))
        #expect(!MCPSettings.isEnabled(environment: ["NOOK_MCP_ENABLED": "0"]))
    }
}

@Suite("nook:// links")
struct NookURLTests {
    @Test(arguments: [
        NookURL.compose(from: "me@x.com", to: "a@b.com, \"Doe, J\" <j@d.com>", cc: "", subject: "Q3 + Q4 & more?", body: "Line 1\nLine 2 — ✓ 100%"),
        NookURL.compose(from: nil, to: "a@b.com", cc: "c@d.com", subject: "", body: ""),
        NookURL.reply(account: "me@x.com", threadId: "18c2f", body: "Sounds good + thanks", all: false),
        NookURL.reply(account: "me@x.com", threadId: "18c2f", body: "", all: true),
        NookURL.open(account: "me@x.com", threadId: "18c2f"),
    ])
    func roundTrips(link: NookURL) {
        #expect(link.url.scheme == "nook")
        #expect(NookURL(link.url) == link)
    }

    @Test func rejectsOtherLinks() {
        #expect(NookURL(URL(string: "https://example.com/compose")!) == nil)
        #expect(NookURL(URL(string: "nook://delete?thread=1")!) == nil)
        #expect(NookURL(URL(string: "nook://reply?account=me@x.com")!) == nil)
    }
}

final class URLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func append(_ url: URL) { lock.withLock { items.append(url) } }
    var urls: [URL] { lock.withLock { items } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool
    init(_ value: Bool) { current = value }
    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
