import Foundation
import Testing
@testable import NookCore

/// Invites an assistant prepares: opened in Nook for review, sent to Google only from there.
@Suite("Calendar invites")
struct CalendarInviteTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    func greg() -> EventInvite {
        EventInvite(
            account: "deven@warmdogo.ai", title: "WarmDogo walkthrough with Greg",
            start: EventInvite.date("2026-11-18T19:00", in: Self.kolkata)!, end: EventInvite.date("2026-11-18T19:30", in: Self.kolkata)!,
            timeZone: "Asia/Kolkata", attendees: "gdermond@esri.example"
        )
    }

    @Test func createEventOnlyOpensTheInviteInNook() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "deven@warmdogo.ai", name: "Deven")
        let opened = URLLog()
        let gmail = FakeGmail()
        let server = MCPServer(
            repo: repo, version: "test", isEnabled: { true }, openURL: { opened.append($0) }, makeGmail: { _ in gmail },
            attachmentCache: { AttachmentCache(root: FileManager.default.temporaryDirectory) },
            createdDrafts: CreatedDrafts(defaults: UserDefaults(suiteName: "nook-tests-\(UUID().uuidString)")!)
        )
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "create_event", "arguments": [
            "account": "deven@warmdogo.ai", "title": "WarmDogo walkthrough with Greg", "start": "2026-11-18T19:00", "end": "2026-11-18T19:30",
            "time_zone": "Asia/Kolkata", "attendees": ["gdermond@esri.example"],
        ] as [String: Any]]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        #expect(!response.contains("\"isError\":true"), "\(response)")

        let link = try #require(opened.urls.first.flatMap(NookURL.init))
        guard case let .event(invite) = link else { Issue.record("not an event link: \(link)"); return }
        #expect(invite.title == "WarmDogo walkthrough with Greg")
        #expect(invite.start == ISO8601DateFormatter().date(from: "2026-11-18T13:30:00Z"), "19:00 in Kolkata")
        #expect(invite.end.timeIntervalSince(invite.start) == 30 * 60)
        #expect(invite.guestEmails == ["gdermond@esri.example"])
        #expect(invite.addMeet, "Meet by default")
    }

    @Test func theLinkCarriesEverythingAcross() {
        var invite = greg()
        invite.notes = "Agenda: signals, leads & next steps + Q&A"
        invite.attendees = "gdermond@esri.example, \"Doe, J\" <j@d.example>"
        #expect(NookURL(NookURL.event(invite).url) == .event(invite))
    }

    @Test func sendingCreatesTheEventWithMeetAndEmailsGuests() async throws {
        let transport = StubTransport([.init(200, #"{"htmlLink": "https://calendar.google.com/event?eid=1", "hangoutLink": "https://meet.google.com/abc-defg-hij"}"#)])
        let made = try await GoogleCalendar(account: "deven@warmdogo.ai", transport: transport, tokens: StaticTokens()).insert(greg())
        #expect(made.meetLink == "https://meet.google.com/abc-defg-hij")

        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "POST")
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("calendars/primary/events") && url.contains("sendUpdates=all") && url.contains("conferenceDataVersion=1"))
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["summary"] as? String == "WarmDogo walkthrough with Greg")
        #expect((body["start"] as? [String: Any])?["dateTime"] as? String == "2026-11-18T19:00:00+05:30")
        #expect((body["start"] as? [String: Any])?["timeZone"] as? String == "Asia/Kolkata")
        #expect((body["attendees"] as? [[String: Any]])?.compactMap { $0["email"] as? String } == ["gdermond@esri.example"])
        let conference = (body["conferenceData"] as? [String: Any])?["createRequest"] as? [String: Any]
        #expect((conference?["conferenceSolutionKey"] as? [String: Any])?["type"] as? String == "hangoutsMeet")
    }

    @Test func aSignInRemembersWhatItAllows() async throws {
        let config = GoogleClientConfig(clientId: "c", clientSecret: "s")
        let old = TokenSet(accessToken: "", refreshToken: "r", expiry: .now)
        #expect(old.allows(GoogleOAuth.calendarEventsScope) == nil, "not known for tokens saved before")
        // Old sign-ins tokens' are decoded without the field.
        let saved = try JSONDecoder().decode(TokenSet.self, from: Data(#"{"accessToken":"a","refreshToken":"r","expiry":0}"#.utf8))
        #expect(saved.scopes == nil)

        let readOnly = StubTransport([.init(200, #"{"access_token": "a", "expires_in": 3600, "scope": "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.readonly"}"#)])
        let refreshed = try await GoogleOAuth.refresh(old, config: config, transport: readOnly)
        #expect(refreshed.allows(GoogleOAuth.calendarEventsScope) == false)
        #expect(refreshed.allows("https://www.googleapis.com/auth/gmail.modify") == true)

        // A refresh that doesn't say keeps what was known.
        let silent = StubTransport([.init(200, #"{"access_token": "b", "expires_in": 3600}"#)])
        #expect(try await GoogleOAuth.refresh(refreshed, config: config, transport: silent).scopes == refreshed.scopes)
    }

    @Test func createEventSaysWhenTheAccountMustSignInAgain() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "deven@warmdogo.ai", name: "Deven")
        let opened = URLLog()
        let gmail = FakeGmail()
        let server = MCPServer(
            repo: repo, version: "test", isEnabled: { true }, openURL: { opened.append($0) }, makeGmail: { _ in gmail },
            attachmentCache: { AttachmentCache(root: FileManager.default.temporaryDirectory) },
            createdDrafts: CreatedDrafts(defaults: UserDefaults(suiteName: "nook-tests-\(UUID().uuidString)")!)
        )
        server.grantedScopes = { _ in ["https://www.googleapis.com/auth/calendar.readonly"] }
        let result = try server.createEvent([
            "account": "deven@warmdogo.ai", "title": "Walkthrough", "start": "2026-11-18T19:00", "end": "2026-11-18T19:30",
            "time_zone": "Asia/Kolkata", "attendees": ["gdermond@esri.example"],
        ])
        #expect(result["needs_sign_in"] as? Bool == true)
        #expect((result["status"] as? String)?.contains("Sign in again") == true)
        #expect(opened.urls.count == 1, "the invite still opens, with the notice, so nothing has to be asked twice")
    }

    @Test func anAccountSignedInBeforeAsksToSignInAgain() async {
        let scope = #"{"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "details": [{"reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
        let client = GoogleCalendar(account: "deven@warmdogo.ai", transport: StubTransport([.init(403, scope)]), tokens: StaticTokens())
        await #expect(throws: CalendarWriteError.needsPermission) { try await client.insert(greg()) }
    }
}
