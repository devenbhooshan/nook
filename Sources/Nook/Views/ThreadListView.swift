import NookCore
import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar {
                ScopeMenu()
            } trailing: {
                searchField
                IconButton(systemImage: "square.and.pencil", title: "New message", shortcut: "C", tooltipAlignment: .trailing) { store.compose() }
            }

            ContentColumn {
                if store.visibleSplits.isEmpty {
                    ListTitle()
                } else {
                    SplitTabs()
                }
            }
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }

            if !store.signedOutAccounts.isEmpty {
                SignedOutNotice()
            }

            if store.threads.isEmpty {
                EmptyListView()
            } else {
                list
                ShortcutHints()
            }
        }
        .onChange(of: store.focusSearchRequest) {
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .onKeyPress(.escape) {
                    if store.searchText.isEmpty { searchFocused = false } else { store.searchText = "" }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    searchFocused = false
                    return .handled
                }
            if store.searchText.isEmpty {
                KeyCap("/")
            } else {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.quiet)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: searchFocused || !store.searchText.isEmpty ? 320 : 220, height: 30)
        .background(Color.primary.opacity(searchFocused ? 0.07 : 0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(searchFocused ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1))
        .animation(.snappy(duration: 0.18), value: searchFocused)
        .help("Try from:anna, tag:receipt, is:unread, in:sent, account:work")
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ContentColumn {
                    LazyVStack(spacing: 2) {
                        ForEach(store.threads) { thread in
                            ThreadRow(
                                thread: thread,
                                isSelected: thread.id == store.selectedID,
                                account: store.accounts.count > 1 && store.scope == nil ? store.account(for: thread.account) : nil,
                                hiddenTag: currentTag,
                                tagColor: { store.tag(named: $0)?.colorIndex ?? 0 }
                            )
                            .id(thread.id)
                            .clickable()
                            .onTapGesture { store.open(thread) }
                            .contextMenu { contextMenu(for: thread) }
                            .onAppear { store.loadMoreIfNeeded(after: thread) }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            // Lists swap instantly; nothing in here should inherit an animation.
            .transaction { $0.animation = nil }
            .onChange(of: store.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) }
            }
        }
    }

    /// The split's own tag is implied, so rows don't repeat it.
    private var currentTag: String? {
        if case .tag(let name) = store.split, !store.visibleSplits.isEmpty { return name }
        return nil
    }

    @ViewBuilder
    private func contextMenu(for thread: ThreadSummary) -> some View {
        Button("Open") { store.open(thread) }
        Divider()
        Button("Mark Done") { store.selectedID = thread.id; store.archive() }
        Button(thread.isStarred ? "Unstar" : "Star") { store.selectedID = thread.id; store.toggleStar() }
        Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") { store.selectedID = thread.id; store.toggleRead() }
        Divider()
        Button("Reply") { store.selectedID = thread.id; store.reply(.reply) }
        Button("Move to Trash", role: .destructive) { store.selectedID = thread.id; store.trash() }
    }
}

// MARK: - Header pieces

/// The account and mailbox switcher at the top left. With the sidebar hidden, this is how you get around.
private struct ScopeMenu: View {
    @EnvironmentObject private var store: AppStore
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Mailbox") {
                ForEach(Mailbox.allCases) { mailbox in
                    Toggle(isOn: Binding(get: { store.mailbox == mailbox }, set: { _ in store.setMailbox(mailbox) })) {
                        Label(mailbox.title, systemImage: mailbox.systemImage)
                    }
                }
            }
            Section("Show") {
                Toggle(isOn: Binding(get: { !store.unreadOnly }, set: { if $0 && store.unreadOnly { store.toggleUnreadOnly() } })) {
                    Label("All mail", systemImage: "tray")
                }
                Toggle(isOn: Binding(get: { store.unreadOnly }, set: { if $0 != store.unreadOnly { store.toggleUnreadOnly() } })) {
                    Label("Unread only  ⇧U", systemImage: "circle.inset.filled")
                }
            }
            Section("Account") {
                Toggle(isOn: Binding(get: { store.scope == nil }, set: { _ in store.setScope(nil) })) {
                    Label("All accounts", systemImage: "tray.2")
                }
                ForEach(store.accounts) { account in
                    Toggle(isOn: Binding(get: { store.scope == account.email }, set: { _ in store.setScope(account.email) })) {
                        // The same color dot as the sidebar and message list, sized to sit where menu icons do.
                        Label { Text(account.email) } icon: { Image(nsImage: AccountDot.menuImage(colorIndex: account.colorIndex)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let email = store.scope, let account = store.account(for: email) {
                    AccountDot(colorIndex: account.colorIndex, size: 7)
                } else {
                    Image(systemName: store.mailbox.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.quiet)
        .fixedSize()
        .onHover { hovering = $0 }
    }

    private var label: String {
        let account = store.scope ?? (store.accounts.count > 1 ? "All accounts" : store.accounts.first?.email ?? "")
        var parts = [account]
        if store.mailbox != .inbox { parts.insert(store.mailbox.title, at: 0) }
        // Say so when the filter is on, so an empty inbox is never a mystery.
        if store.unreadOnly && store.mailbox == .inbox { parts.append("Unread") }
        return parts.joined(separator: " · ")
    }
}

/// Inbox tabs: Everything, one per tag that has mail, and Other.
private struct SplitTabs: View {
    @EnvironmentObject private var store: AppStore
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(store.visibleSplits, id: \.self) { split in
                        tab(split)
                    }
                }
                .padding(.horizontal, 14)
                .animation(.snappy(duration: 0.18), value: store.split)
            }
        }
        .frame(height: 46)
    }

    private func tab(_ split: InboxSplit) -> some View {
        SplitTabButton(
            split: split,
            selected: store.split == split,
            hasUnread: store.unreadSplitCounts.count(for: split) > 0,
            tagColor: { if case .tag(let name) = split { Theme.color(store.tag(named: name)?.colorIndex ?? 0) } else { nil } }(),
            underline: underline
        ) {
            // No animation here: animating the list swap is what made switching feel slow. Only the underline moves.
            store.setSplit(split)
        }
    }
}

