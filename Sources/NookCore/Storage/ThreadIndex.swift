import Foundation

/// A conversation, identified across accounts.
public struct ThreadKey: Hashable, Sendable {
    public var account: String
    public var threadId: String

    public init(account: String, threadId: String) {
        self.account = account
        self.threadId = threadId
    }

    public var id: String { "\(account)/\(threadId)" }
}

/// One row per conversation, kept up to date on every write, so lists and counts never scan messages.
///
/// `threads` holds the flags every view filters on (inbox, unread, starred…) plus the date lists sort by.
/// `thread_tags` holds each conversation's tags. Both are derived from `messages` and `message_tags`, so they can
/// always be rebuilt from scratch, and they are refreshed for exactly the conversations a write touched.
enum ThreadIndex {
    static let createSQL = """
    CREATE TABLE IF NOT EXISTS threads(
        account TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        latest_date REAL NOT NULL,
        in_inbox INTEGER NOT NULL,
        in_sent INTEGER NOT NULL,
        starred INTEGER NOT NULL,
        in_trash INTEGER NOT NULL,
        visible INTEGER NOT NULL,
        unread INTEGER NOT NULL,
        split_tagged INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(account, thread_id)
    );
    CREATE INDEX IF NOT EXISTS threads_inbox ON threads(in_inbox, latest_date DESC);
    CREATE INDEX IF NOT EXISTS threads_date ON threads(latest_date DESC);
    CREATE TABLE IF NOT EXISTS thread_tags(
        account TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        tag TEXT NOT NULL,
        PRIMARY KEY(account, thread_id, tag)
    );
    CREATE INDEX IF NOT EXISTS thread_tags_tag ON thread_tags(tag);
    \(remindersSQL)
    """

    /// Reminders and follow-ups, one per conversation. Here because a reminder that went off moves its conversation
    /// to the top of the list, so building the index reads it.
    static let remindersSQL = """
    CREATE TABLE IF NOT EXISTS reminders(
        account TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        due REAL NOT NULL,
        since REAL,
        woke_at REAL,
        PRIMARY KEY(account, thread_id)
    );
    CREATE INDEX IF NOT EXISTS reminders_due ON reminders(due);
    """

    /// Spam and drafts never appear anywhere.
    private static let alive = "m.labels NOT LIKE '%,SPAM,%' AND m.labels NOT LIKE '%,DRAFT,%'"

    private static let aggregate = """
    SELECT m.account, m.thread_id,
           MAX(COALESCE(MAX(CASE WHEN m.labels NOT LIKE '%,TRASH,%' THEN m.date END), MAX(m.date)),
               COALESCE((SELECT r.woke_at FROM reminders r WHERE r.account = m.account AND r.thread_id = m.thread_id), 0)),
           MAX(m.labels LIKE '%,INBOX,%' AND m.labels NOT LIKE '%,TRASH,%'),
           MAX(m.labels LIKE '%,SENT,%' AND m.labels NOT LIKE '%,TRASH,%'),
           MAX(m.labels LIKE '%,STARRED,%' AND m.labels NOT LIKE '%,TRASH,%'),
           MAX(m.labels LIKE '%,TRASH,%'),
           MAX(m.labels NOT LIKE '%,TRASH,%'),
           MAX(m.labels LIKE '%,UNREAD,%' AND m.labels NOT LIKE '%,TRASH,%'),
           0
    """

    private static let insertColumns = "threads(account, thread_id, latest_date, in_inbox, in_sent, starred, in_trash, visible, unread, split_tagged)"

    /// Recomputes every conversation. Used by migrations and when tag definitions change.
    static func rebuild(_ db: Database) throws {
        try db.transaction {
            try db.run("DELETE FROM threads; DELETE FROM thread_tags;")
            try db.run("INSERT INTO \(insertColumns) \(aggregate) FROM messages m WHERE \(alive) GROUP BY m.account, m.thread_id")
            try db.run("""
            INSERT OR IGNORE INTO thread_tags(account, thread_id, tag)
            SELECT m.account, m.thread_id, t.tag
            FROM message_tags t JOIN messages m ON m.account = t.account AND m.id = t.message_id
            WHERE \(alive)
            """)
            try db.run("""
            UPDATE threads SET split_tagged = 1 WHERE (account, thread_id) IN (
                SELECT tt.account, tt.thread_id FROM thread_tags tt JOIN tags g ON g.name = tt.tag WHERE g.split = 1)
            """)
        }
    }

    /// Recomputes just these conversations. Call inside the write's transaction.
    static func refresh(_ db: Database, _ keys: Set<ThreadKey>) throws {
        guard !keys.isEmpty else { return }
        let all = Array(keys)
        // Stay well under SQLite's bound-parameter limit.
        for start in stride(from: 0, to: all.count, by: 200) {
            let chunk = all[start..<min(start + 200, all.count)]
            let values = Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ", ")
            let arguments: [Any?] = chunk.flatMap { [$0.account, $0.threadId] as [Any?] }
            let keysCTE = "WITH k(account, thread_id) AS (VALUES \(values))"

            try db.execute("\(keysCTE) DELETE FROM threads WHERE (account, thread_id) IN (SELECT account, thread_id FROM k)", arguments)
            try db.execute("\(keysCTE) DELETE FROM thread_tags WHERE (account, thread_id) IN (SELECT account, thread_id FROM k)", arguments)
            try db.execute("""
            \(keysCTE) INSERT INTO \(insertColumns) \(aggregate)
            FROM k JOIN messages m ON m.account = k.account AND m.thread_id = k.thread_id
            WHERE \(alive) GROUP BY m.account, m.thread_id
            """, arguments)
            try db.execute("""
            \(keysCTE) INSERT OR IGNORE INTO thread_tags(account, thread_id, tag)
            SELECT m.account, m.thread_id, t.tag
            FROM k JOIN messages m ON m.account = k.account AND m.thread_id = k.thread_id
            JOIN message_tags t ON t.account = m.account AND t.message_id = m.id
            WHERE \(alive)
            """, arguments)
            try db.execute("""
            \(keysCTE) UPDATE threads SET split_tagged = 1 WHERE (account, thread_id) IN (
                SELECT tt.account, tt.thread_id FROM k JOIN thread_tags tt ON tt.account = k.account AND tt.thread_id = k.thread_id
                JOIN tags g ON g.name = tt.tag WHERE g.split = 1)
            """, arguments)
        }
    }

    /// The conversations that contain these messages.
    static func keys(_ db: Database, account: String, messageIds: [String]) throws -> Set<ThreadKey> {
        var keys = Set<ThreadKey>()
        for start in stride(from: 0, to: messageIds.count, by: 400) {
            let chunk = Array(messageIds[start..<min(start + 400, messageIds.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try db.query("SELECT DISTINCT thread_id FROM messages WHERE account = ? AND id IN (\(placeholders))", [account] + chunk)
            keys.formUnion(rows.map { ThreadKey(account: account, threadId: $0.string("thread_id")) })
        }
        return keys
    }
}
