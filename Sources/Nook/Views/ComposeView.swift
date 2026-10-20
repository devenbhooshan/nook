import AppKit
import NookCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var showCc: Bool
    @State private var confirmDiscard = false
    @State private var dropTargeted = false
    @State private var choosingFiles = false
    /// What the draft looked like when it opened, to tell whether discarding would lose anything.
    private let original: Draft
    @FocusState private var focus: Field?
    @StateObject private var suggestions = RecipientSuggestions()

    private enum Field: Hashable { case to, cc, subject, body }

    init(draft: Draft) {
        _draft = State(initialValue: draft)
        original = draft
        _showCc = State(initialValue: !draft.cc.isEmpty)
    }

    /// Which account sends this. ⌘⇧F moves to the next one.
    private var fromMenu: some View {
        let current = store.accounts.first { $0.email == draft.from }
        return Menu {
            ForEach(store.accounts) { account in
                Button {
                    draft.from = account.email
                } label: {
                    Label { Text(account.email) } icon: { Image(nsImage: AccountDot.menuImage(colorIndex: account.colorIndex)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("From").foregroundStyle(.secondary)
                if let current { AccountDot(colorIndex: current.colorIndex) }
                Text(draft.from).foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
        .help("Send from another account (⌘⇧F)")
        .background {
            Button("Next account", action: nextAccount)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        }
    }

    private func nextAccount() {
        let emails = store.accounts.map(\.email)
        guard emails.count > 1 else { return }
        let index = emails.firstIndex(of: draft.from) ?? -1
        draft.from = emails[(index + 1) % emails.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.accounts.count > 1 {
                    fromMenu
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            recipientField("To", text: $draft.to, focus: .to) {
                if !showCc {
                    Button("Cc") { showCc = true; focus = .cc }
                        .buttonStyle(.textLink)
                        .font(.system(size: 12))
                }
            }
            if showCc {
                recipientField("Cc", text: $draft.cc, focus: .cc) { EmptyView() }
            }
            field("Subject", text: $draft.subject, focus: .subject) { EmptyView() }

            TextEditor(text: $draft.body)
                .font(.system(size: 14.5))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .padding(.bottom, 6)

            if !draft.quoted.isEmpty {
                quotedSection
            }
            if !draft.attachments.isEmpty {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(draft.attachments) { attachment in
                            OutgoingAttachmentChip(attachment: attachment) {
                                draft.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                IconButton(systemImage: "paperclip", title: "Attach files", shortcut: "⌘⇧A", action: pickFiles)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                followUpMenu
                if isOverLimit {
                    Text("Attachments are over Gmail's 25 MB limit")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                } else if draft.followUpAfter == nil {
                    Text("Sent directly from this Mac through Gmail")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if draft.gmailDraftMessageId != nil {
                    // A draft from Gmail: closing keeps it in Drafts, with your changes if you want them.
                    Button("Close") {
                        if hasEdits { confirmDiscard = true } else { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Close and keep the draft (Esc)")
                    .confirmationDialog("Save your changes to this draft?", isPresented: $confirmDiscard) {
                        Button("Save Draft") { store.saveDraft(draft) }
                        Button("Discard Changes", role: .destructive) { dismiss() }
                        Button("Keep Writing", role: .cancel) {}
                    } message: {
                        Text("The draft stays in Drafts either way.")
                    }
                } else {
                    Button("Discard") {
                        if hasEdits { confirmDiscard = true } else { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .confirmationDialog("Discard this message?", isPresented: $confirmDiscard) {
                        Button("Discard", role: .destructive) { dismiss() }
                        Button("Keep Writing", role: .cancel) {}
                    } message: {
                        Text("What you've written will be lost.")
                    }
                }
                Button {
                    store.send(draft)
                } label: {
                    HStack(spacing: 6) {
                        Text("Send")
                        Text("⌘↵").font(.system(size: 11)).opacity(0.7)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
            .padding(.leading, 14)
            .padding(.trailing, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 720, height: 600)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        Label("Drop to attach", systemImage: "paperclip")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Presented from the sheet itself; a modal open panel from inside a sheet can fail to appear.
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            attach(urls)
        }
        // `--attach <file>` in demo mode: the same path as choosing a file, so attaching can be checked without clicking.
        .onReceive(NotificationCenter.default.publisher(for: .nookDemoAttach)) { note in
            if let urls = note.object as? [URL] { attach(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in attach([url]) }
                }
            }
            return true
        }
        .onAppear {
            if draft.from.isEmpty { draft.from = store.accounts.first?.email ?? "" }
            // Start in To until it holds addresses to send to.
            focus = hasRecipients ? .body : .to
        }
        .onChange(of: draft.to) { suggest() }
        .onChange(of: draft.cc) { suggest() }
        .onChange(of: focus) { suggest() }
        .onChange(of: store.contactBook) { suggest() }
        .onDisappear { suggestions.clear() }
    }

    /// Remind me if nobody replies. ⌘⇧R steps through the choices.
    private var followUpMenu: some View {
        let chosen = ReminderTime.followUpChoices.first { $0.after == draft.followUpAfter }
        return Menu {
            ForEach(ReminderTime.followUpChoices, id: \.title) { choice in
                Toggle(isOn: Binding(get: { draft.followUpAfter == choice.after }, set: { _ in draft.followUpAfter = choice.after })) {
                    Text("If no reply in \(choice.title)")
                }
            }
            if draft.followUpAfter != nil {
                Divider()
                Button("Don't remind me") { draft.followUpAfter = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: chosen == nil ? "bell" : "bell.fill")
                    .font(.system(size: 13, weight: .medium))
                if let chosen {
                    Text("Remind me in \(chosen.title) if no reply")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(chosen == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
            .padding(.horizontal, chosen == nil ? 0 : 8)
            .frame(minWidth: 30, minHeight: 28)
            .background(chosen == nil ? Color.clear : Theme.accent.opacity(0.1), in: Capsule())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
        .help("Remind me if no reply (⌘⇧R)")
        .background {
            Button("Remind me if no reply", action: cycleFollowUp)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .hidden()
        }
    }

    private func cycleFollowUp() {
        let choices = ReminderTime.followUpChoices.map(\.after)
        guard let current = draft.followUpAfter, let index = choices.firstIndex(of: current) else {
            draft.followUpAfter = choices.first
            return
        }
        draft.followUpAfter = index + 1 < choices.count ? choices[index + 1] : nil
    }

    private var title: String {
        if draft.inReplyTo != nil { return "Reply" }
        if draft.subject.hasPrefix("Fwd:") { return "Forward" }
        return "New message"
    }

    private var hasEdits: Bool {
        draft.to != original.to || draft.cc != original.cc || draft.subject != original.subject || draft.body != original.body
            || draft.attachments.map(\.id) != original.attachments.map(\.id)
    }

    private var canSend: Bool {
        !draft.from.isEmpty && hasRecipients && !isOverLimit
    }

    private var isOverLimit: Bool {
        draft.attachments.reduce(0) { $0 + $1.size } > OutgoingAttachment.gmailLimit
    }

    /// The message you're replying to or forwarding, folded away until you want it. Showing it moves it into the
    /// editor, below what you've written, so you can read and trim it like the rest of the message.
    private var quotedSection: some View {
        Button(action: expandQuote) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 16)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Text("Show \(quotedLabel)")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .clickable()
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expandQuote() {
        let mine = draft.body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        draft.body = (mine.isEmpty ? "\n\n" : mine + "\n\n") + draft.quoted
        draft.quoted = ""
        focus = .body
    }

    private var quotedLabel: String {
        draft.inReplyTo == nil ? "forwarded message" : "quoted text"
    }

    private func pickFiles() {
        choosingFiles = true
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                store.showToast("Folders can't be attached. Zip it first.", isError: true)
                continue
            }
            do {
                draft.attachments.append(try OutgoingAttachment.fromFile(url))
            } catch {
                store.showToast("Couldn't attach \(url.lastPathComponent): \(error.localizedDescription)", isError: true)
            }
        }
    }

    private var hasRecipients: Bool {
        let recipients = Addresses.parseList(draft.to)
        return !recipients.isEmpty && recipients.allSatisfy { $0.email.contains("@") }
    }

    /// Suggests people for the address being typed in To or Cc.
    private func suggest() {
        let text: Binding<String>
        switch focus {
        case .to: text = $draft.to
        case .cc: text = $draft.cc
        default: return suggestions.clear()
        }
        suggestions.update(text: text.wrappedValue, book: store.contactBook) { contact in
            text.wrappedValue = Addresses.complete(text.wrappedValue, with: contact.address)
        }
    }

    private func recipientField<Accessory: View>(_ label: String, text: Binding<String>, focus field: Field, @ViewBuilder accessory: () -> Accessory) -> some View {
        self.field(label, text: text, focus: field, accessory: accessory)
            .overlay(alignment: .topLeading) {
                if focus == field, !suggestions.items.isEmpty {
                    RecipientSuggestionList(suggestions: suggestions)
                        .offset(x: 82, y: 34)
                }
            }
            .zIndex(focus == field ? 1 : 0)
    }

    private func field<Accessory: View>(_ label: String, text: Binding<String>, focus field: Field, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focus, equals: field)
            accessory()
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Divider().opacity(0.5).padding(.horizontal, 20) }
    }
}
