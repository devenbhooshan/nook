import AppKit
import Combine
import NookCore
import SwiftUI

extension Notification.Name {
    static let nookDataChanged = Notification.Name("NookDataChanged")
    static let nookTaggerStatus = Notification.Name("NookTaggerStatus")
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var canUndo: Bool
    var isError: Bool
}

struct PaletteCommand: Identifiable {
    let id = UUID()
    var title: String
    var section: String
    var systemImage: String
    var shortcut: String?
    var action: () -> Void
}

enum PaletteMode: Equatable {
    case everything
    case tags
}

/// The app's state and the actions the UI and keyboard can take. Everything here runs on the main actor;
/// network and model work happens in `SyncEngine` and `Tagger`.
@MainActor
final class AppStore: ObservableObject {
    // MARK: Data

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var unreadCounts: [String: Int] = [:]
    @Published private(set) var splitCounts = SplitCounts()
    /// Unread conversations per split. Only used to decide where to show a quiet "something new" dot.
    @Published private(set) var unreadSplitCounts = SplitCounts()

    // MARK: What's showing

    @Published private(set) var scope: String?
    @Published private(set) var mailbox: Mailbox = .inbox
    @Published private(set) var split: InboxSplit = .everything
    @Published var searchText = ""
    @Published var selectedID: ThreadSummary.ID?
    @Published private(set) var openThread: ThreadSummary?
    @Published private(set) var openMessages: [MailMessage] = []
    @Published var remoteContentAllowed: Set<ThreadSummary.ID> = []

    // MARK: Status

    @Published private(set) var isSyncing = false
    /// Whether any mail is stored at all. Separates "your first sync is running" from "this view is empty".
    @Published private(set) var hasStoredMail = false
    /// Accounts whose stored sign-in is missing, for example after a Keychain reset.
    @Published private(set) var signedOutAccounts: [String] = []
    @Published private(set) var lastSynced: Date?
    @Published private(set) var syncErrors: [String: String] = [:]
    @Published private(set) var taggerStatus = TaggerStatus()
    @Published private(set) var isSigningIn = false
    @Published private(set) var onboardingStep: OnboardingStep = .connectAccount
    @Published private(set) var toast: Toast?

    // MARK: Overlays

    @Published var showPalette = false
    @Published var paletteMode: PaletteMode = .everything
    @Published var showHelp = false
    @Published var draft: Draft?
    /// Recipient suggestions for the To and Cc fields. Rebuilt in the background each time a message is started.
    @Published private(set) var contactBook = ContactBook()
    private var contactsLoading = false
    @Published var showSidebar = false {
        didSet { defaults.set(showSidebar, forKey: "ui.showSidebar") }
    }
    /// The inbox shows only conversations with something unread. Remembered between launches.
    @Published private(set) var unreadOnly = false

    /// Where preferences live. Demo mode uses its own, emptied at launch, so it never changes the real app's settings.
    let defaults: UserDefaults
    static let demoDefaultsSuite = "com.devenbhooshan.nook.demo"
    /// Conversations read while the unread filter is on stay listed until you change views.
    private var keptVisible: Set<ThreadSummary.ID> = []
    /// How many conversations the list holds. Grows a page at a time as you scroll.
    private var listLimit = AppStore.pageSize
    static let pageSize = 100
    @Published private(set) var focusSearchRequest = 0

    @Published private(set) var isFullScreen = false
    private(set) weak var mainWindow: NSWindow?
    /// The open conversation's scroll view, so the keyboard can scroll it.
    weak var readerScrollView: NSScrollView?

