import NookCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String {
    case general, accounts, tags, intelligence, integrations, privacy
    static let storageKey = "settings.tab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts.rawValue)
            TagsSettings()
                .tabItem { Label("Tags", systemImage: "tag") }
                .tag(SettingsTab.tags.rawValue)
            IntelligenceSettings()
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
                .tag(SettingsTab.intelligence.rawValue)
            IntegrationsSettings()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.integrations.rawValue)
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy.rawValue)
        }
        .frame(width: 580, height: 480)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(AppStore.dockBadgeKey) private var dockBadge = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNote: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Nook at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginItemNote {
                    Text(loginItemNote).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Nook syncs whenever it's running, including with its window closed. Click the Dock icon to bring the window back, and press ⌘Q to quit.")
            }
            Section {
                Toggle("Show unread count on the Dock icon", isOn: $dockBadge)
                    .onChange(of: dockBadge) { store.updateDockBadge() }
            } footer: {
                Text("Counts unread conversations in your inboxes, across all accounts.")
            }
        }
        .formStyle(.grouped)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        // Demo mode never touches your real login items.
        guard !store.isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemNote = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Nook in System Settings → General → Login Items to finish."
                : nil
        } catch {
            loginItemNote = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct AccountsSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingRemoval: Account?

    var body: some View {
        Form {
            // Without the Google client, nothing below can sign in, so ask for it first.
            if !store.hasGoogleClient {
                Section {
                    GoogleClientForm()
                } header: {
                    Text("Step 1: Add your Google client")
                }
            }

            Section(store.hasGoogleClient ? "Accounts" : "Step 2: Sign in") {
                if store.accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.accounts) { account in
                    HStack(spacing: 10) {
                        AccountDot(colorIndex: account.colorIndex, size: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.email)
                            Text(status(for: account)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.hasGoogleClient, store.needsSignIn(account.email) || store.photoAccess[account.email] == .needsPermission {
                            Button(store.isSigningIn ? "Waiting for Google…" : "Sign in again") { store.addAccount(hint: account.email) }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.isSigningIn)
                                .help("Opens Google sign-in. Choose \(account.email).")
                        }
                        Button("Remove…") { pendingRemoval = account }
                    }
                }
                HStack {
                    if store.hasGoogleClient {
                        Spacer()
                        Button(store.isSigningIn ? "Waiting for Google…" : "Add Gmail Account") { store.addAccount() }
                            .disabled(store.isSigningIn)
                    } else {
                        // Say what's missing instead of showing buttons that look clickable but aren't.
                        Text("Signing in needs your Google client ID and secret, above.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if store.hasGoogleClient {
                Section {
                    GoogleClientForm()
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(pendingRemoval?.email ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove Account and Local Mail", role: .destructive) { store.removeAccount(account.email) }
        } message: { _ in
            Text("Nook deletes this account's mail from this Mac and forgets its sign-in. Nothing changes in Gmail.")
        }
    }

    private func status(for account: Account) -> String {
        if store.expiredSignIns.contains(account.email) {
            return "Google ended this sign-in, so it isn't syncing. While your Google Cloud app is in Testing, Google ends sign-ins after 7 days."
        }
        if store.needsSignIn(account.email) {
            return store.hasGoogleClient
                ? "Signed out. Sign in again to resume syncing. Your mail stays on this Mac."
                : "Signed out. Your mail stays on this Mac."
        }
        if let error = store.syncErrors[account.email] { return error }
        guard let lastSync = account.lastSync else { return "Not synced yet" }
        let synced = "Synced \(lastSync.formatted(.relative(presentation: .named)))"
        switch store.photoAccess[account.email] {
        case .needsPermission: return synced + ". Sign in again to show profile photos."
        case .apiDisabled: return synced + ". Profile photos need the People API turned on in Google Cloud."
        default: return synced
        }
    }
}

private struct TagsSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var rows: [TagRow] = []
    @State private var dirty = false

    /// A tag being edited. The id stays put while the name changes, so typing doesn't rebuild the row, and
    /// `originalName` lets Save carry a renamed tag's assignments over.
    private struct TagRow: Identifiable, Equatable {
        let id = UUID()
        var originalName: String?
        var tag: Tag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ForEach($rows) { $row in
                        let tag = $row.tag
                        HStack(alignment: .top, spacing: 10) {
                            Menu {
                                ForEach(Theme.palette.indices, id: \.self) { index in
                                    Button { tag.wrappedValue.colorIndex = index; dirty = true } label: {
                                        Label("Color \(index + 1)", systemImage: tag.wrappedValue.colorIndex == index ? "checkmark.circle.fill" : "circle.fill")
                                    }
                                }
                            } label: {
                                Circle().fill(Theme.color(tag.wrappedValue.colorIndex)).frame(width: 12, height: 12)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.quiet)
                            .fixedSize()
                            .help("Tag color")
                            .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Name", text: tag.name)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, weight: .medium))
                                TextField("Describe which emails get this tag", text: tag.description, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1...3)
                            }
                            Toggle("Inbox tab", isOn: tag.isSplit)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .help("Give this tag its own tab in the split inbox")
                            Button {
                                rows.removeAll { $0.id == row.id }
                                dirty = true
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.quiet)
                            .help("Remove tag")
                        }
                        .onChange(of: row) { dirty = true }
                    }
                    Button {
                        rows.append(TagRow(tag: Tag(name: uniqueName(), description: "", colorIndex: rows.count)))
                        dirty = true
                    } label: {
                        Label("Add Tag", systemImage: "plus")
                    }
                    .buttonStyle(.textLink)
                } header: {
                    Text("The on-device model reads each description to decide which tags fit an email. Tags marked as inbox tabs split your inbox; everything else lands in Other.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Re-tag All Mail") { store.retagAll() }
                    .help("Clears automatic tags and runs the model again. Tags you added by hand stay.")
                Spacer()
                Button("Revert") { load() }.disabled(!dirty)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!dirty || hasDuplicateNames)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear(perform: load)
    }

    private var hasDuplicateNames: Bool {
        let names = rows.map { $0.tag.name.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return Set(names).count != names.count
    }

    private func load() {
        rows = store.tags.map { TagRow(originalName: $0.name, tag: $0) }
        DispatchQueue.main.async { dirty = false }
    }

    private func save() {
        var tags: [Tag] = []
        var renames: [String: String] = [:]
        for row in rows {
            var tag = row.tag
            tag.name = tag.name.trimmingCharacters(in: .whitespaces)
            guard !tag.name.isEmpty else { continue }
            if let original = row.originalName, original != tag.name { renames[original] = tag.name }
            tags.append(tag)
        }
        store.saveTags(tags, renames: renames)
        for index in rows.indices { rows[index].originalName = rows[index].tag.name }
        DispatchQueue.main.async { dirty = false }
    }

    private func uniqueName() -> String {
        var index = 1
        while rows.contains(where: { $0.tag.name == "New Tag \(index)" }) { index += 1 }
        return "New Tag \(index)"
    }
}

private struct IntelligenceSettings: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(TaggingSettings.engineKey) private var engine = TagEngine.automatic.rawValue
    @AppStorage(TaggingSettings.ollamaURLKey) private var ollamaURL = OllamaTagModel.defaultURL.absoluteString
    @AppStorage(TaggingSettings.ollamaModelKey) private var ollamaModel = TaggingSettings.defaultOllamaModel
    @State private var installedModels: [String]?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Picker("Tag with", selection: $engine) {
                    ForEach(TagEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                LabeledContent("Apple Intelligence") {
                    Text(AppleTagModel.statusDescription)
                        .foregroundStyle(AppleTagModel.isAvailable ? .green : .secondary)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Automatic uses Ollama when it's running with your model and falls back to Apple Intelligence. Either way, your mail never leaves this Mac.")
            }

            Section("Ollama") {
                TextField("Server", text: $ollamaURL)
                if !TaggingSettings.isLocal(ollamaURL: ollamaURL) {
                    Label("This server isn't on this Mac. Nook sends each email's sender, recipients, subject and the start of its text there to tag it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
                HStack {
                    if let installedModels, !installedModels.isEmpty {
                        Picker("Model", selection: $ollamaModel) {
                            ForEach(Array(Set(installedModels + [ollamaModel])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField("Model", text: $ollamaModel)
                    }
                    Button(checking ? "Checking…" : "Refresh") { Task { await refresh() } }
                        .disabled(checking)
                }
                LabeledContent("Status") {
                    Text(ollamaStatus).foregroundStyle(installedModels == nil ? .secondary : .primary)
                }
            }

            Section("Status") {
                LabeledContent("Waiting to be tagged", value: "\(store.taggerStatus.pending)")
                if let error = store.taggerStatus.lastError {
                    LabeledContent("Last problem") { Text(error).foregroundStyle(.orange).multilineTextAlignment(.trailing) }
                }
                HStack {
                    Spacer()
                    Button("Tag Now") { store.runTagger() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: engine) { store.runTagger() }
        .onChange(of: ollamaModel) { store.runTagger() }
    }

    private var ollamaStatus: String {
        guard let installedModels else { return "Not running. Install from ollama.com, then run `ollama pull \(ollamaModel)`." }
        if installedModels.contains(ollamaModel) || installedModels.contains("\(ollamaModel):latest") {
            return "Ready"
        }
        return "Running, but \(ollamaModel) isn't installed. Run `ollama pull \(ollamaModel)`."
    }

    private func refresh() async {
        checking = true
        installedModels = await OllamaTagModel.installedModels(baseURL: URL(string: ollamaURL) ?? OllamaTagModel.defaultURL)
        checking = false
    }
}

private struct IntegrationsSettings: View {
    @AppStorage(MCPSettings.enabledKey) private var mcpEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Let AI assistants on this Mac use Nook (MCP)", isOn: $mcpEnabled)
            } footer: {
                Text("Assistants like Claude Code and Claude Desktop can search and read your mail through Nook's local MCP server, and open drafts for you to review. They can't send mail, and nothing is exposed to the network: the server only talks to the app that launches it. What the assistant does with your mail is up to that assistant.")
            }

            Section("Connect") {
                MCPConnectView()
                    .padding(.vertical, 4)
            }

            Section("Tools") {
                LabeledContent("Read", value: "list_accounts, list_tags, search_threads, get_thread")
                LabeledContent("Draft (opens in Nook)", value: "draft_reply, compose_draft")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("privacy.blockRemoteContent") private var blockRemoteContent = true
    @AppStorage(BrandLogos.enabledKey) private var brandLogos = false

    var body: some View {
        Form {
            Section {
                Toggle("Block remote images and content", isOn: $blockRemoteContent)
            } footer: {
                Text("Remote images often act as tracking pixels that report when, where and on what device you opened a message. When blocked, you can still load them for one conversation.")
            }
            Section {
                Toggle("Show company logos for senders", isOn: $brandLogos)
                    .onChange(of: brandLogos) { _, enabled in store.setBrandLogos(enabled) }
            } footer: {
                Text("Uses BIMI: Nook looks up each sender's domain in DNS and downloads the logo from the company's own server, once. That company can see the request. Off by default.")
            }
            Section("Where your data lives") {
                LabeledContent("Mail and tags") {
                    Text("~/Library/Application Support/Nook").textSelection(.enabled)
                }
                LabeledContent("Sign-in tokens", value: "macOS Keychain, this Mac only")
                LabeledContent("Profile photos") {
                    Text("~/Library/Caches/com.devenbhooshan.nook/Avatars").textSelection(.enabled)
                }
                LabeledContent("Network", value: "Only Google: Gmail, sign-in, and contacts for photos")
                LabeledContent("AI tagging", value: "On this Mac (Apple Intelligence or Ollama)")
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        if let url = try? Database.defaultURL() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
