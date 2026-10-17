import Foundation
import Testing
@testable import NookCore

@Suite("GmailClient")
struct GmailClientTests {
    func client(_ transport: StubTransport, tokens: StaticTokens = StaticTokens()) -> GmailClient {
        GmailClient(transport: transport, tokens: tokens, rateLimiter: nil, retryDelay: { _, _ in })
    }

    @Test func sendsBearerTokenAndDecodes() async throws {
        let transport = StubTransport([.init(200, #"{"emailAddress":"me@example.com","historyId":"77"}"#)])
        let profile = try await client(transport).profile()

        #expect(profile == GmailProfile(emailAddress: "me@example.com", historyId: "77"))
        let request = try #require(transport.recorded.first)
        #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-0")
    }

    @Test func refreshesTheTokenOnceAfter401() async throws {
        let tokens = StaticTokens()
        let transport = StubTransport([.init(401), .init(200, #"{"emailAddress":"a","historyId":"1"}"#)])
        _ = try await client(transport, tokens: tokens).profile()

        #expect(await tokens.refreshCount == 1)
        #expect(transport.recorded.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test func givesUpAfterASecond401() async throws {
        let transport = StubTransport([.init(401), .init(401)])
        await #expect(throws: GmailError.unauthorized) {
            _ = try await client(transport).profile()
        }
    }

    @Test func retriesRateLimitsAndServerErrors() async throws {
        let transport = StubTransport([.init(429), .init(503), .init(200, #"{"emailAddress":"a","historyId":"1"}"#)])
        _ = try await client(transport).profile()
        #expect(transport.recorded.count == 3)
    }

    @Test func stopsRetryingEventually() async throws {
        let transport = StubTransport(Array(repeating: .init(500, #"{"error":{"message":"backend down"}}"#), count: 10))
        await #expect(throws: GmailError.http(status: 500, message: "backend down")) {
            _ = try await client(transport).profile()
        }
        #expect(transport.recorded.count == 7)
    }

    static let quotaBody = #"{"error":{"code":403,"message":"Quota exceeded for quota metric 'Total Query Cost' and limit 'Units per minute per user' of service 'gmail.googleapis.com'","errors":[{"reason":"rateLimitExceeded"}],"status":"PERMISSION_DENIED"}}"#

    @Test func retriesGmailsRateLimit403() async throws {
        let transport = StubTransport([.init(403, Self.quotaBody), .init(200, #"{"emailAddress":"a","historyId":"1"}"#)])
        _ = try await client(transport).profile()
        #expect(transport.recorded.count == 2)
    }

    @Test func aRateLimitThatOutlastsTheRetriesSaysSoPlainly() async throws {
        let transport = StubTransport(Array(repeating: .init(403, Self.quotaBody), count: 10))
        await #expect(throws: GmailError.rateLimited) {
            _ = try await client(transport).profile()
        }
        #expect(GmailError.rateLimited.errorDescription?.contains("slow down") == true)
    }

    @Test func doesNotRetryRealPermissionErrors() async throws {
        let body = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","errors":[{"reason":"insufficientPermissions"}]}}"#
        let transport = StubTransport([.init(403, body), .init(200)])
        await #expect(throws: GmailError.http(status: 403, message: "Request had insufficient authentication scopes.")) {
            _ = try await client(transport).profile()
        }
        #expect(transport.recorded.count == 1)
    }

    @Test(arguments: [
        (#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#, true),
        (#"{"error":{"message":"Quota exceeded for quota metric 'Queries' and limit 'Queries per minute per user'"}}"#, true),
        (#"{"error":{"message":"Daily Limit Exceeded","errors":[{"reason":"dailyLimitExceeded"}]}}"#, false),
        ("not json", false),
    ])
    func classifiesRateLimits(body: String, expected: Bool) {
        #expect(GmailClient.isRateLimit(Data(body.utf8)) == expected)
    }

    @Test func passesRetryAfterToTheBackoff() async throws {
        let delays = DelayLog()
        let transport = StubTransport([.init(429, "{}", headers: ["Retry-After": "7"]), .init(200, #"{"emailAddress":"a","historyId":"1"}"#)])
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: nil, retryDelay: { attempt, after in delays.append(attempt, after) })
        _ = try await client.profile()
        #expect(delays.entries.count == 1)
        #expect(delays.entries.first?.0 == 0)
        #expect(delays.entries.first?.1 == 7)
    }

    @Test func pacesRequestsThroughTheRateLimiter() async throws {
        let sleeps = DelayLog()
        let clock = FixedClock()
        let limiter = RateLimiter(unitsPerSecond: 100, burst: 10, now: { clock.now }, sleep: { sleeps.append(0, $0) })
        let transport = StubTransport(Array(repeating: .init(200, #"{"id":"m"}"#), count: 3))
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: limiter, retryDelay: { _, _ in })
        for _ in 0..<3 { _ = try await client.message(id: "m", format: .full) }
        // Each fetch costs 5 units: the first two fit the burst of 10, the third waits 5 units at 100/s.
        #expect(sleeps.entries.map { $0.1 } == [0.05])
    }


    @Test func mapsNotFound() async throws {
        await #expect(throws: GmailError.notFound) {
            _ = try await client(StubTransport([.init(404)])).history(since: "1")
        }
    }

    @Test func pagesThroughMessageLists() async throws {
        let transport = StubTransport([
            .init(200, #"{"messages":[{"id":"a"},{"id":"b"}],"nextPageToken":"p2"}"#),
            .init(200, #"{"messages":[{"id":"c"}]}"#),
        ])
        let ids = try await client(transport).listMessageIDs(query: "in:inbox", limit: 10)

        #expect(ids == ["a", "b", "c"])
        let second = try #require(transport.recorded.last?.url).absoluteString
        #expect(second.contains("pageToken=p2"))
        #expect(second.contains("q=in:inbox"))
    }

    @Test func pagesThroughHistoryAndReturnsTheNewestCursor() async throws {
        let transport = StubTransport([
            .init(200, #"{"history":[{"id":"5","messagesAdded":[{"message":{"id":"m1","labelIds":["INBOX"]}}]}],"nextPageToken":"n","historyId":"9"}"#),
            .init(200, #"{"history":[{"id":"6","labelsRemoved":[{"message":{"id":"m1","labelIds":[]},"labelIds":["UNREAD"]}]}],"historyId":"10"}"#),
        ])
        let history = try await client(transport).history(since: "4")

        #expect(history.historyId == "10")
        #expect(history.records.map(\.id) == ["5", "6"])
        #expect(history.records[1].labelsRemoved?.first?.message.labelIds == [])
        #expect(transport.recorded.first?.url?.absoluteString.contains("historyTypes=messageAdded") == true)
    }

    @Test func postsJSONBodies() async throws {
        let transport = StubTransport([.init(200)])
        try await client(transport).modifyThread(id: "t1", add: ["STARRED"], remove: ["INBOX"])

        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("threads/t1/modify") == true)
        let data = try #require(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: [String]]
        #expect(body == ["addLabelIds": ["STARRED"], "removeLabelIds": ["INBOX"]])
    }
}

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func refillsOverTimeUpToTheBurst() async {
        let sleeps = DelayLog()
        let clock = FixedClock()
        let limiter = RateLimiter(unitsPerSecond: 10, burst: 20, now: { clock.now }, sleep: { sleeps.append(0, $0) })

        await limiter.acquire(20)
        #expect(sleeps.entries.isEmpty)
        await limiter.acquire(5)
        #expect(sleeps.entries.last?.1 == 0.5)

        // A long quiet spell refills only up to the burst size.
        clock.advance(100)
        await limiter.acquire(20)
        #expect(sleeps.entries.count == 1)
        await limiter.acquire(10)
        #expect(sleeps.entries.last?.1 == 1.0)
    }

    @Test func costsFollowGmailsQuotaTable() {
        #expect(GmailQuota.cost(method: "GET", path: "messages/abc") == 5)
        #expect(GmailQuota.cost(method: "GET", path: "history") == 2)
        #expect(GmailQuota.cost(method: "POST", path: "messages/send") == 100)
        #expect(GmailQuota.cost(method: "POST", path: "threads/t1/modify") == 10)
        #expect(GmailQuota.cost(method: "GET", path: "profile") == 1)
    }
}

@Suite("Google OAuth")
struct GoogleOAuthTests {
    @Test func pkceMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE().verifier
        #expect(verifier.count == 64)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test func authorizationURLCarriesEverythingGoogleNeeds() throws {
        let url = GoogleOAuth.authorizationURL(
            config: GoogleClientConfig(clientId: "cid", clientSecret: "s"),
            redirectURI: "http://127.0.0.1:5000", challenge: "ch", state: "st"
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == "cid")
        #expect(query["redirect_uri"] == "http://127.0.0.1:5000")
        #expect(query["code_challenge"] == "ch")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "st")
        #expect(query["access_type"] == "offline")
        #expect(query["scope"]?.contains("https://www.googleapis.com/auth/gmail.modify") == true)
    }

    @Test func exchangesTheCodeAndRequiresARefreshToken() async throws {
        let config = GoogleClientConfig(clientId: "cid", clientSecret: "secret")
        let ok = StubTransport([.init(200, #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#)])
        let tokens = try await GoogleOAuth.exchange(code: "c/1", verifier: "v", redirectURI: "http://127.0.0.1:1", config: config, transport: ok)
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")

        let bodyData = try #require(ok.recorded.first?.httpBody)
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(body.contains("code=c%2F1"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1"))

        let missing = StubTransport([.init(200, #"{"access_token":"at","expires_in":3600}"#)])
        await #expect(throws: OAuthError.missingRefreshToken) {
            _ = try await GoogleOAuth.exchange(code: "c", verifier: "v", redirectURI: "r", config: config, transport: missing)
        }
    }

    @Test func refreshKeepsTheOldRefreshTokenAndPersists() async throws {
        let store = MemorySecretStore()
        let expired = TokenSet(accessToken: "old", refreshToken: "rt", expiry: .distantPast)
        let transport = StubTransport([.init(200, #"{"access_token":"new","expires_in":3600}"#)])
        let provider = OAuthTokenProvider(email: "me@x.com", tokens: expired, config: GoogleClientConfig(clientId: "c", clientSecret: "s"), store: store, transport: transport)

        #expect(try await provider.accessToken(forceRefresh: false) == "new")
        #expect(store.tokens(for: "me@x.com")?.refreshToken == "rt")
        // Still fresh, so no second request.
        #expect(try await provider.accessToken(forceRefresh: false) == "new")
        #expect(transport.recorded.count == 1)
    }

    @Test func surfacesGoogleErrorDescriptions() async throws {
        let transport = StubTransport([.init(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)])
        await #expect(throws: OAuthError.signInExpired) {
            _ = try await GoogleOAuth.refresh(TokenSet(accessToken: "", refreshToken: "r", expiry: .now), config: .init(clientId: "c", clientSecret: "s"), transport: transport)
        }
    }

    @Test func parsesLoopbackCallbacks() {
        let request = "GET /?state=abc&code=4%2F0Ab&scope=email HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(LoopbackServer.callbackParameters(fromRequest: request) == ["state": "abc", "code": "4/0Ab", "scope": "email"])
        #expect(LoopbackServer.callbackParameters(fromRequest: "GET /favicon.ico HTTP/1.1") == [:])
        #expect(LoopbackServer.callbackParameters(fromRequest: "POST / HTTP/1.1") == nil)
    }

    @Test func loopbackServerDeliversTheCallback() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        #expect(port > 0)

        async let parameters = server.waitForCallback(timeout: .seconds(5))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=xyz&state=s1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("signed in"))
        #expect(try await parameters == ["code": "xyz", "state": "s1"])
    }

    @Test func clientConfigPrefersTheEnvironment() throws {
        let store = MemorySecretStore()
        try GoogleClientConfig(clientId: " stored ", clientSecret: "s").save(to: store)
        #expect(GoogleClientConfig.load(from: store, environment: [:]) == GoogleClientConfig(clientId: "stored", clientSecret: "s"))
        #expect(GoogleClientConfig.load(from: store, environment: ["NOOK_GOOGLE_CLIENT_ID": "env"]).clientId == "env")
        #expect(!GoogleClientConfig(clientId: "x", clientSecret: "").isComplete)
    }
}
