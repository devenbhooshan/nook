import NookCore
import SwiftUI

/// Settings → Rules: the list of rules, each with an on/off switch.
struct RulesSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: MailRule?
    @State private var editingIsNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if store.rules.isEmpty {
                        Text("No rules yet. For example: Stripe emails that say “Subscription update” skip the inbox and get marked as read.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.rules) { rule in
                        HStack(alignment: .center, spacing: 10) {
                            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { store.setRule(rule, enabled: $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                                .help(rule.isEnabled ? "Turn this rule off" : "Turn this rule on")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                                Text(rule.summary)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button {
                                edit(rule, isNew: false)
                            } label: {
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.quiet)
                            .help("Edit rule")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { edit(rule, isNew: false) }
                    }
                    Button {
                        edit(MailRule(conditions: [RuleCondition(field: .from, value: "")], actions: RuleActions(skipInbox: true)), isNew: true)
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    .buttonStyle(.textLink)
                } header: {
                    Text("Rules file predictable mail as it arrives, before you see it. They're exact, so they run before the on-device model, and it leaves mail they tag alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: editingIsNew)
                .environmentObject(store)
        }
    }

    private func edit(_ rule: MailRule, isNew: Bool) {
        editingIsNew = isNew
        editing = rule
    }
}

/// Creates or edits one rule, with a live preview of the recent emails it matches.
struct RuleEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MailRule
    @State private var applyToExisting: Bool
    @State private var preview: RulePreview?
    @State private var confirmingDelete = false
    let isNew: Bool

    init(rule: MailRule, isNew: Bool) {
        _rule = State(initialValue: rule)
        _applyToExisting = State(initialValue: isNew)
        self.isNew = isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New Rule" : "Edit Rule")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Form {
                Section {
                    TextField("Name", text: $rule.name, prompt: Text("For example, Stripe renewals"))
                }

                Section {
                    ForEach($rule.conditions) { $condition in
                        HStack(spacing: 8) {
                            Picker("Field", selection: $condition.field) {
                                ForEach(RuleCondition.Field.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text("contains")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            TextField("Text", text: $condition.value, prompt: Text(placeholder(for: condition.field)))
                                .labelsHidden()
                            Button {
                                rule.conditions.removeAll { $0.id == condition.id }
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.quiet)
                            .disabled(rule.conditions.count == 1)
                            .help("Remove condition")
                        }
                    }
                    Button {
                        rule.conditions.append(RuleCondition(field: .text, value: ""))
                    } label: {
                        Label("Add Condition", systemImage: "plus")
                    }
                    .buttonStyle(.textLink)
                } header: {
                    sectionHeader("When an email matches all of these")
                }

                Section {
                    HStack(spacing: 18) {
                        Toggle("Skip the inbox", isOn: $rule.actions.skipInbox)
                            .help("Archives it. It stays in All Mail and search.")
                        Toggle("Mark as read", isOn: $rule.actions.markRead)
                        Toggle("Star", isOn: $rule.actions.star)
                    }
                    .toggleStyle(.checkbox)
                    Picker("Add tag", selection: tagBinding) {
                        Text("None").tag("")
                        ForEach(store.tags) { Text($0.name).tag($0.name) }
                    }
                } header: {
                    sectionHeader("Then")
                }

                Section {
                    previewContent
                    Toggle("Also apply to matching emails you already have", isOn: $applyToExisting)
                } header: {
                    sectionHeader("Preview")
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete Rule", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Rule" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rule.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 560, height: 600)
        .task(id: rule) {
            // Wait for typing to settle before scanning mail.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            preview = await store.previewMatches(for: rule)
        }
        .confirmationDialog("Delete this rule?", isPresented: $confirmingDelete) {
            Button("Delete Rule", role: .destructive) {
                store.deleteRule(rule)
                dismiss()
            }
        } message: {
            Text("Mail it already filed stays where it is.")
        }
    }

    @ViewBuilder private var previewContent: some View {
        if !rule.isValid {
            Text(rule.actions.doesSomething ? "Add some text to match." : "Choose at least one thing to do.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if let preview {
            if preview.examples.isEmpty {
                Text("Doesn't match any of your recent email.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Matches \(preview.count) recent \(preview.count == 1 ? "email" : "emails"), like:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ForEach(preview.examples) { message in
                        HStack(spacing: 6) {
                            Text(message.fromName.isEmpty ? message.fromEmail : message.fromName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text(message.subject)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else {
            Text("Checking your recent email…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var tagBinding: Binding<String> {
        Binding(get: { rule.actions.tag ?? "" }, set: { rule.actions.tag = $0.isEmpty ? nil : $0 })
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).textCase(nil)
    }

    private func placeholder(for field: RuleCondition.Field) -> String {
        switch field {
        case .from: "notifications@stripe.com"
        case .to: "team@yourcompany.com"
        case .subject: "Payment of"
        case .text: "Subscription update"
        }
    }

    private func save() {
        rule.name = rule.name.trimmingCharacters(in: .whitespaces)
        rule.conditions = rule.conditions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        if rule.name.isEmpty { rule.name = rule.conditions.first?.value ?? "Rule" }
        store.saveRule(rule, applyToExisting: applyToExisting)
        dismiss()
    }
}
