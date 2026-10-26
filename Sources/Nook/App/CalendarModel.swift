import Foundation
import NookCore

/// Your schedule across accounts, fetched from Google Calendar a few weeks at a time and kept in memory,
/// so the agenda and the day view open instantly and refresh behind the scenes.
@MainActor
final class CalendarModel: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    /// What each account allowed, from the last fetch.
    @Published private(set) var access: [String: CalendarAccess] = [:]
    /// Whether a fetch has finished at least once, so "nothing today" isn't shown before anything arrived.
    @Published private(set) var loaded = false
    @Published private(set) var isLoading = false

    /// One calendar per signed-in account.
    var makeSources: () -> [String: CalendarSource] = { [:] }

    private var range: (start: Date, end: Date)?
    private var fetchedAt: Date?
    private var generation = 0

    /// How long fetched events count as current.
    private static let freshFor: TimeInterval = 5 * 60

    /// Fetches the weeks around `day` unless they're already here and recent.
    func refresh(around day: Date = Date(), force: Bool = false) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: day)
        if !force, let range, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.freshFor,
           range.start <= today, let weekOut = calendar.date(byAdding: .day, value: 7, to: today), range.end >= weekOut {
            return
        }
        guard let start = calendar.date(byAdding: .day, value: -7, to: today),
              let end = calendar.date(byAdding: .day, value: 28, to: today) else { return }
        let sources = makeSources()
        generation += 1
        let current = generation
        isLoading = true
        Task {
            let result = await CalendarSync.run(sources: sources, from: start, to: end)
            // A newer fetch (another day, say) has started; its answer wins.
            guard current == generation else { return }
            // Accounts that couldn't be reached keep what they had.
            let kept = events.filter { result.failed.contains($0.account) }
            events = CalendarSync.merged(result.events + kept)
            var access = result.access
            for account in result.failed { access[account] = self.access[account] }
            self.access = access
            range = (start, end)
            fetchedAt = Date()
            loaded = true
            isLoading = false
        }
    }

    /// After signing in again or adding an account: the next look fetches afresh.
    func invalidate() {
        fetchedAt = nil
    }

    /// The day's all-day events and timed events, in order.
    func events(on day: Date) -> (allDay: [CalendarEvent], timed: [CalendarEvent]) {
        let start = Calendar.current.startOfDay(for: day)
        let onDay = events.filter { $0.overlaps(dayStart: start) }
        return (onDay.filter(\.isAllDay), onDay.filter { !$0.isAllDay })
    }

    /// Accounts that have to sign in again before their calendar shows.
    var needsPermission: [String] {
        access.filter { $0.value == .needsPermission }.map(\.key).sorted()
    }

    /// The Calendar API is off in the Google Cloud project; the link turns it on.
    var apiDisabledLink: URL? {
        for value in access.values {
            if case .apiDisabled(let link) = value {
                return link ?? URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
            }
        }
        return nil
    }
}
