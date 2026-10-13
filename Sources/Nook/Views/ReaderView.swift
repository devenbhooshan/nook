import NookCore
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSummary

    @AppStorage("privacy.blockRemoteContent") private var blockRemoteContent = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    if blockRemoteContent, hasBlockedContent {
                        remoteContentBanner
                    }
                    VStack(spacing: 12) {
                        ForEach(Array(store.openMessages.enumerated()), id: \.element.id) { index, message in
                            MessageCard(
                                message: message,
                                startsExpanded: index == store.openMessages.count - 1 || message.isUnread,
                                allowRemoteContent: allowRemote
                            )
                        }
                    }
                    replyBar
                }
                .background(EnclosingScrollViewReader { store.readerScrollView = $0 })
                .frame(maxWidth: Theme.readerWidth)
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var current: ThreadSummary {
        store.threads.first { $0.id == thread.id } ?? thread
    }

    private var allowRemote: Bool {
        !blockRemoteContent || store.remoteContentAllowed.contains(thread.id)
    }

    private var hasBlockedContent: Bool {
        !allowRemote && store.openMessages.contains(where: MessageRenderCache.containsRemoteContent)
    }

    // MARK: Pieces

    private var toolbar: some View {
        TopBar {
            Button {
                store.closeThread()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(backLabel).font(.system(size: 13, weight: .medium))
                    KeyCap("esc")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.quiet)
        } trailing: {
            IconButton(systemImage: "checkmark", title: "Mark done", shortcut: "E") { store.archive() }
            IconButton(systemImage: "star", title: isStarred ? "Unstar" : "Star", shortcut: "S", isActive: isStarred) { store.toggleStar() }
            IconButton(systemImage: "envelope.badge", title: "Mark unread", shortcut: "U") { store.toggleRead() }
            IconButton(systemImage: "tag", title: "Tag", shortcut: "L") { store.openPalette(.tags) }
            IconButton(systemImage: "trash", title: "Move to Trash", shortcut: "#") { store.trash() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            IconButton(systemImage: "chevron.up", title: "Previous conversation", shortcut: "K", tooltipAlignment: .trailing) { store.move(by: -1) }
            IconButton(systemImage: "chevron.down", title: "Next conversation", shortcut: "J", tooltipAlignment: .trailing) { store.move(by: 1) }
        }
    }

    private var isStarred: Bool {
        current.isStarred || store.openMessages.contains(where: \.isStarred)
    }

    private var backLabel: String {
        if store.isSearching { return "Search" }
        if store.mailbox == .inbox, store.split != .everything { return store.split.title }
        return store.mailbox.title
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                .font(.system(size: 24, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let account = store.account(for: thread.account), store.accounts.count > 1 {
                    HStack(spacing: 5) {
                        AccountDot(colorIndex: account.colorIndex, size: 6)
                        Text(account.email)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                }
                ForEach(current.tags, id: \.self) { tag in
                    TagPill(name: tag, colorIndex: store.tag(named: tag)?.colorIndex ?? 0)
                }
            }
        }
    }

    private var remoteContentBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote images blocked")
                    .font(.system(size: 12.5, weight: .medium))
                Text("They can tell the sender when and where you opened this email.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Load images") {
                store.remoteContentAllowed.insert(thread.id)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var replyBar: some View {
        HStack(spacing: 8) {
            replyButton("Reply", key: "R", systemImage: "arrowshape.turn.up.left") { store.reply(.reply) }
            replyButton("Reply all", key: "A", systemImage: "arrowshape.turn.up.left.2") { store.reply(.replyAll) }
            replyButton("Forward", key: "F", systemImage: "arrowshape.turn.up.right") { store.reply(.forward) }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func replyButton(_ title: String, key: String, systemImage: String, action: @escaping () -> Void) -> some View {
        ReplyButton(title: title, key: key, systemImage: systemImage, action: action)
    }
}

private struct ReplyButton: View {
    let title: String
    let key: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(title).font(.system(size: 13, weight: .medium))
                KeyCap(key)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .onHover { hovering = $0 }
    }
}

struct MessageCard: View {
    let message: MailMessage
    let startsExpanded: Bool
    let allowRemoteContent: Bool

    @State private var expanded: Bool?
    @State private var bodyHeight: CGFloat = 40

    private var isExpanded: Bool { expanded ?? startsExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .clickable()
                .onTapGesture { withAnimation(.snappy(duration: 0.18)) { expanded = !isExpanded } }

            if isExpanded {
                EmailWebView(
                    html: MessageRenderCache.document(for: message, allowRemoteContent: allowRemoteContent),
                    height: $bodyHeight
                )
                .frame(height: bodyHeight)
                .padding(message.bodyHTML.isEmpty ? EdgeInsets(top: 4, leading: 58, bottom: 18, trailing: 20) : EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                .background {
                    if !message.bodyHTML.isEmpty {
                        // HTML mail is designed for a light page; give it one, inset like a sheet of paper.
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: message.fromName, email: message.fromEmail, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Addresses.displayName(name: message.fromName, email: message.fromEmail))
                        .font(.system(size: 13.5, weight: .semibold))
                    if message.fromName != message.fromEmail {
                        Text(message.fromEmail)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if isExpanded {
                    Text(recipients)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(message.snippet)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if message.isStarred {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                }
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
    }

    private var recipients: String {
        let to = Addresses.parseList(message.to).map { Addresses.displayName(name: $0.name, email: $0.email) }
        let cc = Addresses.parseList(message.cc).map { Addresses.displayName(name: $0.name, email: $0.email) }
        var line = "to " + (to.isEmpty ? "undisclosed recipients" : to.joined(separator: ", "))
        if !cc.isEmpty { line += "  ·  cc " + cc.joined(separator: ", ") }
        return line
    }
}
