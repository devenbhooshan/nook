import Foundation
@testable import NookCore

func makeRepository() throws -> MailRepository {
    MailRepository(db: try Database(path: ":memory:"))
}

extension MailMessage {
    static func fixture(
        id: String, account: String = "me@example.com", thread: String? = nil,
        from: String = "anna@example.com", fromName: String = "Anna", subject: String = "Hello",
        body: String = "Body", labels: Set<String> = [SystemLabel.inbox], minutesAgo: Double = 0,
        to: String = "me@example.com", cc: String = ""
    ) -> MailMessage {
        MailMessage(
            id: id, account: account, threadId: thread ?? id, fromName: fromName, fromEmail: from,
            to: to, cc: cc, subject: subject, snippet: String(body.prefix(80)), bodyText: body,
            date: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60), labels: labels,
            messageIdHeader: "<\(id)@mail.example.com>"
        )
    }
}

/// Builds a Gmail API message with a plain-text body.
func gmailMessage(
    id: String, thread: String? = nil, labels: [String] = [SystemLabel.inbox], subject: String = "Subject \(UUID().uuidString.prefix(4))",
    from: String = "Anna <anna@example.com>", body: String = "Hello there", date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> GmailMessage {
    GmailMessage(
        id: id, threadId: thread ?? id, labelIds: labels, snippet: body,
        internalDate: String(Int(date.timeIntervalSince1970 * 1000)),
        payload: GmailMessagePart(
            mimeType: "text/plain",
            headers: [
                GmailHeader(name: "From", value: from),
                GmailHeader(name: "To", value: "me@example.com"),
                GmailHeader(name: "Subject", value: subject),
                GmailHeader(name: "Message-ID", value: "<\(id)@example.com>"),
            ],
            body: GmailBody(data: MIMEBuilder.base64URL(Data(body.utf8)))
        )
    )
}

/// An in-memory Gmail mailbox.
actor FakeGmail: GmailService {
    var messages: [String: GmailMessage] = [:]
    var historyId = "100"
    var pendingHistory: [GmailHistoryRecord] = []
    var historyExpired = false
    /// Simulates Gmail's rate limit: full fetches start failing once this many have succeeded.
    var rateLimitAfterFullFetches: Int?
    private(set) var fullFetches: [String] = []
    private(set) var minimalFetches: [String] = []
    private(set) var historyCalls = 0
    private(set) var modifiedThreads: [(id: String, add: [String], remove: [String])] = []
    private(set) var sent: [(raw: String, threadId: String?)] = []

    init(messages: [GmailMessage] = []) {
        for message in messages { self.messages[message.id] = message }
    }

    func add(_ message: GmailMessage, historyId: String) {
        messages[message.id] = message
        pendingHistory.append(GmailHistoryRecord(id: historyId, messagesAdded: [.init(message: GmailMessageRef(id: message.id, threadId: message.threadId, labelIds: message.labelIds))]))
        self.historyId = historyId
    }

    func delete(_ id: String, historyId: String) {
        messages[id] = nil
        pendingHistory.append(GmailHistoryRecord(id: historyId, messagesDeleted: [.init(message: GmailMessageRef(id: id))]))
        self.historyId = historyId
    }

    func relabel(_ id: String, labels: [String], historyId: String, includeLabelsInHistory: Bool = true) {
        messages[id]?.labelIds = labels
        let ref = GmailMessageRef(id: id, labelIds: includeLabelsInHistory ? labels : nil)
        pendingHistory.append(GmailHistoryRecord(id: historyId, labelsRemoved: [.init(message: ref, labelIds: [])]))
        self.historyId = historyId
    }

    func expireHistory() { historyExpired = true }
    func rateLimit(after fetches: Int?) { rateLimitAfterFullFetches = fetches }
    func setHistoryId(_ id: String) { historyId = id }

    // MARK: GmailService

    func profile() async throws -> GmailProfile {
        GmailProfile(emailAddress: "me@example.com", historyId: historyId)
    }

    /// Like Gmail, listings leave out spam and trash, and honor `-in:drafts`.
    func listMessageIDs(query: String, limit: Int) async throws -> [String] {
        let excluded: Set<String> = query.contains("-in:drafts") ? ["SPAM", "TRASH", "DRAFT"] : ["SPAM", "TRASH"]
        let listed = messages.values.filter {
            excluded.isDisjoint(with: $0.labelIds ?? []) && (query != "in:drafts" || ($0.labelIds ?? []).contains("DRAFT"))
        }
        return Array(listed.sorted { ($0.internalDate ?? "") > ($1.internalDate ?? "") }.map(\.id).prefix(limit))
    }

    func message(id: String, format: GmailMessageFormat) async throws -> GmailMessage {
        guard let message = messages[id] else { throw GmailError.notFound }
        if format == .full, let limit = rateLimitAfterFullFetches, fullFetches.count >= limit { throw GmailError.rateLimited }
        if format == .full { fullFetches.append(id) } else { minimalFetches.append(id) }
        return format == .full ? message : GmailMessage(id: id, threadId: message.threadId, labelIds: message.labelIds)
    }

    func history(since historyId: String) async throws -> GmailHistory {
        historyCalls += 1
        if historyExpired { throw GmailError.notFound }
        let records = pendingHistory.filter { (Int($0.id) ?? 0) > (Int(historyId) ?? 0) }
        return GmailHistory(records: records, historyId: self.historyId)
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        modifiedThreads.append((id, add, remove))
    }

    func modifyMessage(id: String, add: [String], remove: [String]) async throws {}
    func trashThread(id: String) async throws {}
    func untrashThread(id: String) async throws {}

    func send(raw: String, threadId: String?) async throws -> String? {
        sent.append((raw, threadId))
        return threadId ?? "sent-thread"
    }

    func draftID(messageId: String) async throws -> String? { "draft-\(messageId)" }
    func updateDraft(id: String, raw: String, threadId: String?) async throws {}
    func sendDraft(id: String) async throws -> String? { nil }

    var attachmentData: [String: Data] = [:]
    func setAttachment(_ id: String, data: Data) { attachmentData[id] = data }
    func attachment(messageId: String, attachmentId: String) async throws -> Data {
        guard let data = attachmentData[attachmentId] else { throw GmailError.notFound }
        return data
    }

    func resetCounters() {
        fullFetches = []
        minimalFetches = []
    }
}

/// Replays canned HTTP responses and records requests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]
        init(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
            self.status = status
            self.body = Data(body.utf8)
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var recorded: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? Reply(500, "out of stubs") : replies.removeFirst()
        }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}

/// Hands out tokens and counts refreshes.
actor StaticTokens: AccessTokenProvider {
    private(set) var refreshCount = 0

    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshCount += 1 }
        return "token-\(refreshCount)"
    }
}

/// A tag model that answers from a closure.
struct ScriptedModel: TagModel {
    var displayName = "Scripted"
    var answer: @Sendable (String) throws -> String

    func complete(system: String, prompt: String) async throws -> String {
        try answer(prompt)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Records requested delays: (attempt, seconds).
final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, TimeInterval?)] = []
    func append(_ attempt: Int, _ seconds: TimeInterval?) { lock.withLock { items.append((attempt, seconds)) } }
    var entries: [(Int, TimeInterval?)] { lock.withLock { items } }
}

/// A clock that only moves when told to.
final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}
