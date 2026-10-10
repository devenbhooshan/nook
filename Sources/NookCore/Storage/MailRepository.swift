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
    private let reader: Database

    public init(db: Database, reader: Database? = nil) {
        self.db = db
        self.reader = reader ?? db
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
            try db.execute("DELETE FROM message_tags WHERE account = ?", [email])
            try db.execute("DELETE FROM messages_fts WHERE rowid IN (SELECT fts_rowid FROM fts_map WHERE account = ?)", [email])
            try db.execute("DELETE FROM fts_map WHERE account = ?", [email])
            try db.execute("DELETE FROM threads WHERE account = ?", [email])
            try db.execute("DELETE FROM thread_tags WHERE account = ?", [email])
            try db.execute("DELETE FROM accounts WHERE email = ?", [email])
        }
    }

    public func setHistoryId(_ historyId: String?, for email: String, syncedAt: Date = Date()) throws {
        try db.execute("UPDATE accounts SET history_id = ?, last_sync = ? WHERE email = ?", [historyId, syncedAt, email])
    }

    // MARK: Messages

    /// Whether any mail is stored yet, for telling a first sync apart from an empty view.
    public func hasMessages() -> Bool {
        ((try? reader.query("SELECT 1 AS x FROM threads LIMIT 1")) ?? []).isEmpty == false
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
                                         snippet, date, labels, message_id, refs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account, id) DO UPDATE SET
                        thread_id = excluded.thread_id, from_name = excluded.from_name, from_email = excluded.from_email,
                        reply_to = excluded.reply_to, to_addr = excluded.to_addr, cc = excluded.cc,
                        subject = excluded.subject, snippet = excluded.snippet, date = excluded.date,
                        labels = excluded.labels, message_id = excluded.message_id, refs = excluded.refs
                    """,
                    [m.account, m.id, m.threadId, m.fromName, m.fromEmail, m.replyTo, m.to, m.cc, m.subject,
                     m.snippet, m.date, Self.encode(m.labels), m.messageIdHeader, m.references]
                )
                // Bodies live apart so the hot table stays small.
                try db.execute(
                    "INSERT OR REPLACE INTO message_bodies(account, id, body_html, body_text) VALUES (?, ?, ?, ?)",
                    [m.account, m.id, m.bodyHTML, m.bodyText]
                )
                try deleteFromSearch(account: m.account, id: m.id)
                try db.execute(
                    "INSERT INTO messages_fts(account, id, subject, sender, body) VALUES (?, ?, ?, ?, ?)",
                    [m.account, m.id, m.subject, "\(m.fromName) \(m.fromEmail) \(m.to) \(m.cc)", m.bodyText]
                )
                try db.execute(
                    "INSERT OR REPLACE INTO fts_map(account, id, fts_rowid) VALUES (?, ?, ?)",
                    [m.account, m.id, db.lastInsertRowID()]
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
            for id in ids {
                try db.execute("DELETE FROM messages WHERE account = ? AND id = ?", [account, id])
                try db.execute("DELETE FROM message_bodies WHERE account = ? AND id = ?", [account, id])
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
            "\(Self.selectWithBodies) WHERE m.account = ? AND m.thread_id = ? ORDER BY m.date ASC",
            [account, threadId]
        )) ?? []
        return rows.map(Self.message(from:))
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
        let keys = pageOfThreads(query)
        return summaries(for: keys, mailbox: query.effectiveMailbox)
    }

    /// Which `threads` column a mailbox filters on.
    private static func indexColumn(_ mailbox: Mailbox) -> String {
        switch mailbox {
        case .inbox: "in_inbox"
        case .sent: "in_sent"
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
                       MAX(m.labels LIKE '%,UNREAD,%') AS unread, MAX(m.labels LIKE '%,STARRED,%') AS starred
                FROM k JOIN messages m ON m.account = k.account AND m.thread_id = k.thread_id
                WHERE m.labels NOT LIKE '%,SPAM,%' AND m.labels NOT LIKE '%,DRAFT,%' AND \(trashClause)
                GROUP BY m.account, m.thread_id
            )
            SELECT m.account, m.id, m.thread_id, m.from_name, m.from_email, m.subject, m.snippet, m.date,
                   g.message_count, g.unread, g.starred
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
        for index in ordered.indices { ordered[index].tags = tags[ordered[index].id] ?? [] }
        return ordered
    }

    /// Search: full-text and operator matches at the message level, grouped into conversations.
    private func searchThreads(_ query: ThreadQuery) -> [ThreadSummary] {
        guard let search = query.search else { return [] }
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
        if let account = query.account {
            clauses.append("m.account = ?")
            arguments.append(account)
        }
        if let fts = search.ftsExpression {
            clauses.append("(m.account, m.id) IN (SELECT account, id FROM messages_fts WHERE messages_fts MATCH ?)")
            arguments.append(fts)
        }
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

        // Group the matching messages by thread, then join back to fetch the newest one.
        let sql = """
        SELECT m.account, m.id, m.thread_id, m.from_name, m.from_email, m.subject, m.snippet, m.date,
               g.message_count, g.unread, g.starred
        FROM (
            SELECT m.account, m.thread_id, MAX(m.date) AS latest, COUNT(*) AS message_count,
                   MAX(m.labels LIKE '%,UNREAD,%') AS unread, MAX(m.labels LIKE '%,STARRED,%') AS starred
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
        let tags = threadTags(for: summaries.map { ThreadKey(account: $0.account, threadId: $0.threadId) })
        for index in summaries.indices { summaries[index].tags = tags[summaries[index].id] ?? [] }
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
            tags: []
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

    // MARK: Tags

    public func tags() -> [Tag] {
        let rows = (try? reader.query("SELECT * FROM tags ORDER BY position, name")) ?? []
        return rows.map {
            Tag(name: $0.string("name"), description: $0.string("description"), colorIndex: $0.int("color"), isSplit: $0.int("split") == 1)
        }
    }

    /// Replaces the tag list. Tags that were renamed or removed lose their assignments.
    public func saveTags(_ tags: [Tag]) throws {
        try db.transaction {
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
    public func untaggedMessages(limit: Int) -> [MailMessage] {
        let rows = (try? db.query(
            """
            \(Self.selectWithBodies)
            WHERE m.tagged = 0 AND m.labels NOT LIKE '%,SENT,%' AND m.labels NOT LIKE '%,SPAM,%' AND m.labels NOT LIKE '%,DRAFT,%'
            ORDER BY m.date DESC LIMIT ?
            """,
            [limit]
        )) ?? []
        return rows.map(Self.message(from:))
    }

    public func untaggedCount() -> Int {
        (try? db.query(
            "SELECT COUNT(*) AS n FROM messages WHERE tagged = 0 AND labels NOT LIKE '%,SENT,%' AND labels NOT LIKE '%,SPAM,%' AND labels NOT LIKE '%,DRAFT,%'"
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

    /// Full messages, bodies included. Only for reading a thread or tagging, never for lists.
    static let selectWithBodies = """
    SELECT m.*, COALESCE(b.body_html, '') AS body_html, COALESCE(b.body_text, '') AS body_text
    FROM messages m LEFT JOIN message_bodies b ON b.account = m.account AND b.id = m.id
    """

    /// Labels are stored as `,A,B,` so a single `LIKE '%,A,%'` finds them.
    static func encode(_ labels: Set<String>) -> String {
        "," + labels.sorted().joined(separator: ",") + ","
    }

    static func decode(_ labels: String) -> Set<String> {
        Set(labels.split(separator: ",").map(String.init))
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
            bodyHTML: row.string("body_html"),
            bodyText: row.string("body_text"),
            date: Date(timeIntervalSince1970: row.double("date")),
            labels: decode(row.string("labels")),
            messageIdHeader: row.string("message_id"),
            references: row.string("refs")
        )
    }
}
