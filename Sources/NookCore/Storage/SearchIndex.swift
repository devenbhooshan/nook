import Foundation

/// The full-text index's shape. It used to store each email's text a second time; the lean one keeps only the
/// words, which is all search needs.
enum SearchIndex {
    static let leanName = "messages_fts_lean"
    /// The old index, set aside at the switch. Dropping it walks every page it used, so that waits for compacting,
    /// which only runs while you're away.
    static let retiredName = "messages_fts_retired"

    static func createLean(named name: String) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS \(name) USING fts5(
            subject, sender, body, content = '', contentless_delete = 1,
            tokenize = 'unicode61 remove_diacritics 2'
        )
        """
    }

    /// Whether `messages_fts` is already the lean index.
    static func isLean(_ db: Database) -> Bool {
        let sql = (try? db.query("SELECT sql FROM sqlite_schema WHERE name = 'messages_fts'").first?.string("sql")) ?? ""
        return sql.contains("contentless_delete")
    }

    /// Copies whatever the lean index doesn't have yet, then puts it in place of the old one. One short transaction:
    /// the old index is renamed aside, not dropped.
    /// Only entries after `cursor` are looked at, by rowid, so the write lock is held for a moment: checking the
    /// whole old index here held it for most of a second on a big store.
    static func switchToLean(_ db: Database, after cursor: Int = 0) throws {
        try db.transaction {
            try db.execute("""
            INSERT INTO \(leanName)(rowid, subject, sender, body)
                SELECT rowid, subject, sender, body FROM messages_fts WHERE rowid > ?
            """, [cursor])
            try db.run("""
            ALTER TABLE messages_fts RENAME TO \(retiredName);
            ALTER TABLE \(leanName) RENAME TO messages_fts;
            """)
        }
    }
}
