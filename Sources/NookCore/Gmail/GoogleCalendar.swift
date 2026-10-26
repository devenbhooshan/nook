import Foundation

/// One event on a calendar, as Nook shows it.
public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public enum Response: String, Sendable {
        case accepted, tentative, declined, needsAction
    }

    /// `account/calendar/event`: the same event can be on several calendars.
    public var id: String
    /// Shared by every copy of a meeting, across calendars and accounts.
    public var iCalUID: String?
    public var account: String
    public var calendarName: String
    public var title: String
    public var start: Date
    /// Exclusive. For an all-day event, midnight after its last day.
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    /// Meet, Zoom, Teams or Webex.
    public var joinURL: URL?
    /// The event in Google Calendar.
    public var link: URL?
    /// The calendar's color, "#rrggbb".
    public var color: String?
    /// Your answer, when you're invited rather than the organizer.
    public var response: Response?

    public init(
        id: String, iCalUID: String? = nil, account: String, calendarName: String = "", title: String, start: Date, end: Date,
        isAllDay: Bool = false, location: String? = nil, joinURL: URL? = nil, link: URL? = nil, color: String? = nil,
        response: Response? = nil
    ) {
        self.id = id
        self.iCalUID = iCalUID
        self.account = account
        self.calendarName = calendarName
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.joinURL = joinURL
        self.link = link
        self.color = color
        self.response = response
    }

    public var isDeclined: Bool { response == .declined }

    /// Whether any part of it falls on the day starting at `dayStart`.
    public func overlaps(dayStart: Date, calendar: Calendar = .current) -> Bool {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return start < dayEnd && end > dayStart
    }
}

/// Whether Nook can read an account's calendar.
public enum CalendarAccess: Equatable, Sendable {
    case available
    /// Signed in before Nook asked for the calendar. Signing in again grants it.
    case needsPermission
    /// The Calendar API is turned off in the Google Cloud project behind the OAuth client. The link turns it on.
    case apiDisabled(URL?)
}

/// Where events come from. The app uses Google Calendar; tests and the demo use fakes.
public protocol CalendarSource: Sendable {
    /// Events overlapping `start..<end` on every calendar the account shows.
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
}

/// Read-only Google Calendar: the calendars you have switched on in Google Calendar, and their events.
public struct GoogleCalendar: CalendarSource {
    private let account: String
    private let transport: HTTPTransport
    private let tokens: AccessTokenProvider
    private let baseURL: URL

    public init(
        account: String, transport: HTTPTransport = URLSession.shared, tokens: AccessTokenProvider,
        baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3/")!
    ) {
        self.account = account
        self.transport = transport
        self.tokens = tokens
        self.baseURL = baseURL
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let list = try JSONDecoder().decode(CalendarList.self, from: try await get("users/me/calendarList", query: []))
        // The calendars ticked in Google Calendar's sidebar; your own calendar always.
        let shown = (list.items ?? []).filter { $0.primary == true || ($0.selected == true && $0.hidden != true) }
        var events: [CalendarEvent] = []
        for calendar in shown {
            events += try await self.events(in: calendar, from: start, to: end)
        }
        return events
    }

