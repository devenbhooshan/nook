import Foundation

public enum GmailError: Error, LocalizedError, Equatable {
    /// The resource doesn't exist. For `history`, it means the cursor expired and a full sync is needed.
    case notFound
    case unauthorized
    case http(status: Int, message: String)
    /// Gmail's per-user rate limit, still hit after backing off. Temporary: the next sync picks up where this left off.
    case rateLimited
    case notSignedIn(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Gmail couldn't find that item."
        case .unauthorized: "Gmail rejected the sign-in. Remove and re-add the account."
        case .http(let status, let message): "Gmail error \(status): \(message)"
        case .rateLimited: "Gmail asked Nook to slow down. Syncing resumes automatically in a minute."
        case .notSignedIn(let email): "\(email) isn't signed in."
        }
    }
}

/// The Gmail operations Nook relies on. `SyncEngine` and the app only see this protocol, so tests can supply a fake.
public protocol GmailService: Sendable {
    func profile() async throws -> GmailProfile
    func listMessageIDs(query: String, limit: Int) async throws -> [String]
    func message(id: String, format: GmailMessageFormat) async throws -> GmailMessage
    func history(since historyId: String) async throws -> GmailHistory
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func modifyMessage(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    func untrashThread(id: String) async throws
    func send(raw: String, threadId: String?) async throws
}

/// Sends HTTP requests. `URLSession` conforms; tests use a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Supplies OAuth access tokens, refreshing when asked.
public protocol AccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// Talks to the Gmail REST API. Paces requests under the per-user quota, refreshes auth on 401,
/// and backs off on rate limits and server errors.
public struct GmailClient: GmailService {
    /// Called before a retry with the attempt number and the server's `Retry-After`, if it sent one.
    public typealias RetryDelay = @Sendable (_ attempt: Int, _ retryAfter: TimeInterval?) async -> Void

    private let transport: HTTPTransport
    private let tokens: AccessTokenProvider
    private let baseURL: URL
    private let rateLimiter: RateLimiter?
    private let maxRetries: Int
    private let retryDelay: RetryDelay

    /// Exponential backoff from 1s, capped at 32s, with jitter. A server-sent `Retry-After` wins if it's longer.
    public static let defaultRetryDelay: RetryDelay = { attempt, retryAfter in
        let backoff = min(32, pow(2, Double(attempt))) * Double.random(in: 0.8...1.2)
        try? await Task.sleep(for: .seconds(max(backoff, retryAfter ?? 0)))
    }

    /// - Parameter rateLimiter: Paces requests for this account. Pass `nil` to send without pacing (tests).
    public init(
        transport: HTTPTransport = URLSession.shared,
        tokens: AccessTokenProvider,
        baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!,
        rateLimiter: RateLimiter? = RateLimiter(),
        maxRetries: Int = 6,
        retryDelay: @escaping RetryDelay = GmailClient.defaultRetryDelay
    ) {
        self.transport = transport
        self.tokens = tokens
        self.baseURL = baseURL
        self.rateLimiter = rateLimiter
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }

    public func profile() async throws -> GmailProfile {
        try await get("profile")
    }

    public func listMessageIDs(query: String, limit: Int) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(min(500, limit - ids.count)))]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailMessageList = try await get("messages", query: items)
            ids += page.messages?.map(\.id) ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    public func message(id: String, format: GmailMessageFormat) async throws -> GmailMessage {
        try await get("messages/\(id)", query: [URLQueryItem(name: "format", value: format.rawValue)])
    }

    public func history(since historyId: String) async throws -> GmailHistory {
        var records: [GmailHistoryRecord] = []
        var pageToken: String?
        var latest = historyId
        repeat {
            var items = [URLQueryItem(name: "startHistoryId", value: historyId), URLQueryItem(name: "maxResults", value: "500")]
            for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
                items.append(URLQueryItem(name: "historyTypes", value: type))
            }
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailHistoryPage = try await get("history", query: items)
            records += page.history ?? []
            latest = page.historyId
            pageToken = page.nextPageToken
        } while pageToken != nil
        return GmailHistory(records: records, historyId: latest)
    }

    public func modifyThread(id: String, add: [String], remove: [String]) async throws {
        _ = try await request("threads/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    public func modifyMessage(id: String, add: [String], remove: [String]) async throws {
        _ = try await request("messages/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    public func trashThread(id: String) async throws {
        _ = try await request("threads/\(id)/trash", method: "POST")
    }

    public func untrashThread(id: String) async throws {
        _ = try await request("threads/\(id)/untrash", method: "POST")
    }

    public func send(raw: String, threadId: String?) async throws {
        var body: [String: Any] = ["raw": raw]
        if let threadId { body["threadId"] = threadId }
        _ = try await request("messages/send", method: "POST", body: body)
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }

        var attempt = 0
        var refreshed = false
        while true {
            await rateLimiter?.acquire(GmailQuota.cost(method: method, path: path))
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(try await tokens.accessToken(forceRefresh: refreshed))", forHTTPHeaderField: "Authorization")
            if let bodyData {
                request.httpBody = bodyData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401:
                // The access token may have been revoked or expired early. Refresh once.
                guard !refreshed else { throw GmailError.unauthorized }
                refreshed = true
            case 404:
                throw GmailError.notFound
            case 403 where Self.isRateLimit(data), 429, 500..<600:
                // Gmail reports per-user rate limits as 403, not 429. Those are temporary, so wait and retry.
                guard attempt < maxRetries else {
                    if response.statusCode == 429 || Self.isRateLimit(data) { throw GmailError.rateLimited }
                    throw GmailError.http(status: response.statusCode, message: Self.message(from: data))
                }
                await retryDelay(attempt, response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
                attempt += 1
            default:
                throw GmailError.http(status: response.statusCode, message: Self.message(from: data))
            }
        }
    }

    /// Whether a 403 is a rate limit (retry later) rather than a real permission problem.
    static func isRateLimit(_ data: Data) -> Bool {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                struct Detail: Decodable { var reason: String? }
                var message: String?
                var errors: [Detail]?
            }
            var error: Inner?
        }
        guard let error = (try? JSONDecoder().decode(Envelope.self, from: data))?.error else { return false }
        let rateReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded"]
        if error.errors?.contains(where: { rateReasons.contains($0.reason ?? "") }) == true { return true }
        // Per-minute quota errors sometimes come with only a message.
        let message = error.message?.lowercased() ?? ""
        return message.contains("quota exceeded") && message.contains("per minute")
    }

    static func message(from data: Data) -> String {
        struct Envelope: Decodable { struct Inner: Decodable { var message: String? }; var error: Inner? }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message { return message }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
