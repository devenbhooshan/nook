import NookCore
import SwiftUI

// MARK: Day view (g c)

/// One day of your calendar, in place of the mail list: all-day events on top, then the hours.
struct CalendarDayView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: CalendarModel

    private static let hourHeight: CGFloat = 52
    private static let gutter: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            VStack(alignment: .leading, spacing: 14) {
                header
                CalendarNotices(model: model)
                if !day.allDay.isEmpty { allDayRow }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: Theme.readerWidth)
            .padding(.horizontal, 32)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            Divider().opacity(0.6)
            hours
        }
    }

    private var day: (allDay: [CalendarEvent], timed: [CalendarEvent]) {
        model.events(on: store.calendarDay)
    }

    private var toolbar: some View {
        TopBar {
            Button {
                store.closeCalendar()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(store.mailbox.title).font(.system(size: 13, weight: .medium))
                    KeyCap("esc")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.quiet)
        } trailing: {
            if model.isLoading { ProgressView().controlSize(.small).padding(.trailing, 4) }
            IconButton(systemImage: "chevron.left", title: "Previous day", shortcut: "←") { store.moveCalendarDay(by: -1) }
            Button("Today") { store.showCalendarToday() }
                .buttonStyle(.quiet)
                .font(.system(size: 13, weight: .medium))
                .help("Today (T)")
            IconButton(systemImage: "chevron.right", title: "Next day", shortcut: "→", tooltipAlignment: .trailing) { store.moveCalendarDay(by: 1) }
            IconButton(systemImage: "arrow.up.right.square", title: "Open Google Calendar", tooltipAlignment: .trailing) {
                NSWorkspace.shared.open(Self.googleCalendarURL(for: store.calendarDay))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(store.calendarDay.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 26, weight: .bold))
                Text(store.calendarDay.formatted(.dateTime.day().month(.wide).year()))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                if let relative = Self.relativeName(store.calendarDay) {
                    Text(relative)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
            weekStrip
        }
    }

    /// The week around the day, to jump to a nearby day with one click.
    private var weekStrip: some View {
        let calendar = Calendar.current
        let week = calendar.dateInterval(of: .weekOfYear, for: store.calendarDay)?.start ?? store.calendarDay
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        return HStack(spacing: 6) {
            ForEach(days, id: \.self) { date in
                let selected = calendar.isDate(date, inSameDayAs: store.calendarDay)
                let isToday = calendar.isDateInToday(date)
                let busy = !model.events(on: date).timed.isEmpty
                Button {
                    store.moveCalendarDay(by: calendar.dateComponents([.day], from: store.calendarDay, to: date).day ?? 0)
                } label: {
                    VStack(spacing: 3) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                        Text(date.formatted(.dateTime.day()))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected ? .white : isToday ? Theme.accent : .primary)
                        Circle()
                            .fill(selected ? .white.opacity(0.8) : Theme.accent.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .opacity(busy ? 1 : 0)
                    }
                    .frame(width: 46, height: 52)
                    .background(selected ? Theme.accent : Color.primary.opacity(isToday ? 0.06 : 0.025),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
    }

    private var allDayRow: some View {
        HStack(spacing: 6) {
            Text("All day")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutter - 8, alignment: .leading)
            ForEach(day.allDay) { event in
                Button { open(event) } label: {
                    Text(event.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(EventColor.of(event).opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickable()
                .help(event.calendarName)
            }
            Spacer(minLength: 0)
        }
    }

    private var hours: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    grid
                    GeometryReader { geometry in
                        let width = geometry.size.width - Self.gutter - 8
                        let slots = CalendarLayout.slots(for: day.timed.map { ($0.start, $0.end) })
                        ForEach(Array(day.timed.enumerated()), id: \.element.id) { index, event in
                            let slot = slots[index]
                            let frame = self.frame(for: event, slot: slot, width: width)
                            EventBlock(event: event, height: frame.height) { open(event) }
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                        }
                        if Calendar.current.isDateInToday(store.calendarDay) {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                nowLine(at: context.date, width: geometry.size.width)
                            }
                        }
                    }
                }
                .frame(height: Self.hourHeight * 24)
                .frame(maxWidth: Theme.readerWidth)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: store.calendarDay) { scroll(proxy) }
            .onChange(of: model.loaded) { scroll(proxy) }
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(Self.hourLabel(hour))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: Self.gutter - 8, alignment: .trailing)
                        .offset(y: -6)
                        .opacity(hour == 0 ? 0 : 1)
                    Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                }
                .frame(height: Self.hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }

    private func nowLine(at date: Date, width: CGFloat) -> some View {
        let y = minutes(since: store.calendarDay, to: date) / 60 * Self.hourHeight
        return HStack(spacing: 0) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .frame(width: width - Self.gutter + 4)
        .offset(x: Self.gutter - 4, y: y - 4)
        .allowsHitTesting(false)
    }

    private func frame(for event: CalendarEvent, slot: CalendarLayout.Slot, width: CGFloat) -> CGRect {
        let dayStart = store.calendarDay
        let top = max(0, minutes(since: dayStart, to: event.start))
        let bottom = min(24 * 60, minutes(since: dayStart, to: event.end))
        let height = max((bottom - top) / 60 * Self.hourHeight, 20)
        let columnWidth = width / CGFloat(slot.columns)
        return CGRect(
            x: Self.gutter + columnWidth * CGFloat(slot.column), y: top / 60 * Self.hourHeight + 1,
            width: columnWidth - 3, height: height - 2
        )
    }

    private func minutes(since start: Date, to date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60)
    }

    /// Opens on the first event (or now, today), with an hour of room above it.
    private func scroll(_ proxy: ScrollViewProxy) {
        let calendar = Calendar.current
        var hour = day.timed.first.map { calendar.component(.hour, from: max($0.start, store.calendarDay)) } ?? 8
        if calendar.isDateInToday(store.calendarDay) { hour = min(hour, calendar.component(.hour, from: Date())) }
        proxy.scrollTo(max(0, min(hour - 1, 16)), anchor: .top)
    }

    private func open(_ event: CalendarEvent) {
        if let link = event.link { NSWorkspace.shared.open(link) }
    }

    static func hourLabel(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())?.formatted(.dateTime.hour()) ?? "\(hour)"
    }

    static func relativeName(_ day: Date) -> String? {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return nil
    }

    static func googleCalendarURL(for day: Date) -> URL {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return URL(string: "https://calendar.google.com/calendar/r/day/\(c.year ?? 2026)/\(c.month ?? 1)/\(c.day ?? 1)")!
    }
}

