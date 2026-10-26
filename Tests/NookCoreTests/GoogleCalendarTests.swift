import Foundation
import Testing
@testable import NookCore

@Suite("Calendar")
struct GoogleCalendarTests {
    private let me = "me@example.com"

    private func calendar(_ replies: [StubTransport.Reply]) -> (GoogleCalendar, StubTransport) {
        let transport = StubTransport(replies)
        return (GoogleCalendar(account: me, transport: transport, tokens: StaticTokens()), transport)
    }

    @Test func readsTheCalendarsYouShowAndTheirEvents() async throws {
        let (client, transport) = calendar([
            .init(200, """
            {"items": [
              {"id": "me@example.com", "summary": "Me", "backgroundColor": "#9fe1e7", "primary": true},
              {"id": "en.indian#holiday@group.v.calendar.google.com", "summary": "Holidays", "selected": true, "backgroundColor": "#16a765"},
              {"id": "hidden@group.calendar.google.com", "summary": "Hidden", "selected": false}
            ]}
            """),
            .init(200, """
            {"items": [
              {"id": "e1", "iCalUID": "u1", "summary": "Design review", "start": {"dateTime": "2026-10-21T10:00:00-07:00"},
               "end": {"dateTime": "2026-10-21T10:30:00-07:00"}, "hangoutLink": "https://meet.google.com/abc-defg-hij",
               "htmlLink": "https://www.google.com/calendar/event?eid=e1",
               "attendees": [{"email": "x@example.com", "responseStatus": "accepted"}, {"email": "me@example.com", "self": true, "responseStatus": "tentative"}]},
              {"id": "e2", "summary": "Gone", "status": "cancelled", "start": {"dateTime": "2026-10-21T11:00:00Z"}, "end": {"dateTime": "2026-10-21T12:00:00Z"}},
              {"id": "e3", "summary": "Home", "eventType": "workingLocation", "start": {"date": "2026-10-21"}, "end": {"date": "2026-10-22"}},
              {"id": "e4", "summary": "1:1", "location": "Zoom https://acme.zoom.us/j/123?pwd=x", "start": {"dateTime": "2026-10-21T15:00:00Z"}, "end": {"dateTime": "2026-10-21T15:30:00Z"}}
            ], "nextPageToken": "p2"}
            """),
            .init(200, #"{"items": [{"id": "e5", "start": {"dateTime": "2026-10-22T09:00:00Z"}, "end": {"dateTime": "2026-10-22T09:15:00Z"}}]}"#),
            .init(200, #"{"items": [{"id": "h1", "summary": "Diwali", "start": {"date": "2026-11-08"}, "end": {"date": "2026-11-09"}}]}"#),
        ])
        let events = try await client.events(from: Date(timeIntervalSince1970: 1_792_000_000), to: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(events.map(\.title) == ["Design review", "1:1", "(No title)", "Diwali"])

        let review = events[0]
        #expect(review.id == "me@example.com/me@example.com/e1")
        #expect(review.start == ISO8601DateFormatter().date(from: "2026-10-21T17:00:00Z"))
        #expect(review.end.timeIntervalSince(review.start) == 1800)
        #expect(review.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(review.response == .tentative)
        #expect(review.color == "#9fe1e7" && review.calendarName == "Me")
        #expect(events[1].joinURL?.absoluteString == "https://acme.zoom.us/j/123?pwd=x")

        let holiday = events[3]
        #expect(holiday.isAllDay)
        #expect(Calendar.current.dateComponents([.year, .month, .day, .hour], from: holiday.start) == DateComponents(year: 2026, month: 11, day: 8, hour: 0))
        #expect(holiday.end.timeIntervalSince(holiday.start) == 86_400)

        let urls = transport.recorded.compactMap(\.url?.absoluteString)
        #expect(urls[0].hasSuffix("users/me/calendarList"))
        #expect(urls[1].contains("calendars/me@example.com/events") && urls[1].contains("singleEvents=true"))
        #expect(urls[2].contains("pageToken=p2"))
        #expect(urls[3].contains("calendars/en.indian%23holiday@group.v.calendar.google.com/events"))
        #expect(urls.count == 4)
    }

    @Test func tellsAMissingPermissionAndASwitchedOffAPIApart() async {
        let scope = #"{"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "details": [{"reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
        let disabled = #"{"error": {"code": 403, "message": "Google Calendar API has not been used in project 1 before or it is disabled.", "details": [{"reason": "SERVICE_DISABLED", "metadata": {"activationUrl": "https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=1"}}]}}"#
        let sources: [String: CalendarSource] = [
            "a@x.com": GoogleCalendar(account: "a@x.com", transport: StubTransport([.init(403, scope)]), tokens: StaticTokens()),
            "b@x.com": GoogleCalendar(account: "b@x.com", transport: StubTransport([.init(403, disabled)]), tokens: StaticTokens()),
            "c@x.com": GoogleCalendar(account: "c@x.com", transport: StubTransport([.init(500, "oops")]), tokens: StaticTokens()),
        ]
        let result = await CalendarSync.run(sources: sources, from: Date(), to: Date().addingTimeInterval(86_400))
        #expect(result.access["a@x.com"] == .needsPermission)
        #expect(result.access["b@x.com"] == .apiDisabled(URL(string: "https://console.developers.google.com/apis/api/calendar-json.googleapis.com/overview?project=1")))
        #expect(result.access["c@x.com"] == nil)
        #expect(result.failed == ["c@x.com"])
    }

    @Test func aMeetingOnTwoAccountsShowsOnce() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, uid: String?, response: CalendarEvent.Response?, allDay: Bool = false, at offset: TimeInterval = 0) -> CalendarEvent {
            CalendarEvent(id: id, iCalUID: uid, account: id, title: id, start: start + offset, end: start + offset + 1800, isAllDay: allDay, response: response)
        }
        let merged = CalendarSync.merged([
            event("work", uid: "m1", response: .needsAction),
            event("personal", uid: "m1", response: .accepted),
            event("later", uid: "m2", response: nil, at: 3600),
            event("trip", uid: nil, response: nil, allDay: true),
            event("next-week", uid: "m1", response: nil, at: 7 * 86_400),
        ])
        #expect(merged.map(\.id) == ["trip", "personal", "later", "next-week"])
    }

    @Test func findsVideoLinksPastedIntoTheInvite() {
        #expect(GoogleCalendar.meetingLink(in: "Join: https://teams.microsoft.com/l/meetup-join/19%3a. or call")?.host == "teams.microsoft.com")
        #expect(GoogleCalendar.meetingLink(in: "<a href=\"https://us02web.zoom.us/j/8\">link</a>")?.absoluteString == "https://us02web.zoom.us/j/8")
        #expect(GoogleCalendar.meetingLink(in: "Room 4, https://example.com/agenda") == nil)
    }

    @Test func overlappingEventsShareTheWidth() {
        let base = Date(timeIntervalSince1970: 0)
        func at(_ start: Double, _ end: Double) -> (start: Date, end: Date) { (base + start * 3600, base + end * 3600) }
        let slots = CalendarLayout.slots(for: [at(9, 10), at(9.5, 11), at(10, 10.5), at(12, 13), at(14, 14)])
        #expect(slots == [
            .init(column: 0, columns: 2), .init(column: 1, columns: 2), .init(column: 0, columns: 2),
            .init(column: 0, columns: 1), .init(column: 0, columns: 1),
        ])
    }

    @Test func tShowsTheAgendaAndGCOpensTheCalendar() {
        var interpreter = ShortcutInterpreter()
        let start = Date()
        #expect(interpreter.interpret(characters: "t", keyCode: 17, now: start) == .agenda)
        #expect(interpreter.interpret(characters: "g", keyCode: 5, now: start) == nil)
        #expect(interpreter.interpret(characters: "c", keyCode: 8, now: start.addingTimeInterval(0.2)) == .calendar)
    }

    @Test func asksForTheCalendarAtSignIn() {
        #expect(GoogleOAuth.scopes.contains("https://www.googleapis.com/auth/calendar.readonly"))
    }
}
