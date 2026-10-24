import AppKit
import NookCore
import SwiftUI

/// A reminder going off: a small window in the top-right corner, above every app and on every Space,
/// that stays until you deal with it. Several stack downwards.
@MainActor
final class ReminderAlerts {
    static let shared = ReminderAlerts()

    private var panels: [(key: String, panel: NSPanel)] = []

    /// The alerts on screen, newest last.
    var visiblePanels: [NSPanel] { panels.map(\.panel) }

    func show(_ reminder: Reminder, subject: String, person: String) {
        let key = Self.key(account: reminder.account, threadId: reminder.threadId)
        dismiss(key: key, relayout: false)

        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        // The view draws the rounded card; the panel is just a transparent holder with a shadow.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = ReminderAlertView(
            kind: reminder.kind, subject: subject.isEmpty ? "(no subject)" : subject, person: person, since: reminder.since,
            open: { [weak self] in
                self?.dismiss(key: key)
                AppStore.current?.showMainWindow()
                AppStore.current?.handle(NookURL.open(account: reminder.account, threadId: reminder.threadId).url)
            },
            later: { [weak self] date in
                self?.dismiss(key: key)
                AppStore.current?.remindAgain(account: reminder.account, threadId: reminder.threadId, at: date)
            },
            done: { [weak self] in
                self?.dismiss(key: key)
                AppStore.current?.markDone(account: reminder.account, threadId: reminder.threadId)
            },
            close: { [weak self] in self?.dismiss(key: key) }
        )
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panels.append((key, panel))
        layout()
        panel.orderFrontRegardless()

        NSSound(named: "Glass")?.play()
        NSApp.requestUserAttention(.informationalRequest)
        if CommandLine.arguments.contains("--demo") {
            print("demo: reminder-alert=\(subject) | \(person)")
            fflush(stdout)
        }
    }

    /// Opening the conversation in Nook answers its alert.
    func dismiss(account: String, threadId: String) {
        dismiss(key: Self.key(account: account, threadId: threadId))
    }

    private func dismiss(key: String, relayout: Bool = true) {
        guard let index = panels.firstIndex(where: { $0.key == key }) else { return }
        panels.remove(at: index).panel.close()
        if relayout { layout() }
    }

    /// Top-right of the screen with the menu bar, newest at the top.
    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var top = area.maxY - 12
        for (_, panel) in panels.reversed() {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 12, y: top - size.height))
            top -= size.height + 10
        }
    }

    private static func key(account: String, threadId: String) -> String { "\(account)/\(threadId)" }
}

private struct ReminderAlertView: View {
    let kind: Reminder.Kind
    let subject: String
    let person: String
    let since: Date?
    let open: () -> Void
    let later: (Date) -> Void
    let done: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .followUp ? "arrowshape.turn.up.left.fill" : "bell.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(kind == .followUp ? "No reply yet" : "Reminder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(subject)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    // Drawn by hand: a panel that never becomes key would show a prominent button greyed out.
                    Button(action: open) {
                        Text("Open")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu("Later") {
                        Button("In 1 hour") { later(Date().addingTimeInterval(3600)) }
                        ForEach(ReminderTime.presets(now: Date())) { option in
                            Button("\(option.title) · \(ReminderTime.short(option.date))") { later(option.date) }
                        }
                    }
                    .fixedSize()
                    Button("Done", action: done)
                        .help("Mark done: archive the conversation")
                }
                .controlSize(.regular)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var detail: String {
        switch kind {
        case .remind:
            return person.isEmpty ? "" : "From \(person)"
        case .followUp:
            let wrote = since.map { "you wrote \($0.formatted(.relative(presentation: .named)))" }
            return [person.isEmpty ? nil : "To \(person)", wrote].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