/// An event in the day view's hour grid.
private struct EventBlock: View {
    let event: CalendarEvent
    let height: CGFloat
    let open: () -> Void

    var body: some View {
        let color = EventColor.of(event)
        Button(action: open) {
            HStack(spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .strikethrough(event.isDeclined)
                        .lineLimit(height > 44 ? 2 : 1)
                    if height > 32 {
                        Text(EventText.timeRange(event) + (event.location.map { " · \($0)" } ?? ""))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if height > 60, let join = event.joinURL, !event.isDeclined {
                        JoinButton(url: join, prominent: false).padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, height > 28 ? 4 : 1)
                Spacer(minLength: 0)
                // Too short for the Join button: a video icon at the end does the same.
                if height <= 60, let join = event.joinURL, !event.isDeclined {
                    Button { NSWorkspace.shared.open(join) } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, height: min(height, 22))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .help("Join (\(join.host ?? "call"))")
                    .padding(.trailing, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color.opacity(event.isDeclined ? 0.07 : 0.16))
            .overlay {
                if event.response == .needsAction {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(event.isDeclined ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .help(EventText.help(event))
    }
}

// MARK: Quick agenda (t)

/// Today and tomorrow at a glance, over whatever's on screen.
struct AgendaView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: CalendarModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { store.showAgenda = false }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Agenda").font(.system(size: 17, weight: .semibold))
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

                CalendarNotices(model: model).padding(.horizontal, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .leading, spacing: 14) {
                                section("Today", day: context.date, now: context.date)
                                if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: context.date) {
                                    section("Tomorrow", day: tomorrow, now: context.date)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.6)
                HStack(spacing: 10) {
                    Button {
                        store.openCalendar()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                            Text("Open calendar")
                            KeyCap("G")
                            KeyCap("C")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.quiet)
                    .clickable()
                    Spacer()
                    Text("Press any key to close").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .frame(width: 460)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            .padding(.top, 70)
        }
    }

    @ViewBuilder
    private func section(_ title: String, day: Date, now: Date) -> some View {
        let events = model.events(on: day)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            if events.allDay.isEmpty && events.timed.isEmpty, !model.loaded || model.access.values.contains(.available) {
                Text(model.loaded ? "Nothing on your calendar" : "Loading…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            ForEach(events.allDay) { event in AgendaRow(event: event, now: now) }
            ForEach(events.timed) { event in AgendaRow(event: event, now: now) }
        }
    }
}

private struct AgendaRow: View {
    let event: CalendarEvent
    let now: Date
    @State private var hovering = false

    var body: some View {
        let isPast = !event.isAllDay && event.end <= now
        let isNow = !event.isAllDay && event.start <= now && event.end > now
        let soon = !event.isAllDay && event.start > now && event.start.timeIntervalSince(now) <= 15 * 60
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(EventColor.of(event)).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(event.isDeclined)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(event.isAllDay ? "All day" : EventText.timeRange(event))
                    if isNow {
                        Text("Now").fontWeight(.semibold).foregroundStyle(Theme.accent)
                    } else if soon {
                        Text("in \(max(1, Int(event.start.timeIntervalSince(now) / 60))) min").fontWeight(.semibold).foregroundStyle(Theme.accent)
                    }
                    if let location = event.location, event.joinURL == nil || !location.hasPrefix("http") {
                        Text("· \(location)").lineLimit(1)
                    }
                    if event.response == .needsAction { Text("· Not answered") }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let join = event.joinURL, !isPast, !event.isDeclined {
                JoinButton(url: join, prominent: isNow || soon)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isPast || event.isDeclined ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let link = event.link { NSWorkspace.shared.open(link) } }
        .clickable()
        .help(EventText.help(event))
    }
}

// MARK: Shared pieces

/// Joins the call. Prominent when it's time.
private struct JoinButton: View {
    let url: URL
    let prominent: Bool

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill").font(.system(size: 9.5))
                Text("Join").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? .white : Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(prominent ? Theme.accent : Theme.accent.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickable()
        .help(url.host ?? "Join the call")
    }
}

/// Signing in again for the calendar, or turning the Calendar API on.
struct CalendarNotices: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: CalendarModel

    var body: some View {
        if let link = model.apiDisabledLink {
            notice("Your calendar needs the Google Calendar API turned on in your Google Cloud project.", action: "Turn On…") {
                NSWorkspace.shared.open(link)
                model.invalidate()
            }
        } else if let account = model.needsPermission.first {
            // One account at a time, straight to Google: the notice moves on to the next once this one is done.
            let others = model.needsPermission.count - 1
            notice(
                others == 0 ? "Sign in again to show the calendar for \(account)."
                    : "Sign in again to show the calendar for \(account) and \(others) more account\(others == 1 ? "" : "s").",
                action: store.isSigningIn ? "Waiting for Google…" : "Sign in \(account)"
            ) {
                if store.hasGoogleClient { store.addAccount(hint: account) } else { store.openSettings(tab: .accounts) }
            }
        } else if model.loaded, store.accounts.isEmpty {
            notice("Add a Google account to see your calendar.", action: nil) {}
        }
    }

    private func notice(_ message: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(Theme.accent)
            Text(message).font(.system(size: 12.5))
            Spacer(minLength: 8)
            if let action { Button(action, action: perform).controlSize(.small) }
        }
        .padding(10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 6)
    }
}

enum EventColor {
    static func of(_ event: CalendarEvent) -> Color {
        guard let hex = event.color?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), hex.count == 6,
              let value = UInt32(hex, radix: 16) else { return Theme.accent }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255
        )
    }
}

enum EventText {
    static func timeRange(_ event: CalendarEvent) -> String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    static func help(_ event: CalendarEvent) -> String {
        var parts = [event.title, event.isAllDay ? "All day" : timeRange(event), event.calendarName]
        if let location = event.location { parts.append(location) }
        switch event.response {
        case .declined: parts.append("You declined")
        case .tentative: parts.append("You said maybe")
        case .needsAction: parts.append("You haven't answered")
        default: break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
