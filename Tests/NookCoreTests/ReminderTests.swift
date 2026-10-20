import Foundation
import Testing
@testable import NookCore

@Suite("Reminders")
struct ReminderTests {
    private let me = "me@example.com"
    /// The fixtures' "now".
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func inbox(_ repo: MailRepository) -> [String] {
        repo.threads(ThreadQuery(account: me)).map(\.threadId)
    }

    private func reminders(_ repo: MailRepository) -> [String] {
        repo.threads(ThreadQuery(account: me, mailbox: .reminders)).map(\.threadId)
    }

    @Test func remindersWaitInTheirListSoonestFirstAndLeaveTheInboxAlone() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: me, name: "Me")
        try repo.upsert([
            MailMessage.fixture(id: "a", minutesAgo: 10),
            MailMessage.fixture(id: "b", minutesAgo: 20),
            MailMessage.fixture(id: "c", minutesAgo: 30),
        ])
        for (thread, hours) in [("a", 48.0), ("b", 2.0)] {
            try repo.setReminder(Reminder(account: me, threadId: thread, kind: .remind, due: base.addingTimeInterval(hours * 3600)))
        }

        // Setting a reminder doesn't move anything.
        #expect(inbox(repo) == ["a", "b", "c"])
        #expect(reminders(repo) == ["b", "a"])
        let row = try #require(repo.threads(ThreadQuery(account: me)).first)
        #expect(row.reminder?.kind == .remind && row.reminder?.isPending == true)
        #expect(repo.nextReminderDue() == base.addingTimeInterval(2 * 3600))
        #expect(repo.threads(ThreadQuery(account: me, search: SearchQuery.parse("in:reminders"))).map(\.threadId).sorted() == ["a", "b"])
        // New mail in the conversation doesn't cancel it: you asked to be reminded.
        try repo.upsert([MailMessage.fixture(id: "a2", thread: "a", minutesAgo: 1)])
        #expect(try repo.settleReminders() == 0)
    }

    @Test func aReminderThatGoesOffPutsItsConversationOnTop() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: me, name: "Me")
        try repo.upsert([MailMessage.fixture(id: "old", minutesAgo: 600), MailMessage.fixture(id: "new", minutesAgo: 1)])
        try repo.setReminder(Reminder(account: me, threadId: "old", kind: .remind, due: base.addingTimeInterval(-60)))
        #expect(inbox(repo) == ["new", "old"])

        let due = repo.dueReminders(at: base)
        #expect(due.map(\.threadId) == ["old"])
        try repo.markReminderWoken(account: me, threadId: "old", at: base)

        #expect(inbox(repo) == ["old", "new"])
        #expect(reminders(repo).isEmpty)
        #expect(repo.dueReminders(at: base).isEmpty)
        #expect(repo.threads(ThreadQuery(account: me)).first?.reminder?.wokeAt == base)

        // Done with it: archiving drops the reminder, and the conversation sorts by its mail again.
        try repo.modifyThread(account: me, threadId: "old", add: [], remove: [SystemLabel.inbox])
        #expect(try repo.settleReminders() == 1)
        try repo.modifyThread(account: me, threadId: "old", add: [SystemLabel.inbox], remove: [])
        #expect(inbox(repo) == ["new", "old"])
    }

    @Test func remindersFromTheSnoozeBuildAreReadAsReminders() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: me, name: "Me")
        try repo.upsert([MailMessage.fixture(id: "t")])
        try repo.db.execute("INSERT INTO reminders(account, thread_id, kind, due) VALUES (?, 't', 'snooze', ?)", [me, base])
        #expect(repo.reminder(account: me, threadId: "t")?.kind == .remind)
        // The app puts these back in the inbox once, so they're handed over once.
        #expect(try repo.takeSnoozeBuildReminders().map(\.threadId) == ["t"])
        #expect(try repo.takeSnoozeBuildReminders().isEmpty)
        #expect(repo.reminder(account: me, threadId: "t")?.kind == .remind)
    }

    @Test func aReplyCancelsAFollowUpButYourOwnMailDoesNot() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: me, name: "Me")
        let sentAt = base.addingTimeInterval(-3600)
        try repo.upsert([MailMessage.fixture(id: "s1", thread: "t", from: me, labels: [SystemLabel.sent], minutesAgo: 60)])
        try repo.setReminder(Reminder(account: me, threadId: "t", kind: .followUp, due: base.addingTimeInterval(86_400), since: sentAt))
        #expect(reminders(repo) == ["t"])

        // Another message of yours (a nudge from your phone) isn't a reply.
        try repo.upsert([MailMessage.fixture(id: "s2", thread: "t", from: me, labels: [SystemLabel.sent], minutesAgo: 30)])
        #expect(try repo.settleReminders() == 0)

        try repo.upsert([MailMessage.fixture(id: "r1", thread: "t", minutesAgo: 5)])
        #expect(try repo.settleReminders() == 1)
        #expect(reminders(repo).isEmpty)
    }

    @Test func removingAReminderReturnsItForUndo() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: me, name: "Me")
        try repo.upsert([MailMessage.fixture(id: "t")])
        let reminder = Reminder(account: me, threadId: "t", kind: .remind, due: base)
        try repo.setReminder(reminder)
        #expect(try repo.removeReminder(account: me, threadId: "t") == reminder)
        #expect(try repo.removeReminder(account: me, threadId: "t") == nil)
        try repo.setReminder(reminder)
        try repo.removeAccount(me)
        #expect(repo.nextReminderDue() == nil)
    }
}

