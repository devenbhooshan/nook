import Foundation

/// What the message list is showing.
public struct ThreadQuery: Equatable, Sendable {
    /// `nil` shows every account together.
    public var account: String?
    public var mailbox: Mailbox
    public var split: InboxSplit
    public var search: SearchQuery?
    /// Only conversations with at least one unread message.
    public var unreadOnly: Bool
    /// Conversations (`ThreadSummary.id`) to keep showing under `unreadOnly` even once they're read,
    /// so a thread doesn't vanish the moment you open it.
    public var keepVisible: Set<String>
    public var limit: Int

    public init(
        account: String? = nil, mailbox: Mailbox = .inbox, split: InboxSplit = .everything, search: SearchQuery? = nil,
        unreadOnly: Bool = false, keepVisible: Set<String> = [], limit: Int = 500
    ) {
        self.account = account
        self.mailbox = mailbox
        self.split = split
        self.search = search
        self.unreadOnly = unreadOnly
        self.keepVisible = keepVisible
        self.limit = limit
    }

    /// Searching looks across all mail unless the query names a mailbox with `in:`.
    public var effectiveMailbox: Mailbox {
        if let mailbox = search?.mailbox { return mailbox }
        return search == nil ? mailbox : .all
    }
}

/// A snapshot of a message's labels, used to undo an action.
public struct LabelSnapshot: Sendable, Equatable {
    public var account: String
    public var messageId: String
    public var labels: Set<String>
}

/// All reads and writes of Nook's local mail store.
public final class MailRepository: @unchecked Sendable {
    /// The read-write connection. All writes go here.
    public let db: Database
    /// Where lists, counts and thread reads go. A separate read-only connection in the app, so the UI never
    /// waits behind a sync's write transaction; the same connection in tests and for in-memory stores.
    private let backgroundReader: Database
    /// The main thread's own read-only connection. Every connection serializes its calls, so a main-thread read
    /// sharing one with background work (counts, tagging, loading older mail) waited behind it: closing an email
    /// froze the app for seconds. nil shares `backgroundReader`.
    private let mainReader: Database?
    private var reader: Database {
        if Thread.isMainThread { return mainReader ?? backgroundReader }
        // Everything a search reads (its rows, tags, reminders) goes through the search connection, so a search
        // never waits behind counts or loading older mail on the background one.
        if let searcher, Thread.current.threadDictionary[Self.searchingKey] != nil { return searcher }
        return backgroundReader
    }
    private static let searchingKey = "nook.searching"
    /// Search's own read-only connection in the app, so a search can be cancelled the moment a newer keystroke
    /// replaces it without touching anything else. nil shares `reader`, and then searches aren't cancelled.
    private let searcher: Database?

    /// See `Database.closeForQuit()`.
    public func closeForQuit() {
        searcher?.closeForQuit()
        mainReader?.closeForQuit()
        backgroundReader.closeForQuit()
        db.closeForQuit()
    }

    /// Tests: keeps the background connection busy for a while, like a long count or a tagging batch.
    func occupyBackgroundReader() {
        _ = try? backgroundReader.query("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 4000000) SELECT count(*) AS n FROM c")
    }

    /// `threads(_:)` for a list someone is waiting to see, read off the main thread: it goes through the search
    /// connection, so it doesn't queue behind counts, tagging or loading older mail. `cancelSearch()` stops it.
    public func threadsForDisplay(_ query: ThreadQuery) -> [ThreadSummary] {
        let marked = Thread.current.threadDictionary[Self.searchingKey] != nil
        if !marked { Thread.current.threadDictionary[Self.searchingKey] = true }
        defer { if !marked { Thread.current.threadDictionary[Self.searchingKey] = nil } }
        return threads(query)
    }

    /// Stops a search that's still running; it returns no results. Safe from any thread.
    public func cancelSearch() {
        searcher?.interrupt()
    }

    /// Where downloaded attachments are kept, encrypted. nil keeps them inside the store (tests, the demo).
    public let vault: AttachmentVault?

    public init(db: Database, reader: Database? = nil, mainReader: Database? = nil, searcher: Database? = nil, vault: AttachmentVault? = nil) {
        self.vault = vault
        self.db = db
        self.backgroundReader = reader ?? db
        self.mainReader = mainReader
        self.searcher = searcher
    }

    // MARK: Accounts

    public func accounts() -> [Account] {
        let rows = (try? reader.query("SELECT * FROM accounts ORDER BY position, email")) ?? []
        return rows.map {
            Account(
                email: $0.string("email"),
                name: $0.string("name"),
                historyId: $0.optionalString("history_id"),
                colorIndex: $0.int("color"),
                lastSync: $0.isNull("last_sync") ? nil : Date(timeIntervalSince1970: $0.double("last_sync"))
            )
        }
    }

    public func account(_ email: String) -> Account? {
        accounts().first { $0.email == email }
    }

    /// Adds an account, or updates its display name if it already exists.
    public func addAccount(email: String, name: String) throws {
        try db.transaction {
            let existing = try db.query("SELECT COUNT(*) AS n, COALESCE(MAX(position), -1) AS p FROM accounts").first
            let count = existing?.int("n") ?? 0
            let position = (existing?.int("p") ?? -1) + 1
            try db.execute(
                """
                INSERT INTO accounts(email, name, color, position) VALUES (?, ?, ?, ?)
                ON CONFLICT(email) DO UPDATE SET name = excluded.name
                """,
                [email, name, count, position]
            )
        }
    }