    private func events(in calendar: CalendarList.Entry, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let formatter = ISO8601DateFormatter()
        var events: [CalendarEvent] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "timeMin", value: formatter.string(from: start)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: end)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            // Calendar IDs can hold "#" and "/" (holiday calendars, say), so they're encoded as one path segment.
            let id = calendar.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~@"))) ?? calendar.id
            let path = "calendars/\(id)/events"
            let page = try JSONDecoder().decode(EventPage.self, from: try await get(path, query: query))
            events += (page.items ?? []).compactMap { Self.event(from: $0, calendar: calendar, account: account) }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return events
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        // `path` is already encoded.
        var components = URLComponents(string: baseURL.absoluteString + path)!
        if !query.isEmpty { components.queryItems = query }
        var refreshed = false
        while true {
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(try await tokens.accessToken(forceRefresh: refreshed))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401 where !refreshed:
                refreshed = true
            default:
                // Google's APIs share an error format: the People API's reading of it applies here too.
                throw GooglePeople.error(status: response.statusCode, data: data)
            }
        }
    }

    // MARK: Decoding

    struct CalendarList: Decodable {
        struct Entry: Decodable {
            var id: String
            var summary: String?
            var summaryOverride: String?
            var backgroundColor: String?
            var selected: Bool?
            var hidden: Bool?
            var primary: Bool?
        }
        var items: [Entry]?
    }

    struct EventPage: Decodable {
        var items: [Event]?
        var nextPageToken: String?
    }

    struct Event: Decodable {
        struct Time: Decodable {
            var date: String?
            var dateTime: String?
        }
        struct Attendee: Decodable {
            var isSelf: Bool?
            var responseStatus: String?
            enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
        }
        struct Conference: Decodable {
            struct EntryPoint: Decodable {
                var entryPointType: String?
                var uri: String?
            }
            var entryPoints: [EntryPoint]?
        }
        var id: String
        var iCalUID: String?
        var status: String?
        var summary: String?
        var start: Time?
        var end: Time?
        var location: String?
        var description: String?
        var hangoutLink: String?
        var conferenceData: Conference?
        var htmlLink: String?
        var attendees: [Attendee]?
        var eventType: String?
    }

    static func event(from event: Event, calendar: CalendarList.Entry, account: String) -> CalendarEvent? {
        // Cancelled occurrences, and the "working from home/office" markers, aren't things to attend.
        guard event.status != "cancelled", event.eventType != "workingLocation",
              let startTime = event.start, let (start, allDay) = date(startTime), let endTime = event.end, let (end, _) = date(endTime)
        else { return nil }
        let video = event.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        let join = [event.hangoutLink, video].compactMap { $0.flatMap(URL.init(string:)) }.first
            ?? meetingLink(in: [event.location, event.description].compactMap { $0 }.joined(separator: " "))
        return CalendarEvent(
            id: "\(account)/\(calendar.id)/\(event.id)", iCalUID: event.iCalUID, account: account,
            calendarName: calendar.summaryOverride ?? calendar.summary ?? calendar.id,
            title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(No title)",
            start: start, end: max(end, start), isAllDay: allDay,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            joinURL: join, link: event.htmlLink.flatMap(URL.init(string:)), color: calendar.backgroundColor,
            response: event.attendees?.first { $0.isSelf == true }?.responseStatus.flatMap(CalendarEvent.Response.init(rawValue:))
        )
    }

    /// A timed event's instant, or an all-day event's local midnight.
    static func date(_ time: Event.Time) -> (Date, Bool)? {
        if let dateTime = time.dateTime {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateTime) { return (date, false) }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: dateTime).map { ($0, false) }
        }
        if let day = time.date {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            return (date, true)
        }
        return nil
    }

    /// A video call link pasted into the location or description, for meetings set up outside Google Meet.
    static func meetingLink(in text: String) -> URL? {
        let pattern = #"https://[A-Za-z0-9.-]*(zoom\.us|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|webex\.com|whereby\.com|around\.co)/[^\s<>"')]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Gathers every account's events for a stretch of days.
public enum CalendarSync {
    public struct Result: Sendable, Equatable {
        public var events: [CalendarEvent] = []
        /// What each account allowed. Accounts that failed for other reasons (offline, say) are left out.
        public var access: [String: CalendarAccess] = [:]
        /// Accounts whose events couldn't be fetched this time, so their earlier events should be kept.
        public var failed: Set<String> = []
    }

    public static func run(sources: [String: CalendarSource], from start: Date, to end: Date) async -> Result {
        var result = Result()
        var events: [CalendarEvent] = []
        await withTaskGroup(of: (String, Result).self) { group in
            for (account, source) in sources {
                group.addTask {
                    var one = Result()
                    do {
                        one.events = try await source.events(from: start, to: end)
                        one.access[account] = .available
                    } catch PeopleError.needsPermission {
                        one.access[account] = .needsPermission
                    } catch PeopleError.apiDisabled(let link) {
                        one.access[account] = .apiDisabled(link)
                    } catch {
                        one.failed.insert(account)
                    }
                    return (account, one)
                }
            }
            for await (_, one) in group {
                events += one.events
                result.access.merge(one.access) { $1 }
                result.failed.formUnion(one.failed)
            }
        }
        result.events = merged(events)
        return result
    }

    /// One copy of each meeting, soonest first. A meeting on two of your calendars (your work and personal accounts,
    /// say) shows once, preferring the copy you've answered.
    public static func merged(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var seen: [String: Int] = [:]
        var kept: [CalendarEvent] = []
        for event in events.sorted(by: order) {
            guard let uid = event.iCalUID else {
                kept.append(event)
                continue
            }
            let key = "\(uid)|\(event.start.timeIntervalSince1970)"
            if let index = seen[key] {
                if kept[index].response == nil || kept[index].response == .needsAction, event.response == .accepted { kept[index] = event }
            } else {
                seen[key] = kept.count
                kept.append(event)
            }
        }
        return kept.sorted(by: order)
    }

    static func order(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end > b.end }
        return a.id < b.id
    }
}

/// Places a day's timed events side by side where they overlap, the way calendar apps do.
public enum CalendarLayout {
    public struct Slot: Equatable, Sendable {
        public var column: Int
        public var columns: Int
    }

    /// For each event (in the order given), its column and how many columns its group of overlapping events needs.
    public static func slots(for events: [(start: Date, end: Date)]) -> [Slot] {
        let order = events.indices.sorted { events[$0].start == events[$1].start ? events[$0].end > events[$1].end : events[$0].start < events[$1].start }
        var slots = Array(repeating: Slot(column: 0, columns: 1), count: events.count)
        var group: [Int] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast

        func closeGroup() {
            for index in group { slots[index].columns = max(columnEnds.count, 1) }
            group = []
            columnEnds = []
        }

        for index in order {
            let event = events[index]
            // A very short event still takes up a little room, so it can't hide under the next one.
            let end = max(event.end, event.start.addingTimeInterval(15 * 60))
            if event.start >= groupEnd { closeGroup() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                slots[index].column = free
                columnEnds[free] = end
            } else {
                slots[index].column = columnEnds.count
                columnEnds.append(end)
            }
            group.append(index)
            groupEnd = max(groupEnd, end)
        }
        closeGroup()
        return slots
    }
}
