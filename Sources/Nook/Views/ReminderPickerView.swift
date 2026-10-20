import NookCore
import SwiftUI

/// H: when should Nook remind you about this conversation? Pick a usual time or type one ("fri 2pm", "3d").
struct ReminderPickerView: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSummary

    @State private var text = ""
    @State private var highlighted = 0
    @State private var now = Date()
    @FocusState private var focused: Bool
    /// When it opened. A pointer resting where the list appears reports a hover right away; that isn't a choice,
    /// and following it would make Return pick whatever row happened to be under the pointer.
    @State private var openedAt = Date()

    private struct Choice: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var systemImage: String
        var action: () -> Void
    }

    /// The reminder already waiting on this conversation, if any.
    @State private var pending: Reminder?

    private var isFollowUp: Bool { pending?.kind == .followUp }

    private var choices: [Choice] {
        var choices: [Choice] = []
        let typed = text.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let date = ReminderTime.parse(typed, now: now) {
            choices.append(choice(typed.prefix(1).uppercased() + typed.dropFirst(), date: date, systemImage: "text.cursor"))
        }
        let presets = ReminderTime.presets(now: now).filter { typed.isEmpty || $0.title.lowercased().hasPrefix(typed.lowercased()) }
        for preset in presets where !choices.contains(where: { $0.title.lowercased() == preset.title.lowercased() }) {
            choices.append(choice(preset.title, date: preset.date, systemImage: icon(for: preset.title)))
        }
        if typed.isEmpty, let pending {
            choices.append(Choice(
                title: "Remove reminder",
                detail: pending.kind == .remind ? "" : "Stop waiting for a reply",
                systemImage: "bell.slash"
            ) { [store, thread] in store.removeReminder(thread) })
        }
        return choices
    }

    private func choice(_ title: String, date: Date, systemImage: String) -> Choice {
        Choice(title: title, detail: ReminderTime.describe(date, now: now), systemImage: systemImage) { [store, thread] in
            store.remind(thread, at: date)
        }
    }

    private func icon(for preset: String) -> String {
        switch preset {
        case "Later today": "clock"
        case "Tomorrow": "sunrise"
        case "This weekend": "sofa"
        case "Next week": "calendar"
        default: "calendar.badge.clock"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bell")
                        .foregroundStyle(.secondary)
                    TextField(isFollowUp ? "Remind me if no reply by… try “fri 2pm” or “3d”" : "Remind me… try “fri 2pm” or “3d”", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit(run)
                        .onKeyPress(.downArrow) { step(1); return .handled }
                        .onKeyPress(.upArrow) { step(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, 18)
                .frame(height: 52)

                Divider().opacity(0.6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(heading)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 3)
                    if choices.isEmpty {
                        Text("Try “tomorrow 9am”, “2h”, “mon” or “dec 5”")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        row(choice, isHighlighted: index == highlighted)
                            .clickable()
                            .onHover { if $0, Date().timeIntervalSince(openedAt) > 0.4 { highlighted = index } }
                            .onTapGesture {
                                highlighted = index
                                run()
                            }
                    }
                }
                .padding(8)
            }
            .frame(width: 520)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            .padding(.top, 90)
        }
        .onAppear {
            openedAt = Date()
            now = Date()
            pending = store.repo.reminder(account: thread.account, threadId: thread.threadId).flatMap { $0.isPending ? $0 : nil }
            focused = true
        }
        .onChange(of: text) { highlighted = 0 }
    }

    private var heading: String {
        let subject = thread.subject.isEmpty ? "(no subject)" : thread.subject
        if let pending {
            let when = ReminderTime.describe(pending.due, now: now)
            return pending.kind == .remind ? "Reminding you \(when) · \(subject)" : "Reminding you \(when) if no reply · \(subject)"
        }
        return subject
    }

    private func row(_ choice: Choice, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: choice.systemImage)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Theme.accent : .secondary)
            Text(choice.title)
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer()
            Text(choice.detail)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Theme.accent.opacity(0.13) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func step(_ delta: Int) {
        let count = choices.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func run() {
        let choices = choices
        guard choices.indices.contains(highlighted) else { return }
        close()
        choices[highlighted].action()
    }

    private func close() {
        store.reminderTarget = nil
    }
}
