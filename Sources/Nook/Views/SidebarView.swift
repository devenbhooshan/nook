import NookCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights sit here, unless the window is full screen.
            HStack {
                Spacer()
                IconButton(systemImage: "sidebar.left", title: "Hide sidebar", shortcut: "⌘\\", tooltipAlignment: .trailing) {
                    withAnimation(.snappy(duration: 0.2)) { store.showSidebar = false }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .padding(.top, 1)
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Mailboxes") {
                        ForEach(Mailbox.allCases) { mailbox in
                            SidebarRow(
                                title: mailbox.title,
                                systemImage: mailbox.systemImage,
                                hasUnread: mailbox == .inbox && inboxHasUnread,
                                isSelected: !store.showCalendar && store.mailbox == mailbox && (mailbox != .inbox || store.split == .everything) && !store.isSearching
                            ) { store.setMailbox(mailbox) }
                        }
                        SidebarRow(title: "Calendar", systemImage: "calendar", hasUnread: false, isSelected: store.showCalendar) {
                            store.openCalendar()
                        }
                    }

                    section("Accounts") {
                        SidebarRow(
                            title: "All accounts",
                            systemImage: "tray.2",
                            hasUnread: false,
                            isSelected: store.scope == nil
                        ) { store.setScope(nil) }
                        ForEach(store.accounts) { account in
                            SidebarRow(
                                title: account.email,
                                leading: AnyView(AccountDot(colorIndex: account.colorIndex).frame(width: 16)),
                                hasUnread: (store.unreadCounts[account.email] ?? 0) > 0,
                                warning: store.needsSignIn(account.email) ? "Signed out. Sign in again to resume syncing." : store.syncErrors[account.email],
                                isSelected: store.scope == account.email
                            ) { store.setScope(account.email) }
                        }
                    }

                    if !store.tags.isEmpty {
                        section("Tags") {
                            ForEach(store.tags) { tag in
                                SidebarRow(
                                    title: tag.name,
                                    leading: AnyView(Circle().fill(Theme.color(tag.colorIndex)).frame(width: 7, height: 7).frame(width: 16)),
                                    hasUnread: false,
                                    isSelected: store.mailbox == .inbox && store.split == .tag(tag.name)
                                ) { store.setSplit(.tag(tag.name)) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }

            SidebarFooter()
        }
    }

    private var inboxHasUnread: Bool {
        if let scope = store.scope { return (store.unreadCounts[scope] ?? 0) > 0 }
        return store.unreadCounts.values.contains { $0 > 0 }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            content()
        }
    }
}

private struct SidebarRow: View {
    let title: String
    var systemImage: String?
    var leading: AnyView?
    /// A quiet dot rather than a number: "something's new here" without the pressure of a tally.
    let hasUnread: Bool
    var warning: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    init(title: String, systemImage: String? = nil, leading: AnyView? = nil, hasUnread: Bool, warning: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.leading = leading
        self.hasUnread = hasUnread
        self.warning = warning
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leading {
                    leading
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .frame(width: 16)
                        .foregroundStyle(isSelected ? Theme.accent : .secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let warning {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .help(warning)
                } else if hasUnread {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .onHover { hovering = $0 }
    }
}

/// Sync and tagging status, kept small and out of the way.
private struct SidebarFooter: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if store.isSyncing {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…")
                } else if !store.signedOutAccounts.isEmpty {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                    Text(store.signedOutAccounts.count == 1 ? "An account is signed out" : "Accounts are signed out")
                        .help(store.signedOutAccounts.joined(separator: "\n"))
                } else if !store.syncErrors.isEmpty {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("Sync problem").help(store.syncErrors.values.joined(separator: "\n"))
                } else {
                    Image(systemName: "checkmark.circle")
                    Text(store.lastSynced.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
                }
            }
            if let line = taggerLine {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(line).lineLimit(1)
                }
                .help(store.taggerStatus.lastError ?? store.taggerStatus.modelName ?? "")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var taggerLine: String? {
        let status = store.taggerStatus
        if status.isRunning, status.pending > 0 {
            return "Tagging new mail on device"
        }
        if status.lastError != nil, status.pending > 0 {
            return "Tagging paused"
        }
        return status.modelName.map { "Tags by \($0)" }
    }
}
