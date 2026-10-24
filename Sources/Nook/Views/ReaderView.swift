import NookCore
import QuickLook
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var store: AppStore
    let thread: ThreadSummary

    @AppStorage("privacy.blockRemoteContent") private var blockRemoteContent = true
    @AppStorage(ImageSenders.storageKey) private var imageSenders = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    if blockRemoteContent, hasBlockedContent {
                        remoteContentBanner
                    } else if let entry = autoLoadedFrom {
                        autoLoadedNote(entry)
                    }
                    VStack(spacing: 12) {
                        ForEach(Array(store.openMessages.enumerated()), id: \.element.id) { index, message in
                            MessageCard(
                                message: message,
                                startsExpanded: index == store.openMessages.count - 1 || message.isUnread,
                                allowRemoteContent: allowsRemote(message)
                            )
                        }
                    }
                }
                .background(EnclosingScrollViewReader { store.readerScrollView = $0 })
                .frame(maxWidth: Theme.readerWidth)
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            // Always in reach, however long the conversation.
            replyBar
                .frame(maxWidth: Theme.readerWidth)
                .padding(.horizontal, 32)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
        .quickLookPreview($store.quickLookURL, in: store.quickLookItems)
    }

    private var current: ThreadSummary {
        store.threads.first { $0.id == thread.id } ?? thread
    }

    private var allowRemote: Bool {
        !blockRemoteContent || store.remoteContentAllowed.contains(thread.id)
    }

    private func allowsRemote(_ message: MailMessage) -> Bool {
        allowRemote || ImageSenders.matches(message.fromEmail, in: ImageSenders.parse(imageSenders))
    }

    /// The first message whose images are held back, if any.
    private var blockedMessage: MailMessage? {
        store.openMessages.first { !allowsRemote($0) && MessageRenderCache.containsRemoteContent($0) }
    }

    private var hasBlockedContent: Bool { blockedMessage != nil }

    /// The allowlist entry that loaded this conversation's images without asking, if one did.
    private var autoLoadedFrom: String? {
        guard blockRemoteContent, !allowRemote else { return nil }
        let entries = ImageSenders.parse(imageSenders)
        return store.openMessages.lazy
            .filter(MessageRenderCache.containsRemoteContent)
            .compactMap { ImageSenders.match($0.fromEmail, in: entries) }
            .first
    }

    private func autoLoadedNote(_ entry: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(entry.contains("@") ? "Images from \(entry) load automatically." : "Images from anyone at \(entry) load automatically.")
            Button("Stop") { imageSenders = ImageSenders.removing(entry, from: imageSenders) }
                .buttonStyle(.textLink)
                .clickable()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
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
            IconButton(systemImage: "bell", title: "Remind me", shortcut: "H", isActive: current.reminder?.isPending == true) { store.showReminderPicker() }
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
                if let reminder = current.reminder {
                    reminderChip(reminder)
                }
            }
        }
    }

    /// When a waiting reminder goes off (click to change it), or why this came back.
    private func reminderChip(_ reminder: Reminder) -> some View {
        Button {
            store.showReminderPicker()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell")
                    .font(.system(size: 10.5, weight: .medium))
                Text(reminder.isPending ? ReminderText.waiting(reminder) : ReminderText.woke(reminder))
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.accent.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.quiet)
        .clickable()
        .help(reminder.isPending ? "Change or remove (H)" : "Remind me again (H)")
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
            Menu("Load images") {
                if let sender = blockedMessage?.fromEmail.lowercased(), !sender.isEmpty {
                    Button("Always load from \(sender)") { imageSenders = ImageSenders.adding(sender, to: imageSenders) }
                    if let domain = ImageSenders.domain(of: sender) {
                        Button("Always load from anyone at \(domain)") { imageSenders = ImageSenders.adding(domain, to: imageSenders) }
                    }
                }
            } primaryAction: {
                store.remoteContentAllowed.insert(thread.id)
            }
            .menuStyle(.button)
            .fixedSize()
            .controlSize(.small)
            .help("Load them for this conversation, or always for this sender")
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
    @EnvironmentObject private var store: AppStore
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
                    height: $bodyHeight,
                    inlineImage: inlineImage
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
                if !message.listedAttachments.isEmpty {
                    AttachmentStrip(message: message)
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
                        .contextMenu { copyMenu(name: message.fromName, email: message.fromEmail) }
                    if message.fromName != message.fromEmail {
                        CopyableAddress(email: message.fromEmail)
                            .contextMenu { copyMenu(name: message.fromName, email: message.fromEmail) }
                    }
                }
                if isExpanded {
                    Text(recipients)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contextMenu {
                            ForEach(Array((Addresses.parseList(message.to) + Addresses.parseList(message.cc)).enumerated()), id: \.offset) { _, address in
                                Button("Copy \(address.email)") { CopyableAddress.copy(address.email) }
                            }
                        }
                } else {
                    Text(message.snippet)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if !message.listedAttachments.isEmpty {
                    Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
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

    /// Images the body shows with `cid:` links (pasted screenshots, signature logos), fetched from Gmail.
    private var inlineImage: EmailWebView.InlineImageLoader? {
        let inline = message.attachments.filter { $0.contentId != nil }
        guard !inline.isEmpty else { return nil }
        let files = store.attachmentFiles
        let account = message.account
        let messageId = message.id
        return { contentId in
            guard let attachment = inline.first(where: { $0.contentId?.caseInsensitiveCompare(contentId) == .orderedSame }),
                  let data = try? await files.data(AttachmentRef(attachment: attachment, account: account, messageId: messageId))
            else { return nil }
            return (data, attachment.mimeType)
        }
    }

    @ViewBuilder private func copyMenu(name: String, email: String) -> some View {
        Button("Copy Address") { CopyableAddress.copy(email) }
        if !name.isEmpty && name != email {
            Button("Copy Name and Address") { CopyableAddress.copy("\(name) <\(email)>", shown: email) }
        }
    }

    private var recipients: String {
        let to = Addresses.parseList(message.to).map { Addresses.displayName(name: $0.name, email: $0.email) }
        let cc = Addresses.parseList(message.cc).map { Addresses.displayName(name: $0.name, email: $0.email) }
        var line = "to " + (to.isEmpty ? "undisclosed recipients" : to.joined(separator: ", "))
        if !cc.isEmpty { line += "  ·  cc " + cc.joined(separator: ", ") }
        return line
    }
}

/// An email address you can click to copy, instead of the click opening or folding the message.
struct CopyableAddress: View {
    let email: String
    @State private var hovering = false

    var body: some View {
        Button { Self.copy(email) } label: {
            Text(email)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .underline(hovering)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .clickable()
        .help("Click to copy")
    }

    static func copy(_ text: String, shown: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppStore.current?.showToast("Copied \(shown ?? text)")
    }
}
