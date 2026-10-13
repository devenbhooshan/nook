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

/// Keeps the local store in step with Gmail.
///
/// - The first sync downloads the inbox plus recent mail (`initialQuery`), then saves Gmail's history cursor.
/// - Later syncs replay only the history since that cursor, which is cheap enough to run every few seconds.
/// - If the cursor has expired (Gmail returns 404), it falls back to a full sync that also refreshes labels.
///
/// Concurrent requests for the same account join the sync already running instead of starting a new one.
public actor SyncEngine {
    public typealias ServiceFactory = @Sendable (String) throws -> GmailService

    /// Drafts are excluded because Nook never stores them; listing them would re-download them on every resync.
    public var initialQuery = "(in:inbox OR newer_than:60d) -in:drafts"
    public var initialLimit = 2000
    public var maxConcurrentFetches = 8
    /// Messages are saved, and observers notified, after each batch so the list fills in as it downloads.
    /// Small batches keep each write transaction short, so a user action never waits long behind one.
    public var batchSize = 20

    private let repo: MailRepository
    private let makeService: ServiceFactory
    private let onChange: @Sendable () -> Void
    private var services: [String: GmailService] = [:]
    private var running: [String: Task<SyncReport, Error>] = [:]

    private let now: @Sendable () -> Date
    /// Conversations the user just changed, and until when a sync should leave their labels alone.
    private var protectedThreads: [ThreadKey: Date] = [:]

    public init(
        repo: MailRepository, makeService: @escaping ServiceFactory, onChange: @escaping @Sendable () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repo = repo
        self.makeService = makeService
        self.onChange = onChange
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
                return try await incrementalSync(email, service: service, cursor: cursor)
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
                // Drafts and spam are never stored, so don't download them only to throw them away.
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

    // MARK: Fetching

    /// Spam and drafts are never stored.
    static func shouldStore(labels: [String]) -> Bool {
        !labels.contains(SystemLabel.spam) && !labels.contains(SystemLabel.draft)
    }

    /// Whether these labels put a message somewhere Nook shows it without searching.
    static func bringsIntoView(labels: [String]) -> Bool {
        shouldStore(labels: labels) && !labels.contains(SystemLabel.trash)
            && (labels.contains(SystemLabel.inbox) || labels.contains(SystemLabel.starred))
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
            var messages = fetched
                .filter { Self.shouldStore(labels: $0.labelIds ?? []) }
                .map { MIMEParser.message(from: $0, account: account) }
            let tags = try await applyRules(to: &messages, account: account, service: service)
            try repo.upsert(messages)
            for (id, ruleTags) in tags { try repo.addRuleTags(ruleTags, account: account, messageId: id) }
            stored += messages.count
            onChange()
        }
        return stored
    }

    // MARK: Rules

    /// Runs your rules on newly downloaded mail before it's stored, so a rule's changes never flash in the inbox.
    /// Label changes go to Gmail first, in one request per kind of change; if Gmail refuses, the mail is stored as
    /// it arrived. Returns the tags to add, by message id.
    private func applyRules(to messages: inout [MailMessage], account: String, service: GmailService) async throws -> [String: [String]] {
        let rules = repo.rules().filter(\.isEnabled)
        guard !rules.isEmpty else { return [:] }
        var tags: [String: [String]] = [:]
        var outcomes: [Int: RuleOutcome] = [:]
        for (index, message) in messages.enumerated() {
            let outcome = RuleOutcome.evaluate(message, rules: rules, onlyArrivedAfterCreation: true)
            if !outcome.tags.isEmpty { tags[message.id] = outcome.tags }
            if !outcome.addLabels.isEmpty || !outcome.removeLabels.isEmpty { outcomes[index] = outcome }
        }
        for (change, indices) in Dictionary(grouping: outcomes.keys, by: { LabelChange(outcomes[$0]!) }) {
            do {
                try await service.modifyMessages(ids: indices.map { messages[$0].id }, add: change.add, remove: change.remove)
                for index in indices { messages[index].labels = outcomes[index]!.labels(for: messages[index]) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Leave these as they arrived; the mail is still there to deal with by hand.
            }
        }
        return tags
    }

    /// Applies one rule to mail already in Nook, for when you create a rule and want it to tidy up what's there.
    /// - Returns: How many emails it changed.
    @discardableResult
    public func apply(_ rule: MailRule, searchLimit: Int = 5000) async throws -> Int {
        var rule = rule
        rule.isEnabled = true
        let matches = repo.recentReceivedMessages(limit: searchLimit).filter(rule.matches)
        var changed = 0
        for (account, messages) in Dictionary(grouping: matches, by: \.account) {
            let service = try service(for: account)
            let outcomes = messages.map { ($0, RuleOutcome.evaluate($0, rules: [rule], onlyArrivedAfterCreation: false)) }
                .filter { !$0.1.isEmpty }
            for (change, group) in Dictionary(grouping: outcomes.filter { !$0.1.addLabels.isEmpty || !$0.1.removeLabels.isEmpty },
                                              by: { LabelChange($0.1) }) {
                try await service.modifyMessages(ids: group.map(\.0.id), add: change.add, remove: change.remove)
                for (message, outcome) in group {
                    try repo.setLabels(outcome.labels(for: message), account: account, messageId: message.id)
                }
            }
            for (message, outcome) in outcomes where !outcome.tags.isEmpty {
                try repo.addRuleTags(outcome.tags, account: account, messageId: message.id)
            }
            changed += outcomes.count
        }
        if changed > 0 { onChange() }
        return changed
    }

    private struct LabelChange: Hashable {
        var add: [String]
        var remove: [String]
        init(_ outcome: RuleOutcome) {
            add = outcome.addLabels.sorted()
            remove = outcome.removeLabels.sorted()
        }
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
