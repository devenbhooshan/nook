import Foundation

public struct SyncReport: Sendable, Equatable {
    public enum Kind: Sendable { case full, incremental }
    public var kind: Kind
    public var added = 0
    public var updated = 0
    public var deleted = 0

    public init(kind: Kind, added: Int = 0, updated: Int = 0, deleted: Int = 0) {
        self.kind = kind
        self.added = added
        self.updated = updated
        self.deleted = deleted
    }
}

/// How much attachment data Nook keeps on this Mac, chosen in Settings → Privacy.
public enum AttachmentStorage {
    public static let limitKey = "attachments.storageLimitGB"
    public static let defaultGigabytes = 50
    public static let choices = [5, 10, 20, 50, 100]

    public static func bytes(gigabytes: Int) -> Int { gigabytes * 1024 * 1024 * 1024 }

    public static func limit(in defaults: UserDefaults) -> Int {
        let chosen = defaults.integer(forKey: limitKey)
        return bytes(gigabytes: chosen > 0 ? chosen : defaultGigabytes)
    }
}

/// Keeps the local store in step with Gmail.
///
/// - The first sync downloads the inbox plus recent mail (`initialQuery`), then saves Gmail's history cursor.
/// - Later syncs replay only the history since that cursor, which is cheap enough to run every few seconds.
/// - If the cursor has expired (Gmail returns 404), it falls back to a full sync that also refreshes labels.
///
/// Concurrent requests for the same account join the sync already running instead of starting a new one.
public actor SyncEngine {
    public typealias ServiceFactory = @Sendable (String) throws -> GmailService

    public var initialQuery = "in:inbox OR newer_than:60d OR in:drafts"
    public var initialLimit = 2000
    public var maxConcurrentFetches = 8
    /// Messages are saved, and observers notified, after each batch so the list fills in as it downloads.
    /// Small batches keep each write transaction short, so a user action never waits long behind one.
    public var batchSize = 20

    private let repo: MailRepository
    private let makeService: ServiceFactory
    private let onChange: @Sendable () -> Void
    private var services: [String: GmailService] = [:]
    /// Accounts whose drafts were checked since launch. Accounts synced before Nook kept drafts get theirs here.
    private var draftsChecked: Set<String> = []
    private var running: [String: Task<SyncReport, Error>] = [:]
    private var downloads: [String: Task<Void, Never>] = [:]
    private var backfills: [String: Task<Int, Error>] = [:]
    /// How much attachment data to keep on this Mac. Past this, the oldest mail's files go back to being fetched on demand.
    private let attachmentBudget: @Sendable () -> Int
    /// Bigger files stay in Gmail.
    static let largestStoredAttachment = 25 * 1024 * 1024

    private let now: @Sendable () -> Date
    /// Conversations the user just changed, and until when a sync should leave their labels alone.
    private var protectedThreads: [ThreadKey: Date] = [:]

    public init(
        repo: MailRepository, makeService: @escaping ServiceFactory, onChange: @escaping @Sendable () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() },
        attachmentBudget: @escaping @Sendable () -> Int = { AttachmentStorage.bytes(gigabytes: AttachmentStorage.defaultGigabytes) }
    ) {
        self.repo = repo
        self.makeService = makeService
        self.onChange = onChange
        self.attachmentBudget = attachmentBudget
        self.now = now
    }

    /// Shields a conversation the user just changed from label updates for a short while.
    ///
    /// A sync that started before the change reached Gmail would otherwise write the old labels back (an archived
    /// thread popping back into the inbox until the next sync). Once Gmail applies the change it shows up in history,
    /// which a later sync replays, so skipping stale updates in the meantime loses nothing.
    public func protect(account: String, threadId: String, for seconds: TimeInterval = 30) {
        protectedThreads[ThreadKey(account: account, threadId: threadId)] = now().addingTimeInterval(seconds)
    }

    private func isProtected(account: String, threadId: String?) -> Bool {
        guard let threadId else { return false }
        let key = ThreadKey(account: account, threadId: threadId)
        guard let until = protectedThreads[key] else { return false }
        if until < now() {
            protectedThreads[key] = nil
            return false
        }
        return true
    }

    public func configure(initialQuery: String? = nil, initialLimit: Int? = nil, batchSize: Int? = nil) {
        if let initialQuery { self.initialQuery = initialQuery }
        if let initialLimit { self.initialLimit = initialLimit }
        if let batchSize { self.batchSize = batchSize }
    }

    public func service(for email: String) throws -> GmailService {
        if let service = services[email] { return service }
        let service = try makeService(email)
        services[email] = service
        return service
    }

    /// Drops the cached client, for example after the account is removed.
    /// Drops the account's client and stops its sync, waiting until the sync has actually finished, so nothing
    /// is written for the account after this returns.
    public func forget(_ email: String) async {
        services[email] = nil
        let task = running[email]
        running[email] = nil
        task?.cancel()
        _ = try? await task?.value
        let download = downloads[email]
        download?.cancel()
        await download?.value
        let backfill = backfills[email]
        backfills[email] = nil
        backfill?.cancel()
        _ = try? await backfill?.value
    }

    // MARK: Older mail

    /// Downloads every message matching `query` that isn't stored yet, newest first. Returns how many it added.
    /// A second call for the same account while one runs joins it. Stopping part way loses nothing:
    /// the next run skips what's already stored.
    @discardableResult
    public func loadOlderMail(
        account: String, query: String, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> Int {
        if let task = backfills[account] { return try await task.value }
        let task = Task { () throws -> Int in try await GmailPriority.$background.withValue(true) {
            let service = try self.service(for: account)
            let listed = try await self.patiently { try await service.listMessageIDs(query: query, limit: MailHistory.largestListing) }
            let known = repo.messageIds(account: account)
            let ids = listed.filter { !known.contains($0) }
            // Count what's already here, so the bar shows how much of the mailbox is on this Mac and doesn't start
            // from nothing each time Nook opens.
            let here = listed.count - ids.count
            progress(here, listed.count)
            var added = 0
            // Bigger slices than a sync's batches, so progress is reported without a call per batch.
            for start in stride(from: 0, to: ids.count, by: 200) {
                let slice = Array(ids[start..<min(start + 200, ids.count)])
                added += try await self.patiently { try await self.fetchAndStore(slice, account: account, service: service) }
                progress(here + start + slice.count, listed.count)
            }
            return added
        } }
        backfills[account] = task
        defer { backfills[account] = nil }
        return try await task.value
    }

    /// How long loading older mail waits after Gmail asks it to slow down.
    var backfillPause: Duration = .seconds(60)
    func setBackfillPause(_ pause: Duration) { backfillPause = pause }

    /// Loading a whole mailbox runs into Gmail's rate limit now and then. Wait and carry on from the same place,
    /// instead of giving up and listing the whole mailbox again later.
    private func patiently<T>(_ work: () async throws -> T) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await work()
            } catch let error as GmailError where Self.isTemporary(error) && failures < 30 {
                failures += 1
                try await Task.sleep(for: backfillPause)
            }
        }
    }

    static func isTemporary(_ error: GmailError) -> Bool {
        switch error {
        case .rateLimited: true
        case .http(let status, _): status == 403 || status == 429 || status >= 500
        default: false
        }
    }

    /// Re-reads one conversation's labels from Gmail, so local state matches the server after a change Gmail
    /// refused. Messages Gmail no longer has (or that moved to spam) are removed locally.
    public func refreshThread(account: String, threadId: String) async throws {
        let service = try service(for: account)
        for message in repo.threadMessages(account: account, threadId: threadId) {
            do {
                let labels = try await service.message(id: message.id, format: .minimal).labelIds ?? []
                if Self.shouldStore(labels: labels) {
                    try repo.setLabels(Set(labels), account: account, messageId: message.id)
                } else {
                    try repo.deleteMessages(account: account, ids: [message.id])
                }
            } catch GmailError.notFound {
                try repo.deleteMessages(account: account, ids: [message.id])
            }
        }
        onChange()
    }

    @discardableResult
    public func sync(_ email: String) async throws -> SyncReport {
        if let task = running[email] { return try await task.value }
        let task = Task { try await self.performSync(email) }
        running[email] = task
        defer { running[email] = nil }
        return try await task.value
    }

    private func performSync(_ email: String) async throws -> SyncReport {
        guard repo.account(email) != nil else { throw CancellationError() }
        let service = try service(for: email)
        if let cursor = repo.account(email)?.historyId, !cursor.isEmpty {
            do {
                var report = try await incrementalSync(email, service: service, cursor: cursor)
                if !draftsChecked.contains(email) {
                    let ids = try await service.listMessageIDs(query: "in:drafts", limit: 500)
                    let known = repo.messageIds(account: email)
                    report.added += try await fetchAndStore(ids.filter { !known.contains($0) }, account: email, service: service)
                    draftsChecked.insert(email)
                }
                // A few older messages at a time, so mail stored before Nook kept attachments shows its files.
                try? await fillInAttachments(account: email, ids: repo.messagesMissingAttachments(account: email, limit: 40), service: service)
                startDownloadingAttachments(account: email, service: service)
                return report
            } catch GmailError.notFound {
                // History older than about a week expires. Start over, and re-check labels we can no longer replay.
                try repo.setPendingHistoryId(nil, for: email)
                return try await fullSync(email, service: service, refreshKnownLabels: true)
            }
        }
        return try await fullSync(email, service: service, refreshKnownLabels: false)
    }

    // MARK: Full

    /// Downloads whatever is missing, then saves a cursor so later syncs are incremental.
    ///
    /// The cursor is taken *before* downloading and kept across attempts, so if a first sync is interrupted
    /// (quit, network, rate limit) the next attempt resumes: it fetches only what's still missing, and history
    /// from the original cursor replays any changes made in between. Messages already stored don't need their
    /// labels re-checked, which on a big mailbox meant thousands of requests on every retry.
    ///
    /// - Parameter refreshKnownLabels: Re-check labels on stored messages. Only needed when the old cursor
    ///   expired, because then the changes since can't be replayed.
    private func fullSync(_ email: String, service: GmailService, refreshKnownLabels: Bool) async throws -> SyncReport {
        let cursor: String
        if !refreshKnownLabels, let pending = repo.pendingHistoryId(for: email) {
            cursor = pending
        } else {
            cursor = try await service.profile().historyId
            try repo.setPendingHistoryId(cursor, for: email)
        }

        let ids = try await service.listMessageIDs(query: initialQuery, limit: initialLimit)
        let known = repo.messageIds(account: email)

        var report = SyncReport(kind: .full)
        report.added = try await fetchAndStore(ids.filter { !known.contains($0) }, account: email, service: service)

        if refreshKnownLabels {
            // Every stored message, not just the ones in the listing window: mail archived or deleted elsewhere
            // while the cursor was expired would otherwise stay as it was here, possibly forever.
            report.updated = try await refreshLabels(Array(known), account: email, service: service)
        }

        try repo.setHistoryId(cursor, for: email)
        onChange()
        return report
    }

    // MARK: Incremental

    private func incrementalSync(_ email: String, service: GmailService, cursor: String) async throws -> SyncReport {
        let history = try await service.history(since: cursor)
        var report = SyncReport(kind: .incremental)
        guard !history.records.isEmpty else {
            // Nothing new, but the account is up to date as of now, so record the time.
            try repo.setHistoryId(history.historyId, for: email)
            return report
        }

        // Fold the records into a final state per message. Later records win.
        var added = Set<String>()
        var deleted = Set<String>()
        var labels: [String: [String]] = [:]
        var labelsUnknown = Set<String>()
        for record in history.records {
            for change in record.messagesAdded ?? [] {
                // Spam is never stored, so don't download it only to throw it away.
                if let labels = change.message.labelIds, !Self.shouldStore(labels: labels) { continue }
                added.insert(change.message.id)
                deleted.remove(change.message.id)
            }
            for change in record.messagesDeleted ?? [] {
                deleted.insert(change.message.id)
                added.remove(change.message.id)
                labels[change.message.id] = nil
            }
            for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                if let ids = change.message.labelIds {
                    labels[change.message.id] = ids
                    labelsUnknown.remove(change.message.id)
                } else {
                    labelsUnknown.insert(change.message.id)
                }
            }
        }

        let known = repo.messageIds(account: email)
        var toFetch = added
        // A label change on a message we never downloaded only matters if it brings the message somewhere visible
        // (an old message moved back to the inbox, or starred). Anything else, like "mark all as read" on years of
        // archived mail in Gmail on the web, would otherwise download thousands of messages nobody looks at.
        toFetch.formUnion(labels.filter { !known.contains($0.key) && Self.bringsIntoView(labels: $0.value) }.keys)
        toFetch.subtract(deleted)

        for (id, ids) in labels where known.contains(id) && !toFetch.contains(id) && !deleted.contains(id) {
            if isProtected(account: email, threadId: repo.message(account: email, id: id)?.threadId) { continue }
            if Self.shouldStore(labels: ids) {
                try repo.setLabels(Set(ids), account: email, messageId: id)
            } else {
                deleted.insert(id)
            }
            report.updated += 1
        }
        let refetchLabels = labelsUnknown.filter { known.contains($0) && !deleted.contains($0) }
        report.updated += try await refreshLabels(Array(refetchLabels), account: email, service: service)

        report.added = try await fetchAndStore(Array(toFetch), account: email, service: service)

        let removals = deleted.filter(known.contains)
        try repo.deleteMessages(account: email, ids: Array(removals))
        report.deleted = removals.count

        try repo.setHistoryId(history.historyId, for: email)
        onChange()
        return report
    }

    // MARK: Attachments

    /// Fetches these messages again to learn their attachments, keeping the labels stored here, which may hold
    /// a change still on its way to Gmail.
    public func fillInAttachments(account: String, ids: [String]) async throws {
        try await fillInAttachments(account: account, ids: ids, service: try service(for: account))
    }

    private func fillInAttachments(account: String, ids: [String], service: GmailService) async throws {
        guard !ids.isEmpty else { return }
        let fetched = try await fetch(ids, format: .full, service: service).messages
        try Task.checkCancellation()
        let messages = fetched.compactMap { gmail -> MailMessage? in
            guard let stored = repo.message(account: account, id: gmail.id) else { return nil }
            var message = MIMEParser.message(from: gmail, account: account)
            message.labels = stored.labels
            return message
        }
        try repo.upsert(messages)
        if !messages.isEmpty { onChange() }
    }

    /// Keeps files on this Mac so they open instantly. This runs beside sync, because it can take a long time.
    private func startDownloadingAttachments(account: String, service: GmailService) {
        guard downloads[account] == nil else { return }
        downloads[account] = Task {
            await downloadAttachments(account: account, service: service)
            downloads[account] = nil
        }
    }

    /// Newest mail first. Stops at the first failure and carries on after the next sync.
    private func downloadAttachments(account: String, service: GmailService) async {
        await GmailPriority.$background.withValue(true) { await downloadAttachmentsNow(account: account, service: service) }
    }

    private func downloadAttachmentsNow(account: String, service: GmailService) async {
        // The limit may have been lowered since the last run.
        try? repo.trimStoredAttachments(toBudget: attachmentBudget())
        while !Task.isCancelled {
            let ids = repo.messagesAwaitingAttachments(account: account, budget: attachmentBudget(), limit: 20)
            if ids.isEmpty { return }
            for id in ids {
                guard let message = repo.message(account: account, id: id) else { return }
                var files: [(partId: String, data: Data?)] = []
                for attachment in message.attachments {
                    var data: Data?
                    if !attachment.isInline, attachment.size <= Self.largestStoredAttachment {
                        do {
                            data = try await service.data(for: attachment, messageId: id)
                        } catch GmailError.notFound {
                            data = nil
                        } catch {
                            return
                        }
                    }
                    if Task.isCancelled { return }
                    files.append((attachment.partId, data))
                }
                do {
                    try repo.storeAttachments(account: account, messageId: id, files: files)
                    try repo.trimStoredAttachments(toBudget: attachmentBudget())
                } catch {
                    return
                }
            }
        }
    }

    // MARK: Fetching

    /// Spam is never stored.
    static func shouldStore(labels: [String]) -> Bool {
        !labels.contains(SystemLabel.spam)
    }

    /// Whether these labels put a message somewhere Nook shows it without searching.
    static func bringsIntoView(labels: [String]) -> Bool {
        shouldStore(labels: labels) && !labels.contains(SystemLabel.trash)
            && (labels.contains(SystemLabel.inbox) || labels.contains(SystemLabel.starred) || labels.contains(SystemLabel.draft))
    }

    private func fetchAndStore(_ ids: [String], account: String, service: GmailService) async throws -> Int {
        var stored = 0
        for start in stride(from: 0, to: ids.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            let fetched = try await fetch(batch, format: .full, service: service).messages
            // The account may have been removed while this batch downloaded.
            try Task.checkCancellation()
            guard repo.account(account) != nil else { throw CancellationError() }
            let messages = fetched
                .filter { Self.shouldStore(labels: $0.labelIds ?? []) }
                .map { MIMEParser.message(from: $0, account: account) }
            try repo.upsert(messages)
            stored += messages.count
            onChange()
        }
        return stored
    }

    private func refreshLabels(_ ids: [String], account: String, service: GmailService) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var updated = 0
        let (messages, missing) = try await fetch(ids, format: .minimal, service: service)
        for message in messages {
            if isProtected(account: account, threadId: message.threadId) { continue }
            let labels = message.labelIds ?? []
            if Self.shouldStore(labels: labels) {
                try repo.setLabels(Set(labels), account: account, messageId: message.id)
            } else {
                try repo.deleteMessages(account: account, ids: [message.id])
            }
            updated += 1
        }
        // Gmail no longer has these: they were deleted while we weren't looking.
        try repo.deleteMessages(account: account, ids: missing)
        return updated + missing.count
    }

    /// Fetches messages with bounded concurrency. Messages Gmail no longer has (404) come back in `missing`.
    private func fetch(
        _ ids: [String], format: GmailMessageFormat, service: GmailService
    ) async throws -> (messages: [GmailMessage], missing: [String]) {
        let limit = max(1, maxConcurrentFetches)
        return try await withThrowingTaskGroup(of: (String, GmailMessage?).self) { group in
            var iterator = ids.makeIterator()
            func addNext() -> Bool {
                guard let id = iterator.next() else { return false }
                group.addTask {
                    do {
                        return (id, try await service.message(id: id, format: format))
                    } catch GmailError.notFound {
                        return (id, nil)
                    }
                }
                return true
            }

            for _ in 0..<limit where !addNext() { break }
            var results: [GmailMessage] = []
            var missing: [String] = []
            while let (id, result) = try await group.next() {
                if let result { results.append(result) } else { missing.append(id) }
                _ = addNext()
            }
            return (results, missing)
        }
    }
}

/// How far back Nook keeps mail. The first sync brings the inbox and the last 60 days; more is loaded on request.
public enum MailHistory {
    public static let yearsKey = "sync.historyYears"
    /// Years of mail. 0 is the first sync's 60 days; `everything` is the whole mailbox.
    public static let everything = -1
    public static let choices = [0, 1, 2, 3, 4, everything]
    /// Gmail's search for a choice, or nil when the first sync already covers it. Spam and trash are never stored.
    public static func query(years: Int) -> String? {
        switch years {
        case 0: nil
        case everything: "-in:spam -in:trash"
        default: "newer_than:\(years)y -in:spam -in:trash"
        }
    }

    public static func label(years: Int) -> String {
        switch years {
        case 0: "60 days"
        case everything: "All mail"
        case 1: "1 year"
        default: "\(years) years"
        }
    }

    /// Whether mail loaded for `loaded` already covers `wanted`.
    public static func covers(_ loaded: Int, _ wanted: Int) -> Bool {
        if loaded == everything { return true }
        if wanted == everything { return false }
        return loaded >= wanted
    }

    static let largestListing = 2_000_000
    /// Per account, the choice whose mail has finished loading.
    public static func loadedKey(_ account: String) -> String { "sync.historyLoaded.\(account)" }
}
