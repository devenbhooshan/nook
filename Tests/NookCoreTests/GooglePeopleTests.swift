import Foundation
import Testing
@testable import NookCore

@Suite("Profile photos")
struct GooglePeopleTests {
    private func people(_ replies: [StubTransport.Reply]) -> (GooglePeople, StubTransport) {
        let transport = StubTransport(replies)
        return (GooglePeople(transport: transport, tokens: StaticTokens()), transport)
    }

    @Test func collectsPhotosFromContactsOtherContactsAndTheDirectory() async throws {
        let (client, transport) = people([
            .init(200, """
            {"connections": [
              {"emailAddresses": [{"value": "Anna@Example.com"}, {"value": "anna@work.com"}],
               "photos": [{"url": "https://lh3/default", "default": true}, {"url": "https://lh3/anna-old"},
                          {"url": "https://lh3/anna", "metadata": {"primary": true}}]},
              {"emailAddresses": [{"value": "letters@example.com"}], "photos": [{"url": "https://lh3/x", "default": true}]}
            ], "nextPageToken": "p2"}
            """),
            .init(200, #"{"connections": [{"emailAddresses": [{"value": "bo@example.com"}], "photos": [{"url": "https://lh3/bo"}]}]}"#),
            .init(200, """
            {"otherContacts": [
              {"emailAddresses": [{"value": "anna@example.com"}], "photos": [{"url": "https://lh3/anna-google"}]},
              {"emailAddresses": [{"value": "cy@example.com"}], "photos": [{"url": "https://lh3/cy"}]}
            ]}
            """),
            .init(200, #"{"people": [{"emailAddresses": [{"value": "dee@supergrow.ai"}], "photos": [{"url": "https://lh3/dee"}]}]}"#),
        ])
        let photos = try await client.photoURLs()
        #expect(photos == [
            // A saved contact's photo wins over the one Google has.
            "anna@example.com": URL(string: "https://lh3/anna")!,
            "anna@work.com": URL(string: "https://lh3/anna")!,
            "bo@example.com": URL(string: "https://lh3/bo")!,
            "cy@example.com": URL(string: "https://lh3/cy")!,
            "dee@supergrow.ai": URL(string: "https://lh3/dee")!,
        ])
        let urls = transport.recorded.compactMap(\.url?.absoluteString)
        #expect(urls[0].contains("people/me/connections") && urls[0].contains("personFields=emailAddresses,photos"))
        #expect(urls[1].contains("pageToken=p2"))
        #expect(urls[2].contains("otherContacts") && urls[2].contains("readMask=emailAddresses,photos"))
        #expect(urls[3].contains("people:listDirectoryPeople") && urls[3].contains("DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"))
        #expect(transport.recorded.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token-0" })
    }

    @Test func personalAccountsWithoutADirectoryStillGetPhotos() async throws {
        let (client, _) = people([
            .init(200, #"{"connections": [{"emailAddresses": [{"value": "bo@example.com"}], "photos": [{"url": "https://lh3/bo"}]}]}"#),
            .init(200, "{}"),
            .init(400, #"{"error": {"code": 400, "message": "Must be a G Suite domain user."}}"#),
        ])
        #expect(try await client.photoURLs() == ["bo@example.com": URL(string: "https://lh3/bo")!])
    }

    @Test func refreshesTheTokenOnceOn401() async throws {
        let (client, transport) = people([.init(401), .init(200, "{}"), .init(200, "{}"), .init(200, "{}")])
        #expect(try await client.photoURLs().isEmpty)
        #expect(transport.recorded[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
    }

    @Test func tellsAMissingPermissionFromASwitchedOffAPI() {
        let scope = #"{"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "details": [{"reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
        #expect(GooglePeople.error(status: 403, data: Data(scope.utf8)) == .needsPermission)

        let disabled = """
        {"error": {"code": 403, "message": "People API has not been used in project 123 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/people.googleapis.com/overview?project=123 then retry.",
          "details": [{"reason": "SERVICE_DISABLED", "metadata": {"activationUrl": "https://console.developers.google.com/apis/api/people.googleapis.com/overview?project=123"}}]}}
        """
        #expect(GooglePeople.error(status: 403, data: Data(disabled.utf8))
            == .apiDisabled(URL(string: "https://console.developers.google.com/apis/api/people.googleapis.com/overview?project=123")))

        let messageOnly = #"{"error": {"code": 403, "message": "People API has not been used in project 9 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/people.googleapis.com/overview?project=9 then retry."}}"#
        #expect(GooglePeople.error(status: 403, data: Data(messageOnly.utf8))
            == .apiDisabled(URL(string: "https://console.developers.google.com/apis/api/people.googleapis.com/overview?project=9")))

        #expect(GooglePeople.error(status: 500, data: Data("oops".utf8)) == .http(status: 500, message: "oops"))
    }

