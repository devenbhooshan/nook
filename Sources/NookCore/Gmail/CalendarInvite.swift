import Foundation

/// A calendar invite waiting for you to send it. An assistant prepares it over MCP; Nook shows it, and only
/// Send Invite creates the event and has Google email the guests. Like a draft, nothing goes out on its own.
public struct EventInvite: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var account: String
    public var title: String
    public var start: Date
    public var end: Date
    /// An IANA name ("Asia/Kolkata"): the times are shown, and given to Google, in this zone.
    public var timeZone: String
    /// Comma-separated guest addresses.
    public var attendees: String
    public var addMeet: Bool
    public var notes: String

    public init(
        account: String, title: String, start: Date, end: Date, timeZone: String,
        attendees: String, addMeet: Bool = true, notes: String = ""
    ) {
        self.account = account
        self.title = title
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.attendees = attendees
        self.addMeet = addMeet
        self.notes = notes
    }

    /// Guest addresses, as given.
    public var guestEmails: [String] {
        Addresses.parseList(attendees).map(\.email).filter { !$0.isEmpty }
    }

    /// Reads a time like `2026-11-18T19:00` in `timeZone`, or one with its own offset (`…+05:30`, `…Z`).
    public static func date(_ text: String, in timeZone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// `2026-11-18T19:00:00+05:30`: the time as Google wants it, in the invite's zone.
    public static func string(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// What Google made: where to open the event, and its Meet link.
public struct CreatedEvent: Equatable, Sendable {
    public init(link: String?, meetLink: String?) {
        self.link = link
        self.meetLink = meetLink
    }

    public var link: String?
    public var meetLink: String?
}

public enum CalendarWriteError: Error, LocalizedError, Equatable {
    /// Signed in before Nook asked to add events. Signing in again grants it.
    case needsPermission
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .needsPermission: "Nook isn't allowed to add events to this calendar yet. Sign in to the account again in Settings → Accounts, then send."
        case let .failed(message): message
        }
    }
}

/// Creates events. The app uses Google Calendar; the demo prints what it would send.
public protocol CalendarWriter: Sendable {
    func insert(_ invite: EventInvite) async throws -> CreatedEvent
}

extension GoogleCalendar: CalendarWriter {
    /// Adds the event to the account's own calendar and has Google email the guests (`sendUpdates=all`).
    public func insert(_ invite: EventInvite) async throws -> CreatedEvent {
        let body = try JSONSerialization.data(withJSONObject: Self.eventBody(invite))
        let query = [
            URLQueryItem(name: "sendUpdates", value: "all"),
            URLQueryItem(name: "conferenceDataVersion", value: invite.addMeet ? "1" : "0"),
        ]
        let data: Data
        do {
            data = try await send("POST", "calendars/primary/events", query: query, body: body)
        } catch PeopleError.needsPermission {
            throw CalendarWriteError.needsPermission
        }
        struct Made: Decodable {
            struct Conference: Decodable {
                struct EntryPoint: Decodable { var entryPointType: String?; var uri: String? }
                var entryPoints: [EntryPoint]?
            }
            var htmlLink: String?
            var hangoutLink: String?
            var conferenceData: Conference?
        }
        let made = try JSONDecoder().decode(Made.self, from: data)
        let meet = made.hangoutLink ?? made.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        return CreatedEvent(link: made.htmlLink, meetLink: meet)
    }

    public static func eventBody(_ invite: EventInvite) -> [String: Any] {
        let zone = TimeZone(identifier: invite.timeZone) ?? .current
        var body: [String: Any] = [
            "summary": invite.title,
            "start": ["dateTime": EventInvite.string(invite.start, in: zone), "timeZone": zone.identifier],
            "end": ["dateTime": EventInvite.string(invite.end, in: zone), "timeZone": zone.identifier],
            "attendees": invite.guestEmails.map { ["email": $0] },
        ]
        if !invite.notes.isEmpty { body["description"] = invite.notes }
        if invite.addMeet {
            body["conferenceData"] = ["createRequest": [
                "requestId": invite.id.uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"],
            ]]
        }
        return body
    }
}

