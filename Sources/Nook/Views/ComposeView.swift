import NookCore
import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var showCc: Bool
    @State private var confirmDiscard = false
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if store.accounts.count > 1 {
                    Picker("From", selection: $draft.from) {
                        ForEach(store.accounts) { account in
                            Text(account.email).tag(account.email)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
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
                .font(.system(size: 14))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)

            HStack(spacing: 10) {
                Text("Sent directly from this Mac through Gmail")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 660, height: 540)
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

    private var title: String {
        if draft.inReplyTo != nil { return "Reply" }
        if draft.subject.hasPrefix("Fwd:") { return "Forward" }
        return "New message"
    }

    private var hasEdits: Bool {
        draft.to != original.to || draft.cc != original.cc || draft.subject != original.subject || draft.body != original.body
    }

    private var canSend: Bool {
        !draft.from.isEmpty && hasRecipients
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
