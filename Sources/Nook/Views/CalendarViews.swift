import NookCore
import SwiftUI

// MARK: Day view (g c)

/// One day of your calendar, in place of the mail list: all-day events on top, then the hours.
struct CalendarDayView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: CalendarModel
    /// The event whose details are showing.
    @State private var shown: String?

    private static let hourHeight: CGFloat = 52
    private static let gutter: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            switch store.calendarScope {
            case .day: dayBody
            case .week: CalendarWeekView(model: model)
            case .month: CalendarMonthView(model: model)
            }
        }
    }

    private var dayBody: some View {
        VStack(spacing: 0) {
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
            Picker("View", selection: $store.calendarScope) {
                ForEach(CalendarScope.allCases) { scope in Text(scope.title).tag(scope) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Day (D), Week (W), Month (M)")
            .padding(.trailing, 6)
            IconButton(systemImage: "chevron.left", title: "Previous \(unit)", shortcut: "←") { store.moveCalendar(by: -1) }
            Button("Today") { store.showCalendarToday() }
                .buttonStyle(.quiet)
                .font(.system(size: 13, weight: .medium))
                .help("Today (T)")
            IconButton(systemImage: "chevron.right", title: "Next \(unit)", shortcut: "→", tooltipAlignment: .trailing) { store.moveCalendar(by: 1) }
            IconButton(systemImage: "arrow.up.right.square", title: "Open Google Calendar", tooltipAlignment: .trailing) {
                NSWorkspace.shared.open(Self.googleCalendarURL(for: store.calendarDay, scope: store.calendarScope, account: store.scope ?? store.accounts.first?.email))
            }
        }
    }

    private var unit: String { store.calendarScope.rawValue }

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
                .popover(isPresented: showing(event), arrowEdge: .bottom) { EventDetails(event: event) }
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
                                .popover(isPresented: showing(event), arrowEdge: .trailing) { EventDetails(event: event) }
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
        shown = shown == event.id ? nil : event.id
    }

    private func showing(_ event: CalendarEvent) -> Binding<Bool> {
        Binding(get: { shown == event.id }, set: { if !$0, shown == event.id { shown = nil } })
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

    static func googleCalendarURL(for day: Date, scope: CalendarScope = .day, account: String? = nil) -> URL {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        var components = URLComponents(string: "https://calendar.google.com/calendar/r/\(scope.rawValue)/\(c.year ?? 2026)/\(c.month ?? 1)/\(c.day ?? 1)")!
        // Opens as that account, not whichever one the browser signed in first.
        if let account { components.queryItems = [URLQueryItem(name: "authuser", value: account)] }
        return components.url!
    }
}

// MARK: Week view

/// Seven days side by side, hour by hour.
struct CalendarWeekView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: CalendarModel
    @State private var shown: String?

    private static let hourHeight: CGFloat = 46
    private static let gutter: CGFloat = 52

    private var days: [Date] { CalendarGrid.week(of: store.calendarDay) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                CalendarTitle(date: store.calendarDay, detail: CalendarGrid.weekRange(days))
                CalendarNotices(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            dayHeaders
            allDayRow
            Divider().opacity(0.6)
            hours
        }
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                Button { store.showCalendarDay(day) } label: {
                    HStack(spacing: 5) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isToday ? .white : .primary)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(isToday ? Theme.accent : .clear, in: Circle())
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .help("Show \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var allDayRow: some View {
        let rows = days.map { model.events(on: $0).allDay }
        if rows.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("All day")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.gutter, alignment: .leading)
                ForEach(Array(days.enumerated()), id: \.element) { index, _ in
                    VStack(spacing: 2) {
                        ForEach(rows[index]) { event in
                            EventChip(event: event, showTime: false) { toggle(event) }
                                .popover(isPresented: showing(event), arrowEdge: .bottom) { EventDetails(event: event) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var hours: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    HourGrid(hourHeight: Self.hourHeight, gutter: Self.gutter)
                    GeometryReader { geometry in
                        let column = (geometry.size.width - Self.gutter) / 7
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            // Day separators.
                            Rectangle().fill(Color.primary.opacity(0.06))
                                .frame(width: 1, height: Self.hourHeight * 24)
                                .offset(x: Self.gutter + column * CGFloat(index))
                            let timed = model.events(on: day).timed
                            let slots = CalendarLayout.slots(for: timed.map { (max($0.start, day), min($0.end, CalendarGrid.end(of: day))) })
                            ForEach(Array(timed.enumerated()), id: \.element.id) { position, event in
                                let frame = CalendarGrid.frame(
                                    for: event, on: day, slot: slots[position], hourHeight: Self.hourHeight,
                                    x: Self.gutter + column * CGFloat(index) + 2, width: column - 4
                                )
                                EventBlock(event: event, height: frame.height) { toggle(event) }
                                    .frame(width: frame.width, height: frame.height)
                                    .popover(isPresented: showing(event), arrowEdge: .trailing) { EventDetails(event: event) }
                                    .offset(x: frame.minX, y: frame.minY)
                            }
                            if Calendar.current.isDateInToday(day) {
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    let y = CGFloat(context.date.timeIntervalSince(day) / 3600) * Self.hourHeight
                                    Rectangle().fill(.red).frame(width: column, height: 1.5)
                                        .offset(x: Self.gutter + column * CGFloat(index), y: y)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
                .frame(height: Self.hourHeight * 24)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(CalendarGrid.firstHour(days.flatMap { model.events(on: $0).timed }), anchor: .top) }
            .onChange(of: store.calendarDay) { proxy.scrollTo(CalendarGrid.firstHour(days.flatMap { model.events(on: $0).timed }), anchor: .top) }
        }
    }

    private func toggle(_ event: CalendarEvent) { shown = shown == event.id ? nil : event.id }

    private func showing(_ event: CalendarEvent) -> Binding<Bool> {
        Binding(get: { shown == event.id }, set: { if !$0, shown == event.id { shown = nil } })
    }
}

// MARK: Month view

/// The month as a grid of weeks. A day's events are listed in its square; click a day to see it on its own.
struct CalendarMonthView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: CalendarModel
    @State private var shown: String?

    private static let rowHeight: CGFloat = 18

    private var weeks: [[Date]] { CalendarGrid.month(of: store.calendarDay) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                CalendarTitle(date: store.calendarDay, detail: nil, monthOnly: true)
                CalendarNotices(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            HStack(spacing: 0) {
                ForEach(weeks.first ?? [], id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            GeometryReader { geometry in
                let height = geometry.size.height / CGFloat(max(weeks.count, 1))
                VStack(spacing: 0) {
                    ForEach(weeks, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { day in
                                cell(day, height: height)
                            }
                        }
                        .frame(height: height)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func cell(_ day: Date, height: CGFloat) -> some View {
        let calendar = Calendar.current
        let inMonth = calendar.isDate(day, equalTo: store.calendarDay, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let (allDay, timed) = model.events(on: day)
        let events = allDay + timed
        let fits = max(Int((height - 30) / Self.rowHeight), 0)
        let visible = events.count > fits ? max(fits - 1, 0) : events.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { store.showCalendarDay(day) } label: {
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 12, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(isToday ? Theme.accent : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .clickable()
                .help("Show \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
                Spacer(minLength: 0)
            }
            ForEach(events.prefix(visible)) { event in
                EventChip(event: event, showTime: !event.isAllDay) { toggle(event) }
                    .popover(isPresented: showing(event), arrowEdge: .trailing) { EventDetails(event: event) }
            }
            if visible < events.count {
                Button("More") { store.showCalendarDay(day) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .clickable()
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : Color.primary.opacity(0.025))
        .overlay(alignment: .topLeading) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
        .opacity(inMonth ? 1 : 0.75)
    }

    private func toggle(_ event: CalendarEvent) { shown = shown == event.id ? nil : event.id }

    private func showing(_ event: CalendarEvent) -> Binding<Bool> {
        Binding(get: { shown == event.id }, set: { if !$0, shown == event.id { shown = nil } })
    }
}

/// One line for an event: a colored all-day bar, or a dot, the time and the title.
private struct EventChip: View {
    let event: CalendarEvent
    let showTime: Bool
    let open: () -> Void

    var body: some View {
        let color = EventColor.of(event)
        Button(action: open) {
            HStack(spacing: 4) {
                if event.isAllDay {
                    Text(event.title).fontWeight(.medium).lineLimit(1)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                    if showTime {
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(event.title).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .strikethrough(event.isDeclined)
            .opacity(event.isDeclined ? 0.55 : 1)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.isAllDay ? color.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .help(EventText.help(event))
    }
}

/// The big title over the week and month: "November 2026", with the week's dates beside it.
private struct CalendarTitle: View {
    let date: Date
    let detail: String?
    var monthOnly = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(date.formatted(.dateTime.month(.wide)))
                .font(.system(size: 26, weight: .bold))
            Text(date.formatted(.dateTime.year()))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Hour lines with their labels, for the week.
private struct HourGrid: View {
    let hourHeight: CGFloat
    let gutter: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(CalendarDayView.hourLabel(hour))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: gutter - 6, alignment: .trailing)
                        .offset(y: -6)
                        .opacity(hour == 0 ? 0 : 1)
                    Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }
}

/// Dates and frames for the week and month grids.
enum CalendarGrid {
    /// The seven days of the week `day` is in, in the order this Mac uses.
    static func week(of day: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Whole weeks covering the month `day` is in.
    static func month(of day: Date, calendar: Calendar = .current) -> [[Date]] {
        guard let month = calendar.dateInterval(of: .month, for: day) else { return [week(of: day)] }
        var weeks: [[Date]] = []
        var cursor = week(of: month.start, calendar: calendar).first ?? month.start
        while cursor < month.end {
            let days = week(of: cursor, calendar: calendar)
            weeks.append(days)
            guard let next = calendar.date(byAdding: .day, value: 7, to: days.first ?? cursor) else { break }
            cursor = next
        }
        return weeks
    }

    static func end(of day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
    }

    static func weekRange(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        let start = first.formatted(.dateTime.day().month(.abbreviated))
        let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.day().month(.abbreviated))
        return "\(start) – \(end)"
    }

    /// Where a timed event sits in its day's column. Events that run past midnight are cut at the day's edges.
    static func frame(for event: CalendarEvent, on day: Date, slot: CalendarLayout.Slot, hourHeight: CGFloat, x: CGFloat, width: CGFloat) -> CGRect {
        let top = max(0, event.start.timeIntervalSince(day) / 60)
        let bottom = min(24 * 60, event.end.timeIntervalSince(day) / 60)
        let height = max(CGFloat(bottom - top) / 60 * hourHeight, 18)
        let columnWidth = width / CGFloat(max(slot.columns, 1))
        return CGRect(x: x + columnWidth * CGFloat(slot.column), y: CGFloat(top) / 60 * hourHeight + 1, width: columnWidth - 2, height: height - 2)
    }

    /// An hour above the earliest event, so the week opens on something.
    static func firstHour(_ events: [CalendarEvent]) -> Int {
        let hours = events.map { Calendar.current.component(.hour, from: $0.start) }
        return max(0, min((hours.min() ?? 8) - 1, 16))
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
    @State private var showingDetails = false

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
        .onTapGesture { showingDetails.toggle() }
        .clickable()
        .help(EventText.help(event))
        .popover(isPresented: $showingDetails, arrowEdge: .leading) { EventDetails(event: event) }
    }
}

// MARK: Event details

/// An event's details, shown in Nook when it's clicked. Google Calendar is one button away.
struct EventDetails: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let location = event.location, location != event.joinURL?.absoluteString {
                        row("mappin.and.ellipse") { Text(location).textSelection(.enabled) }
                    }
                    if let response = responseText {
                        row(icon(for: event.response)) { Text(response) }
                    }
                    if !people.isEmpty { guests }
                    if let notes = event.notes {
                        row("text.alignleft") {
                            Text(linked(notes))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)
            Divider()
            actions
        }
        .frame(width: 380)
        .font(.system(size: 12.5))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(EventColor.of(event)).frame(width: 4).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 16, weight: .semibold))
                    .strikethrough(event.isDeclined)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when).foregroundStyle(.secondary)
                Text("\(event.calendarName) · \(event.account)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var guests: some View {
        row("person.2") {
            VStack(alignment: .leading, spacing: 5) {
                Text(guestSummary).foregroundStyle(.secondary)
                ForEach(people, id: \.email) { person in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: person.response))
                            .font(.system(size: 10.5))
                            .foregroundStyle(color(for: person.response))
                            .frame(width: 14)
                        Text(person.displayName + (person.isYou ? " (you)" : "")).lineLimit(1)
                        if person.isOrganizer {
                            Text("Organizer").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    .help(person.email)
                    .contextMenu {
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(person.email, forType: .string)
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let join = event.joinURL, !event.isDeclined {
                Button {
                    NSWorkspace.shared.open(join)
                } label: {
                    Label("Join \(join.host.map(Self.service) ?? "call")", systemImage: "video.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            Spacer(minLength: 0)
            if let link = event.googleCalendarURL {
                Button("Open in Google Calendar") { NSWorkspace.shared.open(link) }
                    .help("Opens as \(event.account)")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func row<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var when: String {
        let calendar = Calendar.current
        if event.isAllDay {
            let last = calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.start
            let first = event.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return calendar.isDate(last, inSameDayAs: event.start) ? "\(first) · All day"
                : "\(first) – \(last.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
        }
        let day = event.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if calendar.isDate(event.start, inSameDayAs: event.end) || event.end == calendar.startOfDay(for: event.end) {
            return "\(day) · \(EventText.timeRange(event))"
        }
        return "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .abbreviated, time: .shortened))"
    }

    private var responseText: String? {
        switch event.response {
        case .accepted: "You're going"
        case .tentative: "You said maybe"
        case .declined: "You declined"
        case .needsAction: "You haven't answered"
        case nil: nil
        }
    }

    /// The organizer first, then everyone else as Google lists them.
    private var people: [CalendarEvent.Person] {
        var list = event.guests
        if let organizer = event.organizer, !list.contains(where: { $0.email.lowercased() == organizer.email.lowercased() }),
           !list.isEmpty {
            list.insert(organizer, at: 0)
        }
        return list.sorted { $0.isOrganizer && !$1.isOrganizer }
    }

    private var guestSummary: String {
        let going = people.filter { $0.response == .accepted }.count
        let total = people.count
        return "\(total) guest\(total == 1 ? "" : "s") · \(going) going"
    }

    private func icon(for response: CalendarEvent.Response?) -> String {
        switch response {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        default: "circle"
        }
    }

    private func color(for response: CalendarEvent.Response?) -> Color {
        switch response {
        case .accepted: .green
        case .declined: .red
        case .tentative: .orange
        default: .secondary
        }
    }

    /// Plain text with its web links clickable.
    private func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].link = url
        }
        return result
    }

    static func service(_ host: String) -> String {
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        return host
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
