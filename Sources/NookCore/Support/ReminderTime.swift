import Foundation

/// A time for a reminder, as the picker offers it.
public struct ReminderOption: Hashable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var date: Date

    public init(title: String, date: Date) {
        self.title = title
        self.date = date
    }
}

/// Reminder times: the usual choices, and whatever you type ("tomorrow 3pm", "2d", "fri", "dec 5").
public enum ReminderTime {
    /// Mornings start at 8, so "tomorrow" means the start of the day, not this time tomorrow.
    public static let morningHour = 8

    /// Later today, tomorrow morning, the weekend, next week and next month. Choices that make no sense right now
    /// (later today, late in the evening; this weekend, on the weekend) are left out.
    public static func presets(now: Date, calendar: Calendar = .current) -> [ReminderOption] {
        var options: [ReminderOption] = []
        if let later = laterToday(now: now, calendar: calendar) {
            options.append(ReminderOption(title: "Later today", date: later))
        }
        if let tomorrow = morning(daysFrom: 1, now: now, calendar: calendar) {
            options.append(ReminderOption(title: "Tomorrow", date: tomorrow))
        }
        if !calendar.isDateInWeekend(now), let saturday = next(weekday: 7, now: now, calendar: calendar),
           calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: saturday).day ?? 0 > 1 {
            options.append(ReminderOption(title: "This weekend", date: saturday))
        }
        if let monday = next(weekday: 2, now: now, calendar: calendar) {
            options.append(ReminderOption(title: "Next week", date: monday))
        }
        if let month = calendar.date(byAdding: .month, value: 1, to: now).flatMap({ atMorning($0, calendar: calendar) }) {
            options.append(ReminderOption(title: "Next month", date: month))
        }
        return options
    }

    /// How long to wait for a reply before a follow-up reminder goes off.
    public static let followUpChoices: [(title: String, after: TimeInterval)] = [
        ("1 day", 86_400), ("2 days", 2 * 86_400), ("3 days", 3 * 86_400), ("1 week", 7 * 86_400),
    ]

    /// Three hours from now, on the hour. Only offered when that's still a reasonable hour today.
    static func laterToday(now: Date, calendar: Calendar) -> Date? {
        guard let inThree = calendar.date(byAdding: .hour, value: 3, to: now),
              let hour = calendar.dateInterval(of: .hour, for: inThree)?.end else { return nil }
        let rounded = calendar.component(.minute, from: inThree) == 0 ? inThree : hour
        guard calendar.isDate(rounded, inSameDayAs: now), calendar.component(.hour, from: rounded) <= 21 else { return nil }
        return rounded
    }

    static func morning(daysFrom days: Int, now: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)).flatMap { atMorning($0, calendar: calendar) }
    }

    static func atMorning(_ date: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: date)
    }

    /// The next given weekday (1 is Sunday) after today, in the morning.
    static func next(weekday: Int, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.component(.weekday, from: now)
        var days = (weekday - today + 7) % 7
        if days == 0 { days = 7 }
        return morning(daysFrom: days, now: now, calendar: calendar)
    }

    // MARK: Typed times

    /// Reads a typed time. Returns nil unless it's understood and in the future.
    ///
    /// Understands "2h", "30 min", "in 3 days", "1w", weekdays ("fri", "monday"), "tomorrow", "tonight",
    /// "weekend", "next week", "next month", and dates and times in plain English ("dec 5", "tomorrow at 3pm").
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty else { return nil }
        if let relative = relative(input, now: now, calendar: calendar) { return relative }
        if let keyword = keyword(input, now: now, calendar: calendar) { return keyword }
        if let weekday = weekdayNumber(input) { return next(weekday: weekday, now: now, calendar: calendar) }
        return detected(input, now: now, calendar: calendar)
    }

    private static let units: [(names: [String], component: Calendar.Component, seconds: Int)] = [
        (["m", "min", "mins", "minute", "minutes"], .minute, 60),
        (["h", "hr", "hrs", "hour", "hours"], .hour, 3600),
        (["d", "day", "days"], .day, 86_400),
        (["w", "wk", "wks", "week", "weeks"], .weekOfYear, 7 * 86_400),
        (["mo", "mos", "month", "months"], .month, 30 * 86_400),
    ]

    /// "2h", "in 3 days", "30 min". Minutes and hours count from now; days and longer land in the morning.
    private static func relative(_ input: String, now: Date, calendar: Calendar) -> Date? {
        var text = Substring(input)
        if text.hasPrefix("in ") { text = text.dropFirst(3) }
        let digits = text.prefix { $0.isNumber }
        guard let amount = Int(digits), amount > 0, amount < 1000 else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard let match = units.first(where: { $0.names.contains(unit) }),
              let date = calendar.date(byAdding: match.component, value: amount, to: now) else { return nil }
        if match.component == .minute || match.component == .hour { return date }
        return atMorning(date, calendar: calendar)
    }

    private static func keyword(_ input: String, now: Date, calendar: Calendar) -> Date? {
        switch input {
        case "later", "later today": return laterToday(now: now, calendar: calendar)
        case "tomorrow", "tmr", "tmrw": return morning(daysFrom: 1, now: now, calendar: calendar)
        case "tonight", "this evening", "evening":
            let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now)
            return evening.flatMap { $0 > now ? $0 : nil }
        case "weekend", "this weekend", "sat", "saturday": return next(weekday: 7, now: now, calendar: calendar)
        case "next week": return next(weekday: 2, now: now, calendar: calendar)
        case "next month": return calendar.date(byAdding: .month, value: 1, to: now).flatMap { atMorning($0, calendar: calendar) }
        default: return nil
        }
    }

    private static func weekdayNumber(_ input: String) -> Int? {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let full = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let extra = ["tues": 3, "weds": 4, "thur": 5, "thurs": 5]
        if let index = names.firstIndex(of: input) ?? full.firstIndex(of: input) { return index + 1 }
        return extra[input]
    }

    /// Anything else, through the system's date detector. A date without a time means the morning.
    private static func detected(_ input: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = detector.firstMatch(in: input, range: range), var date = match.date,
              match.range.length * 2 >= range.length else { return nil }
        // "fri 3" can come back as the 3rd of the month. A day you named has to be the day you get.
        if let named = namedWeekday(input), calendar.component(.weekday, from: date) != named { return nil }
        if !mentionsTime(input), let morning = atMorning(date, calendar: calendar) { date = morning }
        // "3pm" after 3pm means tomorrow.
        if date <= now, !mentionsDay(input), let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) { date = tomorrow }
        return date > now ? date : nil
    }

    private static func namedWeekday(_ input: String) -> Int? {
        for word in input.split(whereSeparator: { !$0.isLetter }) {
            if let day = weekdayNumber(String(word)) { return day }
        }
        return nil
    }

    private static func mentionsTime(_ input: String) -> Bool {
        input.range(of: #"\d\s*(am|pm|a\.m\.|p\.m\.)|\d:\d|\bnoon\b|\bmidnight\b|\bmorning\b|\bevening\b|\bnight\b|\bafternoon\b"#, options: .regularExpression) != nil
    }

    private static func mentionsDay(_ input: String) -> Bool {
        input.range(of: #"\d{1,2}[/.-]\d{1,2}|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|mon|tue|wed|thu|fri|sat|sun|tomorrow|today"#, options: .regularExpression) != nil
    }

    // MARK: Showing times

    /// "Today, 6:00 PM", "Tomorrow, 8:00 AM", "Sat, 8:00 AM" within the week, "Mar 3, 8:00 AM" after that.
    public static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day(date, now: now, calendar: calendar)), \(time)"
    }

    /// Just enough for a list row: the time if it's today, otherwise the day.
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return day(date, now: now, calendar: calendar)
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