/// create_event: prepares an invite and opens it in Nook. It never touches the calendar; the user sends it.
extension MCPServer {
    func createEvent(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let account = arguments["account"] as? String, repo.accounts().contains(where: { $0.email == account }) else {
            throw RPCError.invalidParams("`account` must be one of Nook's accounts: \(repo.accounts().map(\.email).joined(separator: ", ")).")
        }
        guard let title = arguments["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RPCError.invalidParams("`title` is required.")
        }
        let zoneName = arguments["time_zone"] as? String ?? TimeZone.current.identifier
        guard let zone = TimeZone(identifier: zoneName) else {
            throw RPCError.invalidParams("Unknown time_zone \(zoneName). Use an IANA name such as Asia/Kolkata or America/Los_Angeles.")
        }
        guard let start = (arguments["start"] as? String).flatMap({ EventInvite.date($0, in: zone) }),
              let end = (arguments["end"] as? String).flatMap({ EventInvite.date($0, in: zone) }) else {
            throw RPCError.invalidParams("`start` and `end` are required, like 2026-11-18T19:00 (in time_zone).")
        }
        guard end > start else { throw RPCError.invalidParams("`end` must be after `start`.") }
        let attendees: String
        if let list = arguments["attendees"] as? [String] {
            attendees = list.joined(separator: ", ")
        } else {
            attendees = arguments["attendees"] as? String ?? ""
        }
        let invite = EventInvite(
            account: account, title: title, start: start, end: end, timeZone: zone.identifier,
            attendees: attendees, addMeet: arguments["add_meet"] as? Bool ?? true, notes: arguments["description"] as? String ?? ""
        )
        guard !invite.guestEmails.isEmpty || attendees.isEmpty else {
            throw RPCError.invalidParams("Couldn't read any addresses in `attendees`.")
        }
        openURL(NookURL.event(invite).url)
        if let scopes = grantedScopes(account), !scopes.contains(GoogleOAuth.calendarEventsScope) {
            return [
                "status": """
                The invite is open in Nook, but \(account) hasn't allowed Nook to add calendar events yet, so it can't be sent. \
                Tell the user: in the invite (or Nook → Settings → Accounts), click Sign in again, choose \(account) and tick the Calendar boxes on Google's screen, then press Send Invite. Nothing has been sent.
                """,
                "needs_sign_in": true,
                "account": account,
            ]
        }
        return [
            "status": "The invite is open in Nook for the user to review. Nothing is on the calendar and no one has been emailed: that happens only when the user presses Send Invite.",
            "account": account,
            "title": title,
            "start": EventInvite.string(start, in: zone),
            "end": EventInvite.string(end, in: zone),
            "time_zone": zone.identifier,
            "attendees": invite.guestEmails,
            "google_meet": invite.addMeet,
        ]
    }

    static let eventTool: [String: Any] = [
        "name": "create_event",
        "title": "Prepare a calendar invite",
        "description": """
        Prepares a Google Calendar invite and opens it in Nook for the user to review and send. Never sends: the event \
        is created, and guests emailed, only when the user presses Send Invite in Nook. Adds a Google Meet link by default.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "account": ["type": "string", "description": "Whose calendar the event goes on, and who it's from."],
                "title": ["type": "string"],
                "start": ["type": "string", "description": "Like 2026-11-18T19:00, in time_zone."],
                "end": ["type": "string", "description": "Like 2026-11-18T19:30, in time_zone."],
                "time_zone": ["type": "string", "description": "IANA name, such as Asia/Kolkata. Defaults to this Mac's."],
                "attendees": ["type": "array", "items": ["type": "string"], "description": "Guest email addresses."],
                "add_meet": ["type": "boolean", "description": "Add a Google Meet link. Defaults to true."],
                "description": ["type": "string", "description": "Notes shown on the event."],
            ],
            "required": ["account", "title", "start", "end"],
        ],
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true],
    ]
}

/// list_events: read-only, the account's calendar for a time range, with guests and their answers.
extension MCPServer {
    func listEvents(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let account = arguments["account"] as? String, repo.accounts().contains(where: { $0.email == account }) else {
            throw RPCError.invalidParams("`account` must be one of Nook's accounts: \(repo.accounts().map(\.email).joined(separator: ", ")).")
        }
        let zone = (arguments["time_zone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
        guard let from = (arguments["from"] as? String).flatMap({ EventInvite.date($0, in: zone) ?? Self.day($0, in: zone) }),
              let to = (arguments["to"] as? String).flatMap({ EventInvite.date($0, in: zone) ?? Self.day($0, in: zone) }), to > from else {
            throw RPCError.invalidParams("`from` and `to` are required, like 2026-11-18 or 2026-11-18T19:00, with `to` after `from`.")
        }
        let calendar = try makeCalendar(account)
        let events = try wait { try await calendar.events(from: from, to: to) }
        return ["account": account, "count": events.count, "events": events.sorted { $0.start < $1.start }.map { event -> [String: Any] in
            [
                "title": event.title,
                "start": EventInvite.string(event.start, in: zone),
                "end": EventInvite.string(event.end, in: zone),
                "calendar": event.calendarName,
                "meet_link": event.joinURL?.absoluteString ?? NSNull(),
                "link": event.link?.absoluteString ?? NSNull(),
                "organizer": event.organizer?.email ?? NSNull(),
                "guests": event.guests.map { ["email": $0.email, "response": $0.response?.rawValue ?? "needsAction"] },
            ]
        }]
    }

    private static func day(_ text: String, in zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static let listEventsTool: [String: Any] = [
        "name": "list_events",
        "title": "Read a calendar",
        "description": "Events on an account's Google Calendar between two times, read-only: title, times, Meet link, organizer, and each guest's answer.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "account": ["type": "string"],
                "from": ["type": "string", "description": "Like 2026-11-18 or 2026-11-18T09:00, in time_zone."],
                "to": ["type": "string", "description": "Like 2026-11-19, in time_zone."],
                "time_zone": ["type": "string", "description": "IANA name. Defaults to this Mac's."],
            ],
            "required": ["account", "from", "to"],
        ],
        "annotations": ["readOnlyHint": true, "openWorldHint": true],
    ]
}