private struct SplitTabButton: View {
    let split: InboxSplit
    let selected: Bool
    let hasUnread: Bool
    let tagColor: Color?
    let underline: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let tagColor {
                        Circle().fill(tagColor).frame(width: 6, height: 6)
                    }
                    // No counts: a tab with something unread just reads a little darker.
                    Text(split.title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : (hasUnread ? .medium : .regular)))
                        .foregroundStyle(selected || hasUnread || hovering ? Color.primary : Color.secondary)
                }
                Spacer(minLength: 0)
                ZStack {
                    if selected {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    } else {
                        Capsule()
                            .fill(Color.primary.opacity(hovering ? 0.15 : 0))
                            .frame(height: 2)
                    }
                }
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .onHover { hovering = $0 }
    }
}

/// Shown instead of tabs outside the inbox and for search results.
private struct ListTitle: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Text(store.isSearching ? "Search results" : store.mailbox.title)
                .font(.system(size: 13.5, weight: .semibold))
            Spacer()
            if store.isSearching {
                Text("All mail on this Mac").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            } else if store.mailbox != .inbox {
                Button("Back to Inbox") { store.setMailbox(.inbox) }
                    .buttonStyle(.textLink)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

// MARK: - Empty state and hints

private struct EmptyListView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if isFirstSync { ProgressView().controlSize(.small) }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if isUnreadFilter && !isFirstSync {
                Button("Show all mail") { store.toggleUnreadOnly() }
                    .buttonStyle(.textLink)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 6)
            }
        }
        // Sit a little above center, where the eye lands, rather than dead center.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 120)
    }

    /// Only the very first download, before anything is stored, gets the "downloading" message.
    private var isFirstSync: Bool { !store.hasStoredMail && (store.isSyncing || store.lastSynced == nil) }
    private var isWholeInbox: Bool { store.mailbox == .inbox && store.split == .everything }
    private var isUnreadFilter: Bool { store.unreadOnly && store.mailbox == .inbox && !store.isSearching }

    private var title: String {
        if store.isSearching { return "No matches" }
        if isFirstSync { return "Downloading your mail" }
        if isUnreadFilter { return "You're all caught up" }
        if isWholeInbox { return "Inbox zero" }
        return store.mailbox == .inbox ? "Nothing in \(store.split.title)" : "Nothing in \(store.mailbox.title)"
    }

    private var subtitle: String {
        if store.isSearching { return "Search covers all mail stored on this Mac." }
        if isFirstSync { return "It's stored on this Mac, so it'll be instant from now on." }
        if isUnreadFilter { return store.split == .everything ? "Nothing unread." : "Nothing unread in \(store.split.title)." }
        if isWholeInbox { return "Nothing needs you right now." }
        return "Press Tab for the next split."
    }
}

/// One quiet line when an account has lost its sign-in, instead of a silent, stale inbox.
private struct SignedOutNotice: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ContentColumn {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign in again…") { store.openSettings() }
                    .buttonStyle(.textLink)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.orange.opacity(0.06))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var message: String {
        let emails = store.signedOutAccounts
        return emails.count == 1
            ? "\(emails[0]) is signed out, so it isn't syncing."
            : "\(emails.count == 2 ? "Two" : "Some") accounts are signed out, so they aren't syncing."
    }
}

private struct ShortcutHints: View {
    var body: some View {
        HStack(spacing: 16) {
            hint("move", "J", "K")
            hint("open", "↵")
            hint("done", "E")
            hint("reply", "R")
            hint("commands", "⌘K")
            hint("shortcuts", "?")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func hint(_ label: String, _ keys: String...) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Row

struct ThreadRow: View {
    let thread: ThreadSummary
    let isSelected: Bool
    let account: Account?
    var hiddenTag: String?
    let tagColor: (String) -> Int

    @State private var hovering = false

    private var tags: [String] { thread.tags.filter { $0 != hiddenTag } }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(thread.isUnread ? Theme.accent : .clear)
                .frame(width: 7, height: 7)

            HStack(spacing: 6) {
                Text(Addresses.displayName(name: thread.fromName, email: thread.fromEmail))
                    .font(.system(size: 13.5, weight: thread.isUnread ? .semibold : .regular))
                    .foregroundStyle(thread.isUnread ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)

            HStack(spacing: 8) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 13.5, weight: thread.isUnread ? .semibold : .regular))
                    .foregroundStyle(thread.isUnread ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(thread.snippet)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(2), id: \.self) { tag in
                        TagPill(name: tag, colorIndex: tagColor(tag), compact: true)
                    }
                    if tags.count > 2 {
                        Text("+\(tags.count - 2)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .fixedSize()
            }
            if thread.isStarred {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
            }
            if let account {
                AccountDot(colorIndex: account.colorIndex, size: 6).help(account.email)
            }
            Text(thread.date.listLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(thread.isUnread ? .secondary : .tertiary)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.1) : (hovering ? Color.primary.opacity(0.035) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