    @Test func syncMergesAccountsAndReportsWhatEachAllowed() async {
        struct Fake: PhotoDirectory {
            var result: Result<[String: URL], PeopleError>
            func photoURLs() async throws -> [String: URL] { try result.get() }
        }
        let result = await PhotoSync.run(directories: [
            "me@gmail.com": Fake(result: .success(["a@x.com": URL(string: "https://lh3/a")!])),
            "me@work.com": Fake(result: .success(["b@x.com": URL(string: "https://lh3/b")!])),
            "old@gmail.com": Fake(result: .failure(.needsPermission)),
            "off@gmail.com": Fake(result: .failure(.apiDisabled(nil))),
            "offline@gmail.com": Fake(result: .failure(.http(status: 0, message: "offline"))),
        ])
        #expect(result.photos == ["a@x.com": URL(string: "https://lh3/a")!, "b@x.com": URL(string: "https://lh3/b")!])
        #expect(result.access == [
            "me@gmail.com": .available, "me@work.com": .available, "old@gmail.com": .needsPermission, "off@gmail.com": .apiDisabled(nil),
        ])
    }

    @Test func signInAsksForContactsAndCanPreselectTheAccount() {
        let url = GoogleOAuth.authorizationURL(
            config: GoogleClientConfig(clientId: "c", clientSecret: "s"), redirectURI: "http://127.0.0.1:1", challenge: "x", state: "y",
            loginHint: "deven@supergrow.ai"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let scope = items.first { $0.name == "scope" }?.value ?? ""
        #expect(scope.contains("contacts.other.readonly") && scope.contains("contacts.readonly") && scope.contains("directory.readonly"))
        #expect(items.first { $0.name == "login_hint" }?.value == "deven@supergrow.ai")
    }
}

/// Answers by URL, since downloads run in no particular order. Each URL's replies are used in turn.
final class PhotoServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: [StubTransport.Reply]]
    private(set) var count = 0

    init(_ replies: [String: [StubTransport.Reply]]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: StubTransport.Reply = lock.withLock {
            count += 1
            let key = request.url!.absoluteString
            guard var queue = replies[key], !queue.isEmpty else { return StubTransport.Reply(500) }
            let next = queue.removeFirst()
            replies[key] = queue
            return next
        }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Stored profile photos")
struct AvatarStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-avatars-\(UUID().uuidString)")

    @Test func downloadsOnceAndAgainOnlyWhenThePhotoChanges() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AvatarStore(directory: directory)
        let transport = PhotoServer([
            "https://lh3/anna-1": [.init(200, "anna-1")],
            "https://lh3/bo": [.init(200, "bo")],
            "https://lh3/anna-2": [.init(404), .init(200, "anna-2")],
        ])
        let photos = ["anna@example.com": URL(string: "https://lh3/anna-1")!, "bo@example.com": URL(string: "https://lh3/bo")!]

        #expect(await store.download(photos, transport: transport).count == 2)
        #expect(store.image(for: "Anna@Example.com") == Data("anna-1".utf8))
        // Nothing new, so nothing is fetched.
        #expect(await store.download(photos, transport: transport).isEmpty)
        #expect(transport.count == 2)

        // A failed download keeps the old photo; a changed link replaces it.
        let changed = ["anna@example.com": URL(string: "https://lh3/anna-2")!]
        #expect(await store.download(changed, transport: transport).isEmpty)
        #expect(store.image(for: "anna@example.com") == Data("anna-1".utf8))
        #expect(await store.download(changed, transport: transport) == ["anna@example.com"])
        #expect(store.image(for: "anna@example.com") == Data("anna-2".utf8))

        // The index survives a relaunch, and files don't name the address.
        #expect(AvatarStore(directory: directory).outdated(photos).keys.sorted() == ["anna@example.com"])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains("anna") || $0.contains("example") })
    }

    @Test func refetchesFilesThatWereCleared() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AvatarStore(directory: directory)
        let photos = ["bo@example.com": URL(string: "https://lh3/bo")!]
        await store.download(photos, transport: StubTransport([.init(200, "bo")]))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(AvatarStore.key(for: "bo@example.com")))
        #expect(store.outdated(photos).count == 1)
    }
}