    public func removeAccount(_ email: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM messages WHERE account = ?", [email])
            try db.execute("DELETE FROM message_bodies WHERE account = ?", [email])
            try db.execute("DELETE FROM attachment_files WHERE account = ?", [email])
            vault?.removeAccount(email)
            try db.execute("DELETE FROM message_tags WHERE account = ?", [email])
            try db.execute("DELETE FROM messages_fts WHERE rowid IN (SELECT fts_rowid FROM fts_map WHERE account = ?)", [email])
            try? db.execute("DELETE FROM \(SearchIndex.leanName) WHERE rowid IN (SELECT fts_rowid FROM fts_map WHERE account = ?)", [email])
            try db.execute("DELETE FROM fts_map WHERE account = ?", [email])
            try db.execute("DELETE FROM threads WHERE account = ?", [email])
            try db.execute("DELETE FROM thread_tags WHERE account = ?", [email])
            try db.execute("DELETE FROM reminders WHERE account = ?", [email])
            try db.execute("DELETE FROM accounts WHERE email = ?", [email])
        }
    }

    /// Saves the sync cursor once a sync completes, and clears any pending first-sync cursor.
    public func setHistoryId(_ historyId: String?, for email: String, syncedAt: Date = Date()) throws {
        try db.execute(
            "UPDATE accounts SET history_id = ?, last_sync = ?, pending_history_id = NULL WHERE email = ?",
            [historyId, syncedAt, email]
        )
    }

    /// The history cursor captured when an unfinished full sync started.
    public func pendingHistoryId(for email: String) -> String? {
        (try? db.query("SELECT pending_history_id FROM accounts WHERE email = ?", [email]))?.first?.optionalString("pending_history_id")
    }

    public func setPendingHistoryId(_ historyId: String?, for email: String) throws {
        try db.execute("UPDATE accounts SET pending_history_id = ? WHERE email = ?", [historyId, email])
    }

    // MARK: Messages

    /// Whether any mail is stored yet, for telling a first sync apart from an empty view.
    public func hasMessages() -> Bool {
        ((try? reader.query("SELECT 1 AS x FROM threads LIMIT 1")) ?? []).isEmpty == false
    }

    /// The domains that send you the most mail, for brand logos.
    public func senderDomains(limit: Int = 400) -> [String] {
        let rows = (try? reader.query(
            """
            SELECT lower(substr(from_email, instr(from_email, '@') + 1)) AS domain, COUNT(*) AS n FROM messages
            WHERE instr(from_email, '@') > 0 AND labels NOT LIKE '%,SENT,%' AND labels NOT LIKE '%,SPAM,%' AND labels NOT LIKE '%,DRAFT,%'
            GROUP BY domain ORDER BY n DESC LIMIT ?
            """, [limit]
        )) ?? []
        return rows.map { $0.string("domain") }.filter { $0.contains(".") }
    }

    /// Who has written to you and whom you've written to, for recipient suggestions.
    public func contactHistory() -> ContactHistory {
        // With a single MAX(), SQLite takes the bare from_name from the newest message: the sender's latest name.
        let senders = (try? reader.query("""
            SELECT from_name, from_email, COUNT(*) AS n, MAX(date) AS last FROM messages
            WHERE from_email != '' AND labels NOT LIKE '%,SPAM,%' AND labels NOT LIKE '%,SENT,%' AND labels NOT LIKE '%,DRAFT,%'
            GROUP BY lower(from_email)
            """)) ?? []
        let sent = (try? reader.query("SELECT to_addr, cc, date FROM messages WHERE labels LIKE '%,SENT,%'")) ?? []
        return ContactHistory(
            senders: senders.map {
                ContactHistory.Sender(
                    name: $0.string("from_name"), email: $0.string("from_email"), count: $0.int("n"),
                    lastDate: Date(timeIntervalSince1970: $0.double("last"))
                )
            },
            sent: sent.map {
                ContactHistory.Sent(to: $0.string("to_addr"), cc: $0.string("cc"), date: Date(timeIntervalSince1970: $0.double("date")))
            }
        )
    }

    public func messageIds(account: String) -> Set<String> {
        let rows = (try? reader.query("SELECT id FROM messages WHERE account = ?", [account])) ?? []
        return Set(rows.map { $0.string("id") })
    }

    /// Inserts or updates messages. Existing tags and tagging state are kept.
    public func upsert(_ messages: [MailMessage]) throws {
        guard !messages.isEmpty else { return }
        try db.transaction {
            for m in messages {
                try db.execute(
                    """
                    INSERT INTO messages(account, id, thread_id, from_name, from_email, reply_to, to_addr, cc, subject,
                                         snippet, date, labels, message_id, refs, has_attachments)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account, id) DO UPDATE SET
                        thread_id = excluded.thread_id, from_name = excluded.from_name, from_email = excluded.from_email,
                        reply_to = excluded.reply_to, to_addr = excluded.to_addr, cc = excluded.cc,
                        subject = excluded.subject, snippet = excluded.snippet, date = excluded.date,
                        labels = excluded.labels, message_id = excluded.message_id, refs = excluded.refs,
                        has_attachments = excluded.has_attachments
                    """,
                    [m.account, m.id, m.threadId, m.fromName, m.fromEmail, m.replyTo, m.to, m.cc, m.subject,
                     m.snippet, m.date, Self.encode(m.labels), m.messageIdHeader, m.references, !m.listedAttachments.isEmpty]
                )
                // Bodies live apart so the hot table stays small.
                try db.execute(
                    "INSERT OR REPLACE INTO message_bodies(account, id, body_html, body_text, attachments) VALUES (?, ?, ?, ?, ?)",
                    [m.account, m.id, Self.packBody(m.bodyHTML), Self.packBody(m.bodyText), Self.encode(m.attachments)]
                )
                try deleteFromSearch(account: m.account, id: m.id)
                // File names are searchable, so "invoice" finds the email with invoice.pdf.
                let fileNames = m.listedAttachments.map(\.filename).joined(separator: " ")
                let sender = "\(m.fromName) \(m.fromEmail) \(m.to) \(m.cc)", body = m.bodyText + " " + fileNames
                if SearchIndex.isLean(db) {
                    try db.execute("INSERT INTO messages_fts(subject, sender, body) VALUES (?, ?, ?)", [m.subject, sender, body])
                } else {
                    try db.execute(
                        "INSERT INTO messages_fts(account, id, subject, sender, body) VALUES (?, ?, ?, ?, ?)",
                        [m.account, m.id, m.subject, sender, body]
                    )
                }
                try db.execute(
                    "INSERT OR REPLACE INTO fts_map(account, id, fts_rowid, thread_id, date) VALUES (?, ?, ?, ?, ?)",
                    [m.account, m.id, db.lastInsertRowID(), m.threadId, m.date]
                )
            }
            try ThreadIndex.refresh(db, Set(messages.map { ThreadKey(account: $0.account, threadId: $0.threadId) }))
        }
    }

    public func setLabels(_ labels: Set<String>, account: String, messageId: String) throws {
        try db.transaction {
            try writeLabels(labels, account: account, messageId: messageId)
            try ThreadIndex.refresh(db, try ThreadIndex.keys(db, account: account, messageIds: [messageId]))
        }
    }

    /// Removes a message from the full-text index by its remembered rowid, a direct lookup rather than a scan.
    private func deleteFromSearch(account: String, id: String) throws {
        guard let rowid = try db.query("SELECT fts_rowid FROM fts_map WHERE account = ? AND id = ?", [account, id]).first?.int("fts_rowid") else { return }
        try db.execute("DELETE FROM messages_fts WHERE rowid = ?", [rowid])
        // While the lean index is filling in, it has to forget deleted mail too. (No table, no harm.)
        try? db.execute("DELETE FROM \(SearchIndex.leanName) WHERE rowid = ?", [rowid])
        try db.execute("DELETE FROM fts_map WHERE account = ? AND id = ?", [account, id])
    }

    private func writeLabels(_ labels: Set<String>, account: String, messageId: String) throws {
        try db.execute("UPDATE messages SET labels = ? WHERE account = ? AND id = ?", [Self.encode(labels), account, messageId])
    }

    public func deleteMessages(account: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            let affected = try ThreadIndex.keys(db, account: account, messageIds: ids)
            defer { try? ThreadIndex.refresh(db, affected) }
            if let vault {
                for id in ids {
                    for row in try db.query("SELECT part_id FROM attachment_files WHERE account = ? AND message_id = ? AND in_file = 1", [account, id]) {
                        vault.remove(account: account, messageId: id, partId: row.string("part_id"))
                    }
                }
            }
            for id in ids {
                try db.execute("DELETE FROM messages WHERE account = ? AND id = ?", [account, id])
                try db.execute("DELETE FROM message_bodies WHERE account = ? AND id = ?", [account, id])
                try db.execute("DELETE FROM attachment_files WHERE account = ? AND message_id = ?", [account, id])
                try db.execute("DELETE FROM message_tags WHERE account = ? AND message_id = ?", [account, id])
                try deleteFromSearch(account: account, id: id)
            }
        }
    }

    public func message(account: String, id: String) -> MailMessage? {
        (try? reader.query("\(Self.selectWithBodies) WHERE m.account = ? AND m.id = ?", [account, id]))?.first.map(Self.message(from:))
    }

    public func threadMessages(account: String, threadId: String) -> [MailMessage] {
        let rows = (try? reader.query(
            "\(Self.selectWithBodies) WHERE m.account = ? AND m.thread_id = ? AND m.labels NOT LIKE '%,DRAFT,%' ORDER BY m.date ASC",
            [account, threadId]
        )) ?? []
        return rows.map(Self.message(from:))
    }

    /// Messages in a conversation stored before Nook kept attachments. Fetching them again fills that in.
    public func messagesMissingAttachments(account: String, threadId: String) -> [String] {
        let rows = (try? reader.query(
            """
            SELECT m.id FROM messages m JOIN message_bodies b ON b.account = m.account AND b.id = m.id
            WHERE m.account = ? AND m.thread_id = ? AND b.attachments IS NULL
            """,
            [account, threadId]
        )) ?? []
        return rows.map { $0.string("id") }
    }

    /// The newest messages stored before Nook kept attachments, for filling them in a few at a time.
    public func messagesMissingAttachments(account: String, limit: Int) -> [String] {
        let rows = (try? reader.query(
            """
            SELECT m.id FROM messages m JOIN message_bodies b ON b.account = m.account AND b.id = m.id
            WHERE m.account = ? AND b.attachments IS NULL ORDER BY m.date DESC LIMIT ?
            """,
            [account, limit]
        )) ?? []
        return rows.map { $0.string("id") }
    }

    // MARK: Attachment files

    /// A file's bytes, if they've been downloaded.
    public func storedAttachment(account: String, messageId: String, partId: String) -> Data? {
        guard let row = (try? reader.query(
            "SELECT data, in_file FROM attachment_files WHERE account = ? AND message_id = ? AND part_id = ?",
            [account, messageId, partId]
        ))?.first else { return nil }
        if row.int("in_file") == 1 { return vault?.read(account: account, messageId: messageId, partId: partId) }
        return row.data("data")
    }

    /// Kept files: in the vault, or still inside the store from before the vault.
    private static let keptFile = "(f.in_file = 1 OR f.data IS NOT NULL)"
    private static let keptBytes = "(CASE WHEN f.in_file = 1 THEN f.size ELSE length(f.data) END)"

    /// Messages whose files haven't been looked at yet, newest first. Once `budget` bytes are stored, only mail newer
    /// than the oldest kept file qualifies: anything older would be thrown out again straight away.
    public func messagesAwaitingAttachments(account: String, budget: Int, limit: Int) -> [String] {
        var floor = 0.0
        if let totals = (try? reader.query(
            """
            SELECT COALESCE(SUM(\(Self.keptBytes)), 0) AS bytes, MIN(m.date) AS oldest
            FROM attachment_files f JOIN messages m ON m.account = f.account AND m.id = f.message_id
            WHERE \(Self.keptFile)
            """
        ))?.first, totals.int("bytes") >= budget {
            floor = totals.double("oldest")
        }
        let rows = (try? reader.query(
            """
            SELECT m.id FROM messages m
            WHERE m.account = ? AND m.has_attachments = 1 AND m.date > ?
              AND NOT EXISTS (SELECT 1 FROM attachment_files f WHERE f.account = m.account AND f.message_id = m.id)
            ORDER BY m.date DESC LIMIT ?
            """,
            [account, floor, limit]
        )) ?? []
        return rows.map { $0.string("id") }
    }

    /// Records what was downloaded for a message. A nil means that file isn't kept. An empty list still marks the
    /// message as done.
    public func storeAttachments(account: String, messageId: String, files: [(partId: String, data: Data?)]) throws {
        // Files go to disk first, so a row never points at a file that isn't there.
        if let vault {
            for file in files { if let data = file.data { try vault.write(data, account: account, messageId: messageId, partId: file.partId) } }
        }
        try db.transaction {
            for file in files.isEmpty ? [(partId: "", data: nil)] : files {
                let inFile = vault != nil && file.data != nil
                try db.execute(
                    "INSERT OR REPLACE INTO attachment_files(account, message_id, part_id, data, in_file, size) VALUES (?, ?, ?, ?, ?, ?)",
                    [account, messageId, file.partId, inFile ? nil : file.data, inFile, file.data?.count]
                )
            }
        }
    }

    /// Drops the files on the oldest mail until the stored files fit in `budget` bytes.
    public func trimStoredAttachments(toBudget budget: Int) throws {
        let rows = try db.query(
            """
            SELECT f.rowid AS row, f.account, f.message_id, f.part_id, f.in_file, \(Self.keptBytes) AS bytes
            FROM attachment_files f JOIN messages m ON m.account = f.account AND m.id = f.message_id
            WHERE \(Self.keptFile) ORDER BY m.date
            """
        )
        var excess = rows.reduce(0) { $0 + $1.int("bytes") } - budget
        var dropped: [Row] = []
        try db.transaction {
            for row in rows where excess > 0 {
                try db.execute("UPDATE attachment_files SET data = NULL, in_file = 0, size = NULL WHERE rowid = ?", [row.int("row")])
                excess -= row.int("bytes")
                if row.int("in_file") == 1 { dropped.append(row) }
            }
        }
        for row in dropped {
            vault?.remove(account: row.string("account"), messageId: row.string("message_id"), partId: row.string("part_id"))
        }
    }

    /// After the limit goes up: files dropped or skipped earlier get another look.
    public func retrySkippedAttachments() throws {
        try db.execute("DELETE FROM attachment_files WHERE data IS NULL AND in_file = 0")
    }

    /// Whether any downloaded files are still inside the store, from before the vault.
    public var attachmentsLeftInStore: Bool {
        vault != nil && ((try? backgroundReader.query("SELECT 1 AS x FROM attachment_files WHERE data IS NOT NULL LIMIT 1")) ?? []).isEmpty == false
    }

    /// Moves up to `limit` files from inside the store to the vault. Returns how many moved. The store keeps the
    /// space they used until it's compacted.
    @discardableResult
    public func moveAttachmentsToVault(limit: Int = 20) throws -> Int {
        guard let vault else { return 0 }
        let rows = try backgroundReader.query(
            "SELECT rowid AS row, account, message_id, part_id, data FROM attachment_files WHERE data IS NOT NULL LIMIT ?", [limit]
        )
        var moved: [(row: Int, size: Int)] = []
        for row in rows {
            guard let data = row.data("data") else { continue }
            try vault.write(data, account: row.string("account"), messageId: row.string("message_id"), partId: row.string("part_id"))
            moved.append((row.int("row"), data.count))
        }
        try db.transaction {
            for file in moved {
                try db.execute("UPDATE attachment_files SET data = NULL, in_file = 1, size = ? WHERE rowid = ? AND data IS NOT NULL", [file.size, file.row])
            }
        }
        return moved.count
    }

    /// Dev builds: the store's size, how much of it is free space that compacting gives back, and how many
    /// attachment files are still inside it. Instant: it reads two counters, not the store. (Breaking the space down
    /// by table means decrypting every page, which took minutes on a store of several gigabytes.)
    public func storageBreakdown() -> [(name: String, bytes: Int)] {
        let pageSize = (try? backgroundReader.query("PRAGMA page_size").first?.int("page_size")) ?? 0
        let pages = (try? backgroundReader.query("PRAGMA page_count").first?.int("page_count")) ?? 0
        let free = (try? backgroundReader.query("PRAGMA freelist_count").first?.int("freelist_count")) ?? 0
        return [("store file", pages * pageSize), ("in use", (pages - free) * pageSize), ("free space (compacting gives it back)", free * pageSize)]
    }

    // MARK: Slimming a store from before

    /// Compresses up to `limit` bodies stored as text, after rowid `cursor`. Returns the last rowid looked at, or nil
    /// when there are none left. Walks by rowid, so each step reads only its own rows.
    public func compressBodies(after cursor: Int, limit: Int = 200) throws -> Int? {
        let rows = try backgroundReader.query(
            "SELECT rowid AS row, body_html, body_text FROM message_bodies WHERE rowid > ? ORDER BY rowid LIMIT ?", [cursor, limit]
        )
        guard let last = rows.last?.int("row") else { return nil }
        var changes: [(row: Int, html: Any, text: Any)] = []
        for row in rows where row.data("body_html") == nil || row.data("body_text") == nil {
            let html = row.data("body_html").map { $0 as Any } ?? Self.packBody(row.string("body_html"))
            let text = row.data("body_text").map { $0 as Any } ?? Self.packBody(row.string("body_text"))
            if html is Data || text is Data { changes.append((row.int("row"), html, text)) }
        }
        if !changes.isEmpty {
            try db.transaction {
                for change in changes {
                    try db.execute("UPDATE message_bodies SET body_html = ?, body_text = ? WHERE rowid = ?", [change.html, change.text, change.row])
                }
            }
        }
        return last
    }

    /// Copies up to `limit` entries of the old search index into the lean one, after rowid `cursor`. Returns the
    /// last rowid copied, or nil when the copy has caught up and the lean index has taken over.
    public func slimSearchIndex(after cursor: Int, limit: Int = 500) throws -> Int? {
        guard !SearchIndex.isLean(db) else { return nil }
        let rows = try backgroundReader.query(
            "SELECT rowid AS row, subject, sender, body FROM messages_fts WHERE rowid > ? ORDER BY rowid LIMIT ?", [cursor, limit]
        )
        guard let last = rows.last?.int("row") else {
            // Caught up. Entries at or before the cursor that the copy missed (a rowid reused after the newest
            // entry was deleted) are found through the small rowid map, without the write lock, and copied first.
            let missing = try backgroundReader.query(
                "SELECT fts_rowid AS row FROM fts_map WHERE fts_rowid <= ? AND fts_rowid NOT IN (SELECT rowid FROM \(SearchIndex.leanName))", [cursor]
            ).map { $0.int("row") }
            try copyToLeanIndex(missing)
            try SearchIndex.switchToLean(db, after: cursor)
            return nil
        }
        try copyToLeanIndex(rows)
        return last
    }

    private func copyToLeanIndex(_ rowids: [Int]) throws {
        guard !rowids.isEmpty else { return }
        for start in stride(from: 0, to: rowids.count, by: 100) {
            let chunk = Array(rowids[start..<min(start + 100, rowids.count)])
            let rows = try backgroundReader.query(
                "SELECT rowid AS row, subject, sender, body FROM messages_fts WHERE rowid IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ", ")))", chunk
            )
            try copyToLeanIndex(rows)
        }
    }

    private func copyToLeanIndex(_ rows: [Row]) throws {
        try db.transaction {
            for row in rows {
                try db.execute(
                    "INSERT OR REPLACE INTO \(SearchIndex.leanName)(rowid, subject, sender, body) VALUES (?, ?, ?, ?)",
                    [row.int("row"), row.string("subject"), row.string("sender"), row.string("body")]
                )
            }
        }
    }

    public var searchIndexIsLean: Bool { SearchIndex.isLean(db) }

    /// The old search index, set aside and waiting for compacting to drop it.
    public var hasRetiredSearchIndex: Bool {
        ((try? backgroundReader.query("SELECT 1 AS x FROM sqlite_schema WHERE name = ?", [SearchIndex.retiredName])) ?? []).isEmpty == false
    }

    /// Rewrites the store without the space its old attachment files used. Takes the write lock for as long as it
    /// runs (tens of seconds for a big store), so it's only run where nothing is waiting to write.
    public func compact() throws {
        try db.run("DROP TABLE IF EXISTS \(SearchIndex.retiredName)")
        try db.run("VACUUM")
        // With a write-ahead log, the compacted store lands in the log first; the file only shrinks once it's
        // checkpointed back.
        try db.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Adds and removes labels on every message in a thread. Returns the labels from before the change, for undo.
    @discardableResult
    public func modifyThread(account: String, threadId: String, add: Set<String>, remove: Set<String>) throws -> [LabelSnapshot] {
        try db.transaction {
            let rows = try db.query("SELECT id, labels FROM messages WHERE account = ? AND thread_id = ?", [account, threadId])
            var snapshots: [LabelSnapshot] = []
            for row in rows {
                let id = row.string("id")
                let before = Self.decode(row.string("labels"))
                snapshots.append(LabelSnapshot(account: account, messageId: id, labels: before))
                let after = before.subtracting(remove).union(add)
                if after != before { try writeLabels(after, account: account, messageId: id) }
            }
            try ThreadIndex.refresh(db, [ThreadKey(account: account, threadId: threadId)])
            return snapshots
        }
    }

    /// Adds and removes labels on a single message. Returns the labels from before the change.
    @discardableResult
    public func modifyMessage(account: String, id: String, add: Set<String>, remove: Set<String>) throws -> [LabelSnapshot] {
        guard let message = message(account: account, id: id) else { return [] }
        try setLabels(message.labels.subtracting(remove).union(add), account: account, messageId: id)
        return [LabelSnapshot(account: account, messageId: id, labels: message.labels)]
    }

    public func restore(_ snapshots: [LabelSnapshot]) throws {
        try db.transaction {
            var affected = Set<ThreadKey>()
            for snapshot in snapshots {
                try writeLabels(snapshot.labels, account: snapshot.account, messageId: snapshot.messageId)
                affected.formUnion(try ThreadIndex.keys(db, account: snapshot.account, messageIds: [snapshot.messageId]))
            }
            try ThreadIndex.refresh(db, affected)
        }
    }

    // MARK: Listing

    /// One page of conversations, newest first. Browsing reads the thread index, so the cost depends on the page
    /// size, not the size of the mailbox. Search narrows with the full-text index first, then groups.
    public func threads(_ query: ThreadQuery) -> [ThreadSummary] {
        if query.search != nil { return searchThreads(query) }
        if query.mailbox == .drafts { return drafts(query) }
        if query.mailbox == .reminders {
            return summaries(for: pendingReminderKeys(account: query.account, limit: query.limit), mailbox: .all)
        }
        let keys = pageOfThreads(query)
        return summaries(for: keys, mailbox: query.effectiveMailbox)
    }

    /// Which `threads` column a mailbox filters on.
    private static func indexColumn(_ mailbox: Mailbox) -> String {
        switch mailbox {
        case .inbox: "in_inbox"
        case .sent: "in_sent"
        // Drafts aren't part of conversations; `drafts(_:)` lists them. Reminders have their own table.
        case .drafts, .reminders: "0"
        case .starred: "starred"
        case .trash: "in_trash"
        case .all: "visible"
        }
    }

    private func pageOfThreads(_ query: ThreadQuery) -> [ThreadKey] {
        var clauses = ["t.\(Self.indexColumn(query.effectiveMailbox)) = 1"]
        var arguments: [Any?] = []
        if let account = query.account {
            clauses.append("t.account = ?")
            arguments.append(account)
        }
        switch query.split {
        case .everything:
            break
        case .tag(let tag):
            clauses.append("EXISTS (SELECT 1 FROM thread_tags tt WHERE tt.account = t.account AND tt.thread_id = t.thread_id AND tt.tag = ?)")
            arguments.append(tag)
        case .other:
            clauses.append("t.split_tagged = 0")
        }
        if query.unreadOnly {
            if query.keepVisible.isEmpty {
                clauses.append("t.unread = 1")
            } else {
                let kept = query.keepVisible.sorted()
                clauses.append("(t.unread = 1 OR t.account || '/' || t.thread_id IN (\(Array(repeating: "?", count: kept.count).joined(separator: ", "))))")
                arguments += kept as [Any?]
            }
        }
        arguments.append(query.limit)
        let rows = (try? reader.query(
            "SELECT t.account, t.thread_id FROM threads t WHERE \(clauses.joined(separator: " AND ")) ORDER BY t.latest_date DESC LIMIT ?",
            arguments
        )) ?? []
        return rows.map { ThreadKey(account: $0.string("account"), threadId: $0.string("thread_id")) }
    }

    /// Unsent drafts, newest first, one row per conversation. A row shows who the draft is to.
    private func drafts(_ query: ThreadQuery) -> [ThreadSummary] {
        var clauses = ["m.labels LIKE '%,DRAFT,%'", "m.labels NOT LIKE '%,TRASH,%'"]
        var arguments: [Any?] = []
        if let account = query.account {
            clauses.append("m.account = ?")
            arguments.append(account)
        }
        arguments.append(query.limit)
        let rows = (try? reader.query(
            """
            SELECT m.account, m.id, m.thread_id, m.to_addr, m.subject, m.snippet, MAX(m.date) AS date
            FROM messages m WHERE \(clauses.joined(separator: " AND "))
            GROUP BY m.account, m.thread_id ORDER BY date DESC LIMIT ?
            """,
            arguments
        )) ?? []
        return rows.map { row in
            let recipients = Addresses.parseList(row.string("to_addr"))
            return ThreadSummary(
                account: row.string("account"), threadId: row.string("thread_id"), latestMessageId: row.string("id"),
                fromName: recipients.isEmpty ? "No recipient" : recipients.map { Addresses.displayName(name: $0.name, email: $0.email) }.joined(separator: ", "),
                fromEmail: recipients.first?.email ?? "", subject: row.string("subject"), snippet: row.string("snippet"),
                date: Date(timeIntervalSince1970: row.double("date")), messageCount: 1, isUnread: false, isStarred: false, tags: []
            )
        }
    }

    /// The row for each conversation: its newest message, message count and flags, in the order given.
    private func summaries(for keys: [ThreadKey], mailbox: Mailbox) -> [ThreadSummary] {
        guard !keys.isEmpty else { return [] }
        var byID: [String: ThreadSummary] = [:]
        let trashClause = mailbox == .trash ? "m.labels LIKE '%,TRASH,%'" : "m.labels NOT LIKE '%,TRASH,%'"
        for start in stride(from: 0, to: keys.count, by: 200) {
            let chunk = keys[start..<min(start + 200, keys.count)]
            let values = Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ", ")
            let arguments: [Any?] = chunk.flatMap { [$0.account, $0.threadId] as [Any?] }
            let rows = (try? reader.query("""
            WITH k(account, thread_id) AS (VALUES \(values)),
            g AS (
                SELECT m.account, m.thread_id, MAX(m.date) AS latest, COUNT(*) AS message_count,
                       MAX(m.labels LIKE '%,UNREAD,%') AS unread, MAX(m.labels LIKE '%,STARRED,%') AS starred,
                       MAX(m.has_attachments) AS attachments
                FROM k JOIN messages m ON m.account = k.account AND m.thread_id = k.thread_id
                WHERE m.labels NOT LIKE '%,SPAM,%' AND m.labels NOT LIKE '%,DRAFT,%' AND \(trashClause)
                GROUP BY m.account, m.thread_id
            )
            SELECT m.account, m.id, m.thread_id, m.from_name, m.from_email, m.subject, m.snippet, m.date,
                   g.message_count, g.unread, g.starred, g.attachments
            FROM g JOIN messages m ON m.account = g.account AND m.thread_id = g.thread_id AND m.date = g.latest
            GROUP BY m.account, m.thread_id
            """, arguments)) ?? []
            for row in rows {
                let summary = Self.summary(from: row)
                byID[summary.id] = summary
            }
        }
        var ordered = keys.compactMap { byID[$0.id] }
        let tags = threadTags(for: keys)
        let reminders = reminders(for: keys)
        for index in ordered.indices {
            ordered[index].tags = tags[ordered[index].id] ?? []
            ordered[index].reminder = reminders[ordered[index].id]
        }
        return ordered
    }

    /// One conversation by id, wherever it is (including trash), or nil if it isn't stored.
    public func thread(account: String, threadId: String) -> ThreadSummary? {
        let key = ThreadKey(account: account, threadId: threadId)
        return summaries(for: [key], mailbox: .all).first ?? summaries(for: [key], mailbox: .trash).first
    }

    /// The conversations with the newest full-text matches, walking matches newest first and stopping once a page
    /// is found, so a search matching most of a mailbox costs no more than one matching a few emails. Returns nil
    /// when the walk ran out before filling the page (a few very long conversations), and the caller groups instead.
    private func newestMatches(fts: String, clauses: [String], arguments: [Any?], limit: Int) -> [ThreadKey]? {
        let cap = max(1500, limit * 15)
        let rows = (try? reader.query("""
            SELECT f.account, f.thread_id FROM fts_map f INDEXED BY fts_map_newest
            JOIN messages m ON m.account = f.account AND m.id = f.id
            WHERE f.fts_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)
              AND \(clauses.joined(separator: " AND "))
            ORDER BY f.date DESC LIMIT ?
            """, [fts] + arguments + [cap])) ?? []
        var seen = Set<ThreadKey>()
        var keys: [ThreadKey] = []
        for row in rows {
            let key = ThreadKey(account: row.string("account"), threadId: row.string("thread_id"))
            if seen.insert(key).inserted { keys.append(key) }
            if keys.count == limit { return keys }
        }
        return rows.count < cap ? keys : nil
    }

    /// Search: full-text and operator matches at the message level, grouped into conversations.
    private func searchThreads(_ query: ThreadQuery) -> [ThreadSummary] {
        guard let search = query.search else { return [] }
        Thread.current.threadDictionary[Self.searchingKey] = true
        defer { Thread.current.threadDictionary[Self.searchingKey] = nil }
        var clauses = [
            "m.labels NOT LIKE '%,\(SystemLabel.spam),%'",
            "m.labels NOT LIKE '%,\(SystemLabel.draft),%'",
        ]
        var arguments: [Any?] = []

        let mailbox = query.effectiveMailbox
        if mailbox != .trash { clauses.append("m.labels NOT LIKE '%,\(SystemLabel.trash),%'") }
        if let label = mailbox.gmailLabel {
            clauses.append("m.labels LIKE ?")
            arguments.append("%,\(label),%")
        }
        if mailbox == .reminders {
            clauses.append("EXISTS (SELECT 1 FROM reminders r WHERE r.account = m.account AND r.thread_id = m.thread_id AND r.woke_at IS NULL)")
        }
        if let account = query.account {
            clauses.append("m.account = ?")
            arguments.append(account)
        }
        let fts = search.ftsExpression
        for value in search.from {
            clauses.append("(m.from_email LIKE ? OR m.from_name LIKE ?)")
            arguments += ["%\(value)%", "%\(value)%"]
        }
        for value in search.to {
            clauses.append("(m.to_addr LIKE ? OR m.cc LIKE ?)")
            arguments += ["%\(value)%", "%\(value)%"]
        }
        for value in search.tags {
            clauses.append("EXISTS (SELECT 1 FROM message_tags t WHERE t.account = m.account AND t.message_id = m.id AND t.tag LIKE ?)")
            arguments.append(value)
        }
        for value in search.accounts {
            clauses.append("m.account LIKE ?")
            arguments.append("%\(value)%")
        }
        if let unread = search.isUnread {
            clauses.append(unread ? "m.labels LIKE '%,UNREAD,%'" : "m.labels NOT LIKE '%,UNREAD,%'")
        }
        if search.isStarred == true {
            clauses.append("m.labels LIKE '%,STARRED,%'")
        }
        if search.hasAttachment {
            clauses.append("m.has_attachments = 1")
        }
        for value in search.filenames {
            clauses.append("""
            m.has_attachments = 1 AND EXISTS (SELECT 1 FROM message_bodies b, json_each(b.attachments) f
                WHERE b.account = m.account AND b.id = m.id AND json_extract(f.value, '$.isInline') = 0
                  AND json_extract(f.value, '$.filename') LIKE ?)
            """)
            arguments.append("%\(value)%")
        }

        if let fts, let found = newestMatches(fts: fts, clauses: clauses, arguments: arguments, limit: query.limit) {
            return summaries(for: found, mailbox: mailbox)
        }
        if let fts {
            clauses.append("""
            (m.account, m.id) IN (SELECT f.account, f.id FROM fts_map f
                WHERE f.fts_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?))
            """)
            arguments.append(fts)
        }

        // Group the matching messages by thread, then join back to fetch the newest one.
        let sql = """
        SELECT m.account, m.id, m.thread_id, m.from_name, m.from_email, m.subject, m.snippet, m.date,
               g.message_count, g.unread, g.starred, g.attachments
        FROM (
            SELECT m.account, m.thread_id, MAX(m.date) AS latest, COUNT(*) AS message_count,
                   MAX(m.labels LIKE '%,UNREAD,%') AS unread, MAX(m.labels LIKE '%,STARRED,%') AS starred,
                   MAX(m.has_attachments) AS attachments
            FROM messages m
            WHERE \(clauses.joined(separator: " AND "))
            GROUP BY m.account, m.thread_id
            ORDER BY latest DESC
            LIMIT ?
        ) g
        JOIN messages m ON m.account = g.account AND m.thread_id = g.thread_id AND m.date = g.latest
        GROUP BY m.account, m.thread_id
        ORDER BY g.latest DESC
        """
        arguments.append(query.limit)

        var summaries = ((try? reader.query(sql, arguments)) ?? []).map(Self.summary(from:))
        let keys = summaries.map { ThreadKey(account: $0.account, threadId: $0.threadId) }
        let tags = threadTags(for: keys)
        let reminders = reminders(for: keys)
        for index in summaries.indices {
            summaries[index].tags = tags[summaries[index].id] ?? []
            summaries[index].reminder = reminders[summaries[index].id]
        }
        return summaries
    }

    private static func summary(from row: Row) -> ThreadSummary {
        ThreadSummary(
            account: row.string("account"),
            threadId: row.string("thread_id"),
            latestMessageId: row.string("id"),
            fromName: row.string("from_name"),
            fromEmail: row.string("from_email"),
            subject: row.string("subject"),
            snippet: row.string("snippet"),
            date: Date(timeIntervalSince1970: row.double("date")),
            messageCount: row.int("message_count"),
            isUnread: row.int("unread") == 1,
            isStarred: row.int("starred") == 1,
            tags: [],
            hasAttachments: row.int("attachments") == 1
        )
    }

    /// Each conversation's tags, in the user's tag order.
    private func threadTags(for keys: [ThreadKey]) -> [String: [String]] {
        guard !keys.isEmpty else { return [:] }
        let order = Dictionary(uniqueKeysWithValues: tags().enumerated().map { ($1.name, $0) })
        var result: [String: [String]] = [:]
        for start in stride(from: 0, to: keys.count, by: 200) {
            let chunk = keys[start..<min(start + 200, keys.count)]
            let values = Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ", ")
            let arguments: [Any?] = chunk.flatMap { [$0.account, $0.threadId] as [Any?] }
            let rows = (try? reader.query("""
            WITH k(account, thread_id) AS (VALUES \(values))
            SELECT tt.account, tt.thread_id, tt.tag FROM k JOIN thread_tags tt ON tt.account = k.account AND tt.thread_id = k.thread_id
            """, arguments)) ?? []
            for row in rows {
                result["\(row.string("account"))/\(row.string("thread_id"))", default: []].append(row.string("tag"))
            }
        }
        return result.mapValues { $0.sorted { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) } }
    }

    /// Unread inbox conversations per account.
    public func unreadInboxCounts() -> [String: Int] {
        let rows = (try? reader.query("SELECT account, COUNT(*) AS n FROM threads WHERE in_inbox = 1 AND unread = 1 GROUP BY account")) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.string("account"), $0.int("n")) })
    }

    /// Conversation counts for each split of a mailbox, optionally for one account.
    /// With `unreadOnly`, counts only conversations that have something unread.
    public func splitCounts(account: String?, mailbox: Mailbox = .inbox, unreadOnly: Bool = false) -> SplitCounts {
        var clauses = ["t.\(Self.indexColumn(mailbox)) = 1"]
        var arguments: [Any?] = []
        if let account {
            clauses.append("t.account = ?")
            arguments.append(account)
        }
        if unreadOnly { clauses.append("t.unread = 1") }
        let filter = clauses.joined(separator: " AND ")

        let totals = (try? reader.query(
            "SELECT COUNT(*) AS total, COALESCE(SUM(t.split_tagged = 0), 0) AS other FROM threads t WHERE \(filter)", arguments
        ))?.first
        let rows = (try? reader.query(
            """
            SELECT tt.tag, COUNT(*) AS n FROM threads t
            JOIN thread_tags tt ON tt.account = t.account AND tt.thread_id = t.thread_id
            WHERE \(filter) GROUP BY tt.tag
            """,
            arguments
        )) ?? []
        return SplitCounts(
            total: totals?.int("total") ?? 0,
            tags: Dictionary(uniqueKeysWithValues: rows.map { ($0.string("tag"), $0.int("n")) }),
            other: totals?.int("other") ?? 0
        )
    }

    // MARK: Reminders

    /// Sets the conversation's reminder, replacing any it had.
    public func setReminder(_ reminder: Reminder) throws {
        try db.transaction {
            try db.execute(
                "INSERT OR REPLACE INTO reminders(account, thread_id, kind, due, since, woke_at) VALUES (?, ?, ?, ?, ?, ?)",
                [reminder.account, reminder.threadId, reminder.kind.rawValue, reminder.due, reminder.since, reminder.wokeAt]
            )
            try ThreadIndex.refresh(db, [ThreadKey(account: reminder.account, threadId: reminder.threadId)])
        }
    }

    /// Removes the conversation's reminder. Returns it, for undo.
    @discardableResult
    public func removeReminder(account: String, threadId: String) throws -> Reminder? {
        try db.transaction {
            guard let existing = try db.query("SELECT * FROM reminders WHERE account = ? AND thread_id = ?", [account, threadId])
                .first.map(Self.reminder(from:)) else { return nil }
            try db.execute("DELETE FROM reminders WHERE account = ? AND thread_id = ?", [account, threadId])
            try ThreadIndex.refresh(db, [ThreadKey(account: account, threadId: threadId)])
            return existing
        }
    }

    public func reminder(account: String, threadId: String) -> Reminder? {
        (try? reader.query("SELECT * FROM reminders WHERE account = ? AND thread_id = ?", [account, threadId]))?.first.map(Self.reminder(from:))
    }

    /// Reminders whose time has come, soonest first.
    public func dueReminders(at now: Date) -> [Reminder] {
        let rows = (try? db.query("SELECT * FROM reminders WHERE woke_at IS NULL AND due <= ? ORDER BY due", [now])) ?? []
        return rows.map(Self.reminder(from:))
    }

    /// When the next reminder goes off, for scheduling a wake-up.
    public func nextReminderDue() -> Date? {
        guard let row = (try? db.query("SELECT MIN(due) AS due FROM reminders WHERE woke_at IS NULL"))?.first, !row.isNull("due") else { return nil }
        return Date(timeIntervalSince1970: row.double("due"))
    }

    /// Records that a reminder went off, which moves its conversation to the top of the list.
    public func markReminderWoken(account: String, threadId: String, at date: Date) throws {
        try db.transaction {
            try db.execute("UPDATE reminders SET woke_at = ? WHERE account = ? AND thread_id = ?", [date, account, threadId])
            try ThreadIndex.refresh(db, [ThreadKey(account: account, threadId: threadId)])
        }
    }

    /// Drops reminders that no longer have anything to do:
    ///
    /// - a follow-up someone has replied to;
    /// - one that went off and has since been dealt with (it left the inbox) or answered.
    ///
    /// Returns how many were dropped.
    @discardableResult
    public func settleReminders() throws -> Int {
        try db.transaction {
            let answered = """
            EXISTS (SELECT 1 FROM messages m WHERE m.account = r.account AND m.thread_id = r.thread_id AND m.date > r.since
                    AND m.labels NOT LIKE '%,SENT,%' AND m.labels NOT LIKE '%,DRAFT,%' AND m.labels NOT LIKE '%,SPAM,%')
            """
            let inInbox = "EXISTS (SELECT 1 FROM threads t WHERE t.account = r.account AND t.thread_id = r.thread_id AND t.in_inbox = 1)"
            let rows = try db.query("""
            SELECT r.account, r.thread_id FROM reminders r WHERE
                (r.kind = 'followup' AND r.since IS NOT NULL AND \(answered))
                OR (r.woke_at IS NOT NULL AND NOT \(inInbox))
            """)
            let keys = Set(rows.map { ThreadKey(account: $0.string("account"), threadId: $0.string("thread_id")) })
            for key in keys {
                try db.execute("DELETE FROM reminders WHERE account = ? AND thread_id = ?", [key.account, key.threadId])
            }
            try ThreadIndex.refresh(db, keys)
            return keys.count
        }
    }

    /// Reminders set by the short-lived snooze build, which also archived their conversations. Marks them as plain
    /// reminders and returns them, so the caller can put those conversations back in the inbox. Runs once: afterwards
    /// there are none left to find.
    public func takeSnoozeBuildReminders() throws -> [Reminder] {
        try db.transaction {
            let rows = try db.query("SELECT * FROM reminders WHERE kind = 'snooze'")
            try db.execute("UPDATE reminders SET kind = 'remind' WHERE kind = 'snooze'")
            return rows.map(Self.reminder(from:))
        }
    }

    /// Conversations with a reminder still to go off, soonest first.
    private func pendingReminderKeys(account: String?, limit: Int) -> [ThreadKey] {
        var clauses = ["r.woke_at IS NULL", "t.visible = 1"]
        var arguments: [Any?] = []
        if let account {
            clauses.append("r.account = ?")
            arguments.append(account)
        }
        arguments.append(limit)
        let rows = (try? reader.query(
            """
            SELECT r.account, r.thread_id FROM reminders r JOIN threads t ON t.account = r.account AND t.thread_id = r.thread_id
            WHERE \(clauses.joined(separator: " AND ")) ORDER BY r.due LIMIT ?
            """,
            arguments
        )) ?? []
        return rows.map { ThreadKey(account: $0.string("account"), threadId: $0.string("thread_id")) }
    }

    private func reminders(for keys: [ThreadKey]) -> [String: Reminder] {
        guard !keys.isEmpty else { return [:] }
        var result: [String: Reminder] = [:]
        for start in stride(from: 0, to: keys.count, by: 200) {
            let chunk = keys[start..<min(start + 200, keys.count)]
            let values = Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ", ")
            let arguments: [Any?] = chunk.flatMap { [$0.account, $0.threadId] as [Any?] }
            let rows = (try? reader.query("""
            WITH k(account, thread_id) AS (VALUES \(values))
            SELECT r.* FROM k JOIN reminders r ON r.account = k.account AND r.thread_id = k.thread_id
            """, arguments)) ?? []
            for reminder in rows.map(Self.reminder(from:)) {
                result["\(reminder.account)/\(reminder.threadId)"] = reminder
            }
        }
        return result
    }

    private static func reminder(from row: Row) -> Reminder {
        Reminder(
            account: row.string("account"),
            threadId: row.string("thread_id"),
            kind: Reminder.Kind(stored: row.string("kind")),
            due: Date(timeIntervalSince1970: row.double("due")),
            since: row.isNull("since") ? nil : Date(timeIntervalSince1970: row.double("since")),
            wokeAt: row.isNull("woke_at") ? nil : Date(timeIntervalSince1970: row.double("woke_at"))
        )
    }

    // MARK: Tags

    public func tags() -> [Tag] {
        let rows = (try? reader.query("SELECT * FROM tags ORDER BY position, name")) ?? []
        return rows.map {
            Tag(name: $0.string("name"), description: $0.string("description"), colorIndex: $0.int("color"), isSplit: $0.int("split") == 1)
        }
    }

    /// Replaces the tag list. `renames` maps old names to new ones, so renamed tags keep their assignments
    /// (including ones you applied by hand). Tags that were removed lose theirs.
    public func saveTags(_ tags: [Tag], renames: [String: String] = [:]) throws {
        try db.transaction {
            for (old, new) in renames where old != new {
                try db.execute(
                    "INSERT OR IGNORE INTO message_tags(account, message_id, tag, source) SELECT account, message_id, ?, source FROM message_tags WHERE tag = ?",
                    [new, old]
                )
                try db.execute("DELETE FROM message_tags WHERE tag = ?", [old])
            }
            try db.execute("DELETE FROM tags")
            for (position, tag) in tags.enumerated() {
                try db.execute(
                    "INSERT INTO tags(name, description, color, position, split) VALUES (?, ?, ?, ?, ?)",
                    [tag.name, tag.description, tag.colorIndex, position, tag.isSplit]
                )
            }
            try db.execute("DELETE FROM message_tags WHERE tag NOT IN (SELECT name FROM tags)")
            try ThreadIndex.rebuild(db)
        }
    }

    /// Messages the tagger hasn't looked at yet, newest first. Messages you sent are skipped.
    /// Mail waiting for the tagger, newest first. `since` skips older mail, so loading years of history
    /// doesn't queue tens of thousands of messages for the on-device model.
    public func untaggedMessages(limit: Int, since: Date? = nil) -> [MailMessage] {
        let rows = (try? db.query(
            """
            \(Self.selectWithBodies)
            WHERE m.tagged = 0 AND m.date >= ? AND m.labels NOT LIKE '%,SENT,%' AND m.labels NOT LIKE '%,SPAM,%' AND m.labels NOT LIKE '%,DRAFT,%'
            ORDER BY m.date DESC LIMIT ?
            """,
            [since ?? Date(timeIntervalSince1970: 0), limit]
        )) ?? []
        return rows.map(Self.message(from:))
    }

    public func untaggedCount(since: Date? = nil) -> Int {
        (try? db.query(
            "SELECT COUNT(*) AS n FROM messages WHERE tagged = 0 AND date >= ? AND labels NOT LIKE '%,SENT,%' AND labels NOT LIKE '%,SPAM,%' AND labels NOT LIKE '%,DRAFT,%'",
            [since ?? Date(timeIntervalSince1970: 0)]
        ))?.first?.int("n") ?? 0
    }

    /// Records the tagger's verdict. Manual tags are never touched.
    public func setAutoTags(_ tags: [String], account: String, messageId: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM message_tags WHERE account = ? AND message_id = ? AND source = 'auto'", [account, messageId])
            for tag in tags {
                try db.execute(
                    "INSERT OR IGNORE INTO message_tags(account, message_id, tag, source) VALUES (?, ?, ?, 'auto')",
                    [account, messageId, tag]
                )
            }
            try db.execute("UPDATE messages SET tagged = 1 WHERE account = ? AND id = ?", [account, messageId])
            try ThreadIndex.refresh(db, try ThreadIndex.keys(db, account: account, messageIds: [messageId]))
        }
    }

    /// Applies a better tagging prompt to mail tagged with an older one. Needs Reply the tagger put on newsletters and
    /// bulk mail goes at once; recent mail is then tagged again, newest first, keeping its old tags until then.
    /// Tags you added yourself stay.
    public func upgradeTags(since: Date) throws {
        try db.transaction {
            let rows = try db.query(
                """
                SELECT m.account, m.thread_id, m.id, m.from_email, m.labels,
                       EXISTS (SELECT 1 FROM message_tags n WHERE n.account = r.account AND n.message_id = r.message_id AND n.tag = ?) AS newsletter
                FROM message_tags r JOIN messages m ON m.account = r.account AND m.id = r.message_id
                WHERE r.tag = ? AND r.source = 'auto'
                """,
                [TagPrompt.newsletterTag, TagPrompt.replyTag]
            ).filter {
                $0.int("newsletter") != 0
                    || TagPrompt.isBulk(labels: Set($0.string("labels").split(separator: ",").map(String.init)), fromEmail: $0.string("from_email"))
            }
            for row in rows {
                try db.execute(
                    "DELETE FROM message_tags WHERE account = ? AND message_id = ? AND tag = ? AND source = 'auto'",
                    [row.string("account"), row.string("id"), TagPrompt.replyTag]
                )
            }
            try db.execute("UPDATE messages SET tagged = 0 WHERE date >= ?", [since.timeIntervalSince1970])
            try ThreadIndex.refresh(db, Set(rows.map { ThreadKey(account: $0.string("account"), threadId: $0.string("thread_id")) }))
        }
    }

    public func tags(account: String, messageId: String) -> [String] {
        let rows = (try? db.query("SELECT tag FROM message_tags WHERE account = ? AND message_id = ? ORDER BY tag", [account, messageId])) ?? []
        return rows.map { $0.string("tag") }
    }

    /// Toggles a tag on a thread by hand. Adding applies to the newest message; removing clears it from the whole thread.
    public func toggleTag(_ tag: String, account: String, threadId: String) throws {
        try db.transaction {
            // Read on the write connection: this is part of the write.
            let messages = try db.query("SELECT id FROM messages WHERE account = ? AND thread_id = ? ORDER BY date ASC", [account, threadId])
                .map { $0.string("id") }
            guard let latest = messages.last else { return }
            let hasTag = try db.query(
                """
                SELECT 1 FROM message_tags t JOIN messages m ON m.account = t.account AND m.id = t.message_id
                WHERE m.account = ? AND m.thread_id = ? AND t.tag = ? LIMIT 1
                """,
                [account, threadId, tag]
            ).isEmpty == false

            if hasTag {
                for id in messages {
                    try db.execute("DELETE FROM message_tags WHERE account = ? AND message_id = ? AND tag = ?", [account, id, tag])
                }
            } else {
                try db.execute(
                    "INSERT OR REPLACE INTO message_tags(account, message_id, tag, source) VALUES (?, ?, ?, 'manual')",
                    [account, latest, tag]
                )
            }
            try ThreadIndex.refresh(db, [ThreadKey(account: account, threadId: threadId)])
        }
    }

    /// Clears automatic tags so the tagger re-runs over all mail, for example after editing tag descriptions.
    public func resetAutoTags() throws {
        try db.transaction {
            try db.execute("DELETE FROM message_tags WHERE source = 'auto'")
            try db.execute("UPDATE messages SET tagged = 0")
            try ThreadIndex.rebuild(db)
        }
    }

    // MARK: Encoding

    /// Bodies over a few hundred bytes are kept LZFSE-compressed, as a blob; shorter ones as text. HTML mail
    /// shrinks 5-10x, and bodies were most of a big store. A blob is how a compressed body is told apart.
    static func packBody(_ text: String) -> Any {
        let data = Data(text.utf8)
        guard data.count > 256, let packed = try? (data as NSData).compressed(using: .lzfse) as Data else { return text }
        return packed
    }

    static func unpackBody(_ row: Row, _ column: String) -> String {
        guard let packed = row.data(column) else { return row.string(column) }
        guard let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Full messages, bodies included. Only for reading a thread or tagging, never for lists.
    static let selectWithBodies = """
    SELECT m.*, COALESCE(b.body_html, '') AS body_html, COALESCE(b.body_text, '') AS body_text,
           b.attachments AS attachments
    FROM messages m LEFT JOIN message_bodies b ON b.account = m.account AND b.id = m.id
    """

    /// Labels are stored as `,A,B,` so a single `LIKE '%,A,%'` finds them.
    static func encode(_ labels: Set<String>) -> String {
        "," + labels.sorted().joined(separator: ",") + ","
    }

    static func decode(_ labels: String) -> Set<String> {
        Set(labels.split(separator: ",").map(String.init))
    }

    static func encode(_ attachments: [Attachment]) -> String {
        guard let data = try? JSONEncoder().encode(attachments) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeAttachments(_ json: String) -> [Attachment] {
        guard !json.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Attachment].self, from: Data(json.utf8))) ?? []
    }

    static func message(from row: Row) -> MailMessage {
        MailMessage(
            id: row.string("id"),
            account: row.string("account"),
            threadId: row.string("thread_id"),
            fromName: row.string("from_name"),
            fromEmail: row.string("from_email"),
            replyTo: row.string("reply_to"),
            to: row.string("to_addr"),
            cc: row.string("cc"),
            subject: row.string("subject"),
            snippet: row.string("snippet"),
            bodyHTML: unpackBody(row, "body_html"),
            bodyText: unpackBody(row, "body_text"),
            date: Date(timeIntervalSince1970: row.double("date")),
            labels: decode(row.string("labels")),
            messageIdHeader: row.string("message_id"),
            references: row.string("refs"),
            attachments: decodeAttachments(row.string("attachments"))
        )
    }
}