@Suite("Reminder times")
struct ReminderTimeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Wednesday, Oct 21 2026, at the given time, in Los Angeles.
    private func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: hour, minute: minute))!
    }

    private func components(_ date: Date?) -> [Int] {
        guard let date else { return [] }
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return [c.month!, c.day!, c.hour!, c.minute!]
    }

    @Test func offersTheUsualTimes() {
        let presets = ReminderTime.presets(now: wednesday(10, 20), calendar: calendar)
        #expect(presets.map(\.title) == ["Later today", "Tomorrow", "This weekend", "Next week", "Next month"])
        #expect(presets.map { components($0.date) } == [[10, 21, 14, 0], [10, 22, 8, 0], [10, 24, 8, 0], [10, 26, 8, 0], [11, 21, 8, 0]])
        // Late in the evening there's no "later today".
        #expect(ReminderTime.presets(now: wednesday(22), calendar: calendar).first?.title == "Tomorrow")
    }

    @Test func understandsShorthand() {
        let now = wednesday(10, 20)
        func parse(_ text: String) -> [Int] { components(ReminderTime.parse(text, now: now, calendar: calendar)) }
        #expect(parse("2h") == [10, 21, 12, 20])
        #expect(parse("in 30 min") == [10, 21, 10, 50])
        #expect(parse("3d") == [10, 24, 8, 0])
        #expect(parse("1w") == [10, 28, 8, 0])
        #expect(parse("Tomorrow") == [10, 22, 8, 0])
        #expect(parse("fri") == [10, 23, 8, 0])
        #expect(parse("wed") == [10, 28, 8, 0]) // Today is Wednesday: the next one.
        #expect(parse("tonight") == [10, 21, 19, 0])
        #expect(parse("next week") == [10, 26, 8, 0])
        #expect(ReminderTime.parse("whenever", now: now, calendar: calendar) == nil)
        #expect(ReminderTime.parse("0h", now: now, calendar: calendar) == nil)
    }

    @Test func understandsPlainEnglishDates() throws {
        // The system's detector works from the real clock, so these are checked against it.
        let now = Date()
        let tomorrow = try #require(ReminderTime.parse("tomorrow at 3pm", now: now))
        #expect(Calendar.current.isDateInTomorrow(tomorrow))
        #expect(Calendar.current.component(.hour, from: tomorrow) == 15)
        // A named day is kept: "fri 3" isn't the 3rd unless that's a Friday.
        if let fri = ReminderTime.parse("fri 3pm", now: now) {
            #expect(Calendar.current.component(.weekday, from: fri) == 6)
            #expect(Calendar.current.component(.hour, from: fri) == 15)
        }
        if let partial = ReminderTime.parse("fri 3", now: now) {
            #expect(Calendar.current.component(.weekday, from: partial) == 6)
        }
        let date = try #require(ReminderTime.parse("december 5", now: now))
        #expect(Calendar.current.component(.hour, from: date) == ReminderTime.morningHour)
        #expect(date > now)
    }

    @Test func describesTimesRelativeToNow() {
        let now = wednesday(10)
        #expect(ReminderTime.describe(wednesday(18), now: now, calendar: calendar).hasPrefix("Today, "))
        #expect(ReminderTime.describe(wednesday(10).addingTimeInterval(86_400), now: now, calendar: calendar).hasPrefix("Tomorrow, "))
    }

    @Test func hRemindsAndGHGoesToReminders() {
        var interpreter = ShortcutInterpreter()
        let start = Date()
        #expect(interpreter.interpret(characters: "h", keyCode: 4, now: start) == .remind)
        #expect(interpreter.interpret(characters: "g", keyCode: 5, now: start) == nil)
        #expect(interpreter.interpret(characters: "h", keyCode: 4, now: start.addingTimeInterval(0.2)) == .go(.reminders))
    }

    @Test func sendingReportsTheConversation() async throws {
        let transport = StubTransport([.init(200, #"{"id":"m9","threadId":"t9"}"#)])
        let client = GmailClient(transport: transport, tokens: StaticTokens(), rateLimiter: nil)
        #expect(try await client.send(raw: "abc", threadId: nil) == "t9")
    }
}