    /// Remembers the main window and tracks full screen, where the traffic lights are hidden.
    func attach(to window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        DemoData.applyWindowOptions(to: window)
        // Replace, don't add: the window is recreated each time it's reopened from the Dock.
        windowSubscriptions.removeAll()
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self, weak window] _ in self?.isFullScreen = window?.styleMask.contains(.fullScreen) ?? false }
                .store(in: &windowSubscriptions)
        }
    }

    let repo: MailRepository
    let secrets: SecretStore
    private let sync: SyncEngine
    private let tagger: Tagger
    let isDemo: Bool
    private var sendingDrafts: Set<UUID> = []
    /// The previous mail store couldn't be unlocked and was set aside; mail downloads again.
    var startedWithFreshStore = false
    private var demoOnboardingCompleted: Bool? = true
    private var demoTaggingReviewed = true
    /// Undo for the toast currently on screen; it goes away with the toast.
    private var undoAction: (id: UUID, action: () -> Void)?
    /// The last Gmail change sent per account, so changes reach Gmail in the order they were made.
    private var remoteQueue: [String: Task<Void, Never>] = [:]
    private var windowSubscriptions = Set<AnyCancellable>()
    private var started = false
    private var reloadPending = false
    private var subscriptions = Set<AnyCancellable>()
    private var syncLoop: Task<Void, Never>?
    private lazy var keyRouter = KeyRouter(store: self)

    static let syncInterval: Duration = .seconds(30)

    /// - Parameters:
    ///   - makeService: How to reach Gmail for an account. Defaults to the real API with Keychain tokens.
    ///   - isDemo: Demo stores keep onboarding state in memory, so they never touch the real app's settings.
    init(repo: MailRepository, secrets: SecretStore, makeService: SyncEngine.ServiceFactory? = nil, isDemo: Bool = false) {
        self.repo = repo
        self.secrets = secrets
        self.isDemo = isDemo
        if isDemo, let demo = UserDefaults(suiteName: Self.demoDefaultsSuite) {
            demo.removePersistentDomain(forName: Self.demoDefaultsSuite)
            defaults = demo
        } else {
            defaults = .standard
        }
        let defaults = defaults
        showSidebar = defaults.bool(forKey: "ui.showSidebar")
        unreadOnly = defaults.bool(forKey: "ui.unreadOnly")

        let notify: @Sendable () -> Void = {
            Task { @MainActor in NotificationCenter.default.post(name: .nookDataChanged, object: nil) }
        }
        self.sync = SyncEngine(repo: repo, makeService: makeService ?? { email in
            guard let tokens = secrets.tokens(for: email) else { throw GmailError.notSignedIn(email) }
            let provider = OAuthTokenProvider(email: email, tokens: tokens, config: GoogleClientConfig.load(from: secrets), store: secrets)
            return GmailClient(tokens: provider)
        }, onChange: notify)

        self.tagger = Tagger(
            repo: repo,
            modelProvider: { [suite = isDemo ? Self.demoDefaultsSuite : nil] in
                await TaggingSettings.load(suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard).resolveModel()
            },
            onUpdate: { status in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .nookTaggerStatus, object: nil, userInfo: ["status": status])
                }
            }
        )
        // Decide between onboarding and the inbox before the first frame, so neither flashes.
        loadAccounts(checkSignIns: true)
    }

    static func live() -> AppStore {
        let store = makeLive()
        // The app delegate starts it, so sync runs even if the app launches without its window.
        current = store
        return store
    }

    private static func makeLive() -> AppStore {
        if CommandLine.arguments.contains("--demo") { return DemoData.store() }
        LegacySettings.migrateIfNeeded()
        do {
            // Encrypted at rest with a key from the Keychain. The first launch after updating converts the old,
            // unencrypted store in place. The UI gets its own read-only connection, so it never waits on a sync.
            let secrets = KeychainStore()
            let opened = try MailStore.open(path: try Database.defaultURL().path, secrets: secrets)
            let store = AppStore(repo: opened.repository, secrets: secrets)
            store.startedWithFreshStore = opened.startedFresh
            return store
        } catch {
            fatalError("Nook couldn't open its mail store: \(error.localizedDescription)")
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Self.current = self
        loadAccounts()
        tags = repo.tags()
        reload()

        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.listLimit = AppStore.pageSize
                self?.reload(resetSelection: true)
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .nookDataChanged)
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .nookTaggerStatus)
            .compactMap { $0.userInfo?["status"] as? TaggerStatus }
            .sink { [weak self] status in
                self?.taggerStatus = status
                self?.scheduleReload()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.syncNow() }
            .store(in: &subscriptions)

        keyRouter.install()
        DemoData.applyLaunchOptions(to: self)
        if startedWithFreshStore {
            showToast("Nook couldn't unlock its saved mail, so it's downloading it again.", isError: true)
        }
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncNow()
                try? await Task.sleep(for: Self.syncInterval)
            }
        }
    }

    // MARK: Loading

    /// - Parameter checkSignIns: Re-read sign-in state from the Keychain. That's slow-ish, so it happens only at launch
    ///   and when it can have changed (accounts added or removed, a sync reporting a missing sign-in), not every sync.
    private func loadAccounts(checkSignIns: Bool = false) {
        accounts = repo.accounts()
        if checkSignIns {
            hasGoogleClient = isDemo || googleConfig.isComplete
            // Demo accounts never have stored sign-ins; don't call them signed out.
            signedOutAccounts = isDemo ? [] : accounts.map(\.email).filter { secrets.tokens(for: $0) == nil }
        } else {
            signedOutAccounts.removeAll { email in !accounts.contains { $0.email == email } }
        }
        if let scope, !accounts.contains(where: { $0.email == scope }) { self.scope = nil }
        refreshOnboarding()
    }

    // MARK: Onboarding

    private var onboardingCompleted: Bool? {
        get { isDemo ? demoOnboardingCompleted : UserDefaults.standard.object(forKey: OnboardingStep.completedKey) as? Bool }
        set {
            if isDemo { demoOnboardingCompleted = newValue } else { UserDefaults.standard.set(newValue, forKey: OnboardingStep.completedKey) }
        }
    }

    private var taggingReviewed: Bool {
        get { isDemo ? demoTaggingReviewed : UserDefaults.standard.bool(forKey: OnboardingStep.taggingReviewedKey) }
        set {
            if isDemo { demoTaggingReviewed = newValue } else { UserDefaults.standard.set(newValue, forKey: OnboardingStep.taggingReviewedKey) }
        }
    }

    private func refreshOnboarding() {
        // Starting from no accounts means running the whole flow, including tagging and the optional assistant step.
        if accounts.isEmpty {
            if onboardingCompleted != false { onboardingCompleted = false }
            if taggingReviewed { taggingReviewed = false }
        }
        let step = OnboardingStep.current(hasAccounts: !accounts.isEmpty, completed: onboardingCompleted, taggingReviewed: taggingReviewed)
        if step != onboardingStep {
            withAnimation(.snappy(duration: 0.25)) { onboardingStep = step }
        }
    }

    /// Leaves the tagging step, starting the tagger with whatever was chosen.
    func finishTaggingSetup() {
        taggingReviewed = true
        refreshOnboarding()
        runTagger()
    }

    func finishOnboarding() {
        onboardingCompleted = true
        refreshOnboarding()
    }

    /// For demo screenshots of onboarding after mail is connected.
    func restartOnboarding(at step: OnboardingStep) {
        onboardingCompleted = false
        taggingReviewed = step == .connectAssistant
        refreshOnboarding()
    }

    /// Coalesces bursts of change notifications (a sync stores many batches) into one reload.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    var currentQuery: ThreadQuery {
        let search = SearchQuery.parse(searchText)
        // Splits divide the inbox; other mailboxes and search results show everything.
        let inInbox = mailbox == .inbox && search == nil
        return ThreadQuery(
            account: scope, mailbox: mailbox, split: inInbox ? self.split : .everything, search: search,
            unreadOnly: inInbox && unreadOnly, keepVisible: keptVisible, limit: listLimit
        )
    }

    /// Loads the next page when a row near the end of the list appears.
    func loadMoreIfNeeded(after thread: ThreadSummary) {
        guard threads.count >= listLimit,
              let index = threads.firstIndex(where: { $0.id == thread.id }),
              index >= threads.count - 20 else { return }
        listLimit += Self.pageSize
        reload()
    }

    func reload(resetSelection: Bool = false) {
        let previous = threads
        let previousIndex = selectedID.flatMap { id in previous.firstIndex { $0.id == id } }
        let updated = repo.threads(currentQuery)
        if updated != threads { threads = updated }

        if resetSelection || selectedID == nil {
            selectedID = threads.first?.id
        } else if let id = selectedID, !threads.contains(where: { $0.id == id }) {
            // The selected thread left the list (archived elsewhere, say). Select its neighbor.
            selectedID = threads.isEmpty ? nil : threads[min(previousIndex ?? 0, threads.count - 1)].id
        }

        unreadCounts = repo.unreadInboxCounts()
        updateDockBadge()
        hasStoredMail = !threads.isEmpty || repo.hasMessages()
        splitCounts = repo.splitCounts(account: scope)
        unreadSplitCounts = repo.splitCounts(account: scope, unreadOnly: true)
        if let open = openThread {
            let messages = repo.threadMessages(account: open.account, threadId: open.threadId)
            if messages.isEmpty {
                closeThread()
            } else if messages != openMessages {
                openMessages = messages
            }
        }
    }

    // MARK: Navigation

    var selectedThread: ThreadSummary? {
        selectedID.flatMap { id in threads.first { $0.id == id } }
    }

    /// The thread actions apply to: the open one, otherwise the selected one.
    var currentThread: ThreadSummary? { openThread ?? selectedThread }

    var isSearching: Bool { SearchQuery.parse(searchText) != nil }

    var effectiveMailbox: Mailbox { currentQuery.effectiveMailbox }

    func setScope(_ email: String?) {
        guard scope != email || openThread != nil else { return }
        scope = email
        keptVisible = []
        listLimit = Self.pageSize
        closeThread()
        reload(resetSelection: true)
    }

    func setMailbox(_ mailbox: Mailbox) {
        self.mailbox = mailbox
        split = .everything
        keptVisible = []
        listLimit = Self.pageSize
        searchText = ""
        closeThread()
        reload(resetSelection: true)
    }

    /// The split inbox tabs to show right now.
    var visibleSplits: [InboxSplit] {
        guard mailbox == .inbox, !isSearching else { return [] }
        return InboxSplit.visible(tags: tags, counts: splitCounts, selected: split)
    }

    /// Shows one split of the inbox.
    func setSplit(_ split: InboxSplit) {
        mailbox = .inbox
        searchText = ""
        self.split = split
        keptVisible = []
        listLimit = Self.pageSize
        closeThread()
        reload(resetSelection: true)
    }

    /// ⇧U: show only unread conversations in the inbox, or everything again.
    func toggleUnreadOnly() {
        unreadOnly.toggle()
        defaults.set(unreadOnly, forKey: "ui.unreadOnly")
        keptVisible = []
        listLimit = Self.pageSize
        if mailbox != .inbox || isSearching { setMailbox(.inbox) } else { reload(resetSelection: true) }
    }

    /// Tab and Shift-Tab: move between splits, wrapping around.
    func cycleSplit(by offset: Int) {
        let splits = visibleSplits
        guard splits.count > 1 else { return }
        let index = splits.firstIndex(of: split) ?? 0
        setSplit(splits[(index + offset + splits.count) % splits.count])
    }

    func move(by offset: Int) {
        guard !threads.isEmpty else { return }
        let current = (openThread ?? selectedThread).flatMap { thread in threads.firstIndex { $0.id == thread.id } }
        let target = max(0, min(threads.count - 1, (current ?? -1) + offset))
        if openThread != nil {
            open(threads[target])
        } else {
            selectedID = threads[target].id
        }
    }

    func open(_ thread: ThreadSummary? = nil) {
        guard let thread = thread ?? selectedThread else { return }
        selectedID = thread.id
        if unreadOnly { keptVisible.insert(thread.id) }
        openThread = thread
        openMessages = repo.threadMessages(account: thread.account, threadId: thread.threadId)
        if thread.isUnread { markRead(thread) }
    }

    func closeThread() {
        openThread = nil
        openMessages = []
    }

    /// Esc: close the thread, then clear the search, then go back to the whole inbox.
    func back() {
        if openThread != nil {
            closeThread()
        } else if !searchText.isEmpty {
            searchText = ""
        } else if split != .everything {
            setSplit(.everything)
        }
    }

    func focusSearch() {
        closeThread()
        focusSearchRequest += 1
    }

    func openPalette(_ mode: PaletteMode = .everything) {
        paletteMode = mode
        showPalette = true
    }

    // MARK: Sync

    func syncNow() {
        guard !isSyncing, !accounts.isEmpty else { return }
        isSyncing = true
        let emails = accounts.map(\.email)
        let sync = sync
        let tagger = tagger
        // Tag alongside the sync rather than after it: the tagger keeps draining while new batches land,
        // so a long first sync doesn't leave the inbox untagged until every account finishes.
        Task.detached { await tagger.run() }
        Task {
            let errors = await withTaskGroup(of: (String, String?).self) { group in
                for email in emails {
                    group.addTask {
                        do {
                            try await sync.sync(email)
                            return (email, nil)
                        } catch {
                            return (email, error.localizedDescription)
                        }
                    }
                }
                var errors: [String: String] = [:]
                for await (email, error) in group { errors[email] = error }
                return errors
            }
            syncErrors = errors.compactMapValues { $0 }
            isSyncing = false
            lastSynced = Date()
            loadAccounts(checkSignIns: !syncErrors.isEmpty)
            reload()
            Task.detached { await tagger.run() }
        }
    }

    func retagAll() {
        try? repo.resetAutoTags()
        reload()
        let tagger = tagger
        Task.detached { await tagger.run() }
    }

    func runTagger() {
        let tagger = tagger
        Task.detached { await tagger.run() }
    }

    // MARK: Accounts

    var googleConfig: GoogleClientConfig { GoogleClientConfig.load(from: secrets) }

    /// Whether the Google OAuth client is filled in. Cached so views don't read the Keychain on every render.
    @Published private(set) var hasGoogleClient = false

    func saveGoogleConfig(clientId: String, clientSecret: String) {
        do {
            let config = GoogleClientConfig(clientId: clientId, clientSecret: clientSecret)
            try config.save(to: secrets)
            if hasGoogleClient != config.isComplete { hasGoogleClient = config.isComplete }
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func addAccount() {
        guard !isSigningIn else { return }
        isSigningIn = true
        let config = googleConfig
        Task {
            defer { isSigningIn = false }
            do {
                let result = try await GoogleOAuth.signIn(config: config, openURL: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                })
                try secrets.setTokens(result.tokens, for: result.email)
                try repo.addAccount(email: result.email, name: result.name)
                await sync.forget(result.email)
                NSApp.activate()
                loadAccounts(checkSignIns: true)
                syncErrors[result.email] = nil
                showToast("Added \(result.email)")
                // Start this account now rather than waiting for a sync round that may already be running.
                let sync = sync
                let tagger = tagger
                Task {
                    do { try await sync.sync(result.email) } catch { syncErrors[result.email] = error.localizedDescription }
                    loadAccounts()
                    reload()
                    Task.detached { await tagger.run() }
                }
            } catch is CancellationError {
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    func removeAccount(_ email: String) {
        // Stop the account's sync before deleting its mail, so a batch in flight can't write it back.
        let sync = sync
        Task {
            await sync.forget(email)
            do {
                try repo.removeAccount(email)
                secrets.removeTokens(for: email)
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
            if scope == email { scope = nil }
            closeThread()
            loadAccounts()
            reload(resetSelection: true)
        }
    }

    /// Whether an account has lost its stored sign-in (for example, after Keychain was reset) and needs a fresh one.
    func needsSignIn(_ email: String) -> Bool {
        signedOutAccounts.contains(email)
    }

    /// Set by the root view from SwiftUI's `openSettings` action. The old AppKit selector
    /// (`showSettingsWindow:`) no longer opens SwiftUI Settings windows on current macOS.
    var openSettingsHandler: (() -> Void)?
    /// Set by the root view from SwiftUI's `openWindow` action, so the Dock icon can reopen a closed window.
    var openMainWindowHandler: (() -> Void)?

    /// The running app's store, for AppKit callbacks that can't reach SwiftUI state.
    static weak var current: AppStore?
    /// Opens Settings, optionally on a specific tab.
    func openSettings(tab: SettingsTab? = nil) {
        if let tab { defaults.set(tab.rawValue, forKey: SettingsTab.storageKey) }
        openSettingsHandler?()
        NSApp.activate()
    }

    func showMainWindow() {
        openMainWindowHandler?()
        NSApp.activate()
    }

    // MARK: Dock badge

    static let dockBadgeKey = "ui.dockBadge"

    /// Unread inbox conversations across all accounts, on the Dock icon. Optional, in Settings → General.
    func updateDockBadge() {
        let showBadge = defaults.object(forKey: Self.dockBadgeKey) as? Bool ?? true
        let unread = unreadCounts.values.reduce(0, +)
        let label = showBadge && unread > 0 ? (unread > 999 ? "999+" : "\(unread)") : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    func account(for email: String) -> Account? {
        accounts.first { $0.email == email }
    }

    // MARK: Tags

    /// Saves the tag list. `renames` (old name → new name) keeps a renamed tag's assignments. Rebuilding the
    /// conversation index can take a moment on a big mailbox, so it happens off the main thread.
    func saveTags(_ updated: [Tag], renames: [String: String] = [:]) {
        let repo = repo
        Task {
            do {
                try await Task.detached { try repo.saveTags(updated, renames: renames) }.value
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
            tags = repo.tags()
            // If the open tab's tag was renamed or removed, follow the rename or fall back to Everything.
            if case .tag(let name) = split, !tags.contains(where: { $0.name == name }) {
                if let renamed = renames[name] { setSplit(.tag(renamed)) } else { setSplit(.everything) }
            }
            reload()
        }
    }

    func toggleTag(_ tag: String) {
        guard let thread = currentThread else { return }
        try? repo.toggleTag(tag, account: thread.account, threadId: thread.threadId)
        reload()
    }

    func tag(named name: String) -> Tag? {
        tags.first { $0.name == name }
    }

    // MARK: Actions

    func archive() {
        guard let thread = currentThread else { return }
        let inInbox = repo.threadMessages(account: thread.account, threadId: thread.threadId).contains { $0.labels.contains(SystemLabel.inbox) }
        if inInbox {
            changeLabels(thread, add: [], remove: [SystemLabel.inbox], message: "Marked done")
        } else {
            changeLabels(thread, add: [SystemLabel.inbox], remove: [], message: "Moved to Inbox")
        }
    }

    func trash() {
        guard let thread = currentThread else { return }
        let snapshots = (try? repo.modifyThread(account: thread.account, threadId: thread.threadId, add: [SystemLabel.trash], remove: [SystemLabel.inbox])) ?? []
        advance(after: thread)
        remote(thread, rollback: snapshots) { try await $0.trashThread(id: thread.threadId) }
        showToast("Moved to Trash", undo: { [weak self] in
            try? self?.repo.restore(snapshots)
            self?.remote(thread, rollback: []) { try await $0.untrashThread(id: thread.threadId) }
        })
    }

    func toggleStar() {
        guard let thread = currentThread else { return }
        if thread.isStarred || openMessages.contains(where: \.isStarred) {
            changeLabels(thread, add: [], remove: [SystemLabel.starred], message: nil)
        } else {
            let snapshots = (try? repo.modifyMessage(account: thread.account, id: thread.latestMessageId, add: [SystemLabel.starred], remove: [])) ?? []
            refreshAfterChange(thread)
            remote(thread, rollback: snapshots) { try await $0.modifyMessage(id: thread.latestMessageId, add: [SystemLabel.starred], remove: []) }
        }
    }

    func toggleRead() {
        guard let thread = currentThread else { return }
        let unread = repo.threadMessages(account: thread.account, threadId: thread.threadId).contains(where: \.isUnread)
        if unread {
            changeLabels(thread, add: [], remove: [SystemLabel.unread], message: nil)
        } else {
            changeLabels(thread, add: [SystemLabel.unread], remove: [], message: nil)
            if openThread?.id == thread.id { closeThread() }
        }
    }

    private func markRead(_ thread: ThreadSummary) {
        let snapshots = (try? repo.modifyThread(account: thread.account, threadId: thread.threadId, add: [], remove: [SystemLabel.unread])) ?? []
        remote(thread, rollback: snapshots) { try await $0.modifyThread(id: thread.threadId, add: [], remove: [SystemLabel.unread]) }
        scheduleReload()
    }

    /// Applies a label change locally right away, mirrors it to Gmail, and offers undo when there's a message to show.
    private func changeLabels(_ thread: ThreadSummary, add: Set<String>, remove: Set<String>, message: String?) {
        let snapshots = (try? repo.modifyThread(account: thread.account, threadId: thread.threadId, add: add, remove: remove)) ?? []
        if message != nil { advance(after: thread) } else { refreshAfterChange(thread) }
        remote(thread, rollback: snapshots) { try await $0.modifyThread(id: thread.threadId, add: Array(add), remove: Array(remove)) }

        if let message {
            showToast(message, undo: { [weak self] in
                try? self?.repo.restore(snapshots)
                self?.remote(thread, rollback: []) { try await $0.modifyThread(id: thread.threadId, add: Array(remove), remove: Array(add)) }
            })
        }
    }

    private func refreshAfterChange(_ thread: ThreadSummary) {
        reload()
        if openThread?.id == thread.id, let updated = threads.first(where: { $0.id == thread.id }) {
            openThread = updated
        }
    }

    /// After a thread leaves the list, move to the next one, like Superhuman.
    private func advance(after thread: ThreadSummary) {
        let wasOpen = openThread?.id == thread.id
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            // Opened from a link or search result that isn't in this list: there's no "next", so just close it,
            // rather than opening (and marking read) whatever happens to be first.
            reload()
            if wasOpen { closeThread() }
            return
        }
        reload()
        guard !threads.contains(where: { $0.id == thread.id }) else {
            refreshAfterChange(thread)
            return
        }
        let next = threads.isEmpty ? nil : threads[min(index, threads.count - 1)]
        selectedID = next?.id
        if wasOpen {
            if let next { open(next) } else { closeThread() }
        }
    }

    /// Mirrors a local change to Gmail in the background. Changes for an account go out one at a time, in the order
    /// they were made, so "archive, then undo" can't reach Gmail as "undo, then archive".
    ///
    /// While the change is in flight, the conversation is shielded from a sync that started earlier and would write
    /// the old labels back. If Gmail refuses, the local change is rolled back and the conversation is re-read from
    /// Gmail, so Nook never shows a state Gmail doesn't have. (A history sync can't fix that on its own: a change
    /// Gmail never applied leaves no history to replay.)
    private func remote(
        _ thread: ThreadSummary, rollback: [LabelSnapshot],
        _ operation: @escaping @Sendable (GmailService) async throws -> Void
    ) {
        let sync = sync
        let previous = remoteQueue[thread.account]
        remoteQueue[thread.account] = Task {
            await previous?.value
            await sync.protect(account: thread.account, threadId: thread.threadId)
            do {
                try await operation(try await sync.service(for: thread.account))
            } catch {
                try? repo.restore(rollback)
                reload()
                showToast("Couldn't update Gmail, so the change was undone. \(error.localizedDescription)", isError: true)
                try? await sync.refreshThread(account: thread.account, threadId: thread.threadId)
            }
        }
    }

    /// Undoes the action whose toast is on screen. Once the toast is gone, there's nothing to undo,
    /// so a stray "z" minutes later can't reverse something long forgotten.
    func undo() {
        guard let pending = undoAction, toast?.id == pending.id else { return }
        undoAction = nil
        pending.action()
        reload()
        showToast("Undone")
    }

    // MARK: Compose

    /// Opens a new draft unless one is already open: replacing it would throw away what's been typed.
    private func openDraft(_ new: Draft) {
        guard draft == nil else {
            showToast("Finish or discard the message you're writing first.")
            return
        }
        draft = new
        refreshContacts()
    }

    private func refreshContacts() {
        guard !contactsLoading else { return }
        contactsLoading = true
        let repo = repo
        let own = Set(accounts.map(\.email))
        let useAddressBook = !isDemo
        Task {
            let addressBook = useAddressBook ? await AddressBook.entries() : []
            let book = await Task.detached(priority: .userInitiated) {
                ContactBook(history: repo.contactHistory(), addressBook: addressBook, own: own)
            }.value
            contactBook = book
            contactsLoading = false
        }
    }

    func compose() {
        openDraft(Draft(from: scope ?? accounts.first?.email ?? ""))
    }

    func reply(_ kind: ReplyComposer.Kind) {
        guard let thread = currentThread else { return }
        let messages = openThread?.id == thread.id ? openMessages : repo.threadMessages(account: thread.account, threadId: thread.threadId)
        guard let latest = messages.last else { return }
        openDraft(ReplyComposer.draft(kind, to: latest, account: thread.account))
    }

    func send(_ draft: Draft) {
        // A second ⌘↵ during the sheet's closing animation must not send the same message twice.
        guard !sendingDrafts.contains(draft.id) else { return }
        sendingDrafts.insert(draft.id)
        self.draft = nil
        let name = account(for: draft.from)?.name ?? ""
        let raw = MIMEBuilder.gmailRaw(draft, fromName: name)
        showToast("Sending…")
        let sync = sync
        Task {
            do {
                try await sync.service(for: draft.from).send(raw: raw, threadId: draft.threadId)
                showToast("Sent")
                syncNow()
            } catch {
                sendingDrafts.remove(draft.id)
                // Bring the draft back, unless another one is open by now; never overwrite it.
                if self.draft == nil {
                    self.draft = draft
                    showToast("Couldn't send: \(error.localizedDescription)", isError: true)
                } else {
                    showToast("Couldn't send \"\(draft.subject)\": \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    // MARK: Links

    /// Handles `nook://` links. They come from the MCP server and other local tools, and only ever open
    /// something for you to look at. Drafts still need you to press Send.
    func handle(_ url: URL) {
        guard let link = NookURL(url) else { return }
        NSApp.activate()
        switch link {
        case let .compose(from, to, cc, subject, body):
            let sender = from.flatMap { account(for: $0)?.email } ?? scope ?? accounts.first?.email ?? ""
            openDraft(Draft(from: sender, to: to, cc: cc, subject: subject, body: body))
        case let .reply(account, threadId, body, all):
            let messages = repo.threadMessages(account: account, threadId: threadId)
            guard let latest = messages.last else { return showToast("That conversation isn't on this Mac.", isError: true) }
            var reply = ReplyComposer.draft(all ? .replyAll : .reply, to: latest, account: account)
            reply.body = body + reply.body
            openDraft(reply)
        case let .open(account, threadId):
            guard let thread = repo.thread(account: account, threadId: threadId) else {
                return showToast("That conversation isn't on this Mac.", isError: true)
            }
            open(thread)
        }
    }

    // MARK: Toasts

    func showToast(_ message: String, isError: Bool = false, undo: (() -> Void)? = nil) {
        let toast = Toast(message: message, canUndo: undo != nil, isError: isError)
        undoAction = undo.map { (toast.id, $0) }
        withAnimation(.snappy(duration: 0.2)) { self.toast = toast }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 4))
            if self.toast?.id == toast.id {
                withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
                if undoAction?.id == toast.id { undoAction = nil }
            }
        }
    }

    // MARK: Command palette

    func paletteCommands() -> [PaletteCommand] {
        if paletteMode == .tags {
            let applied = Set(currentThread?.tags ?? [])
            return tags.map { tag in
                PaletteCommand(
                    title: tag.name, section: "Tag conversation",
                    systemImage: applied.contains(tag.name) ? "checkmark.circle.fill" : "circle", shortcut: nil
                ) { [weak self] in self?.toggleTag(tag.name) }
            }
        }

        var commands: [PaletteCommand] = []
        if currentThread != nil {
            commands += [
                PaletteCommand(title: "Mark done", section: "Conversation", systemImage: "checkmark", shortcut: "E") { [weak self] in self?.archive() },
                PaletteCommand(title: "Reply", section: "Conversation", systemImage: "arrowshape.turn.up.left", shortcut: "R") { [weak self] in self?.reply(.reply) },
                PaletteCommand(title: "Reply all", section: "Conversation", systemImage: "arrowshape.turn.up.left.2", shortcut: "A") { [weak self] in self?.reply(.replyAll) },
                PaletteCommand(title: "Forward", section: "Conversation", systemImage: "arrowshape.turn.up.right", shortcut: "F") { [weak self] in self?.reply(.forward) },
                PaletteCommand(title: "Star", section: "Conversation", systemImage: "star", shortcut: "S") { [weak self] in self?.toggleStar() },
                PaletteCommand(title: "Toggle read", section: "Conversation", systemImage: "envelope.badge", shortcut: "U") { [weak self] in self?.toggleRead() },
                PaletteCommand(title: "Tag…", section: "Conversation", systemImage: "tag", shortcut: "L") { [weak self] in
                    DispatchQueue.main.async { self?.openPalette(.tags) }
                },
                PaletteCommand(title: "Move to Trash", section: "Conversation", systemImage: "trash", shortcut: "#") { [weak self] in self?.trash() },
            ]
        }
        commands += [
            PaletteCommand(title: "New message", section: "General", systemImage: "square.and.pencil", shortcut: "C") { [weak self] in self?.compose() },
            PaletteCommand(title: "Search", section: "General", systemImage: "magnifyingglass", shortcut: "/") { [weak self] in self?.focusSearch() },
            PaletteCommand(
                title: unreadOnly ? "Show all mail" : "Show only unread", section: "General",
                systemImage: unreadOnly ? "tray" : "circle.inset.filled", shortcut: "⇧U"
            ) { [weak self] in self?.toggleUnreadOnly() },
            PaletteCommand(title: "Sync now", section: "General", systemImage: "arrow.triangle.2.circlepath", shortcut: "⌘R") { [weak self] in self?.syncNow() },
            PaletteCommand(title: "Keyboard shortcuts", section: "General", systemImage: "keyboard", shortcut: "?") { [weak self] in self?.showHelp = true },
            PaletteCommand(title: "Settings", section: "General", systemImage: "gearshape", shortcut: "⌘,") { [weak self] in
                self?.openSettings()
            },
        ]
        commands += Mailbox.allCases.map { mailbox in
            PaletteCommand(title: "Go to \(mailbox.title)", section: "Go to", systemImage: mailbox.systemImage, shortcut: nil) { [weak self] in self?.setMailbox(mailbox) }
        }
        commands.append(PaletteCommand(title: "All accounts", section: "Accounts", systemImage: "tray.2", shortcut: "⌘0") { [weak self] in self?.setScope(nil) })
        commands += accounts.enumerated().map { index, account in
            PaletteCommand(title: account.email, section: "Accounts", systemImage: "person.crop.circle", shortcut: index < 9 ? "⌘\(index + 1)" : nil) { [weak self] in
                self?.setScope(account.email)
            }
        }
        commands += tags.map { tag in
            PaletteCommand(title: "Show \(tag.name)", section: "Tags", systemImage: "tag", shortcut: nil) { [weak self] in self?.setSplit(.tag(tag.name)) }
        }
        return commands
    }
}
