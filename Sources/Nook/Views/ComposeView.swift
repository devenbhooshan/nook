import NookCore
import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var showCc: Bool
    @FocusState private var focus: Field?

    private enum Field: Hashable { case to, cc, subject, body }

    init(draft: Draft) {
        _draft = State(initialValue: draft)
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

            field("To", text: $draft.to, focus: .to) {
                if !showCc {
                    Button("Cc") { showCc = true; focus = .cc }
                        .buttonStyle(.textLink)
                        .font(.system(size: 12))
                }
            }
            if showCc {
                field("Cc", text: $draft.cc, focus: .cc) { EmptyView() }
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
                Button("Discard") { dismiss() }
                    .keyboardShortcut(.cancelAction)
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
            focus = draft.to.isEmpty ? .to : .body
        }
    }

    private var title: String {
        if draft.inReplyTo != nil { return "Reply" }
        if draft.subject.hasPrefix("Fwd:") { return "Forward" }
        return "New message"
    }

    private var canSend: Bool {
        !draft.from.isEmpty && !Addresses.parseList(draft.to).isEmpty && Addresses.parseList(draft.to).allSatisfy { $0.email.contains("@") }
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