@Suite("Brand logos")
struct BrandLogosTests {
    struct FakeDNS: TXTResolver {
        var records: [String: [String]]
        func txt(_ name: String) async -> [String] { records[name] ?? [] }
    }

    @Test func readsTheLogoFromABIMIRecord() {
        #expect(BrandLogos.logoURL(fromRecords: ["v=BIMI1;l=https://www.apple.com/bimi/v2/apple.svg;a=https://www.apple.com/bimi/v2/apple.pem;"])
            == URL(string: "https://www.apple.com/bimi/v2/apple.svg"))
        #expect(BrandLogos.logoURL(fromRecords: ["v=spf1 include:_spf.google.com ~all", "v=BIMI1; l= https://x.com/l.svg"]) == URL(string: "https://x.com/l.svg"))
        // Not BIMI, no logo, or not HTTPS.
        #expect(BrandLogos.logoURL(fromRecords: ["v=BIMI1; l=;"]) == nil)
        #expect(BrandLogos.logoURL(fromRecords: ["v=BIMI1; l=http://x.com/l.svg"]) == nil)
        #expect(BrandLogos.logoURL(fromRecords: []) == nil)
    }

    @Test func triesTheSendingDomainThenItsParents() {
        #expect(BrandLogos.candidates(for: "Email.Apple.com") == ["email.apple.com", "apple.com"])
        #expect(BrandLogos.candidates(for: "stripe.com") == ["stripe.com"])
        #expect(BrandLogos.candidates(for: "localhost").isEmpty)
        #expect(BrandLogos.domain(of: "no_reply@email.apple.com") == "email.apple.com")
        #expect(BrandLogos.domain(of: "nobody") == nil)
    }

    @Test func downloadsLogosIntoThePhotoStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-logos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AvatarStore(directory: directory)
        let dns = FakeDNS(records: ["default._bimi.apple.com": ["v=BIMI1;l=https://www.apple.com/logo.svg;"]])
        let server = PhotoServer(["https://www.apple.com/logo.svg": [.init(200, "<svg/>")]])

        let updated = await BrandLogos.refresh(domains: ["email.apple.com", "stripe.com"], store: store, dns: dns, transport: server)
        #expect(updated == ["email.apple.com"])
        #expect(store.image(for: BrandLogos.key(for: "email.apple.com")) == Data("<svg/>".utf8))
        #expect(store.image(for: BrandLogos.key(for: "stripe.com")) == nil)
    }

    @Test func theSystemResolverFindsARealRecordOrGivesUpQuietly() async {
        // Needs the network; an offline run just finds nothing, which is what the app does too.
        let records = await SystemDNS(timeout: 3).txt("default._bimi.apple.com")
        if !records.isEmpty { #expect(BrandLogos.logoURL(fromRecords: records) != nil) }
        #expect(await SystemDNS(timeout: 3).txt("default._bimi.no-such-domain.invalid").isEmpty)
    }
}
