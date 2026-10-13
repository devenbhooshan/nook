import Foundation

extension MailRepository {
    // MARK: Rules

    public func rules() -> [MailRule] {
        let rows = (try? reader.query("SELECT definition FROM rules ORDER BY position, rowid")) ?? []
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(MailRule.self, from: Data($0.string("definition").utf8)) }
    }

    /// Adds the rule, or replaces the one with the same id.
    public func saveRule(_ rule: MailRule) throws {
        let definition = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        try db.transaction {
            let position = try db.query("SELECT position FROM rules WHERE id = ?", [rule.id.uuidString]).first?.int("position")
                ?? (try db.query("SELECT COALESCE(MAX(position) + 1, 0) AS next FROM rules").first?.int("next") ?? 0)
            try db.execute(
                "INSERT OR REPLACE INTO rules(id, position, definition) VALUES (?, ?, ?)",
                [rule.id.uuidString, position, definition]
            )
        }
    }

    public func deleteRule(id: UUID) throws {
        try db.execute("DELETE FROM rules WHERE id = ?", [id.uuidString])
    }

    /// Keeps rules pointing at the right tag when tags are renamed, and stops them adding tags that were removed.
    /// Call inside the tag-saving transaction.
    func updateRuleTags(renames: [String: String], remaining: Set<String>) throws {
        for var rule in rules() {
            guard let tag = rule.actions.tag else { continue }
            let renamed = renames[tag] ?? tag
            let updated = remaining.contains(renamed) ? renamed : nil
            guard updated != tag else { continue }
            rule.actions.tag = updated
            try saveRule(rule)
        }
    }

    /// Adds tags a rule applied. They're kept apart from the model's tags (re-tagging leaves them alone), and the
    /// email is marked as tagged so the model doesn't second-guess the rule.
    public func addRuleTags(_ tags: [String], account: String, messageId: String) throws {
        guard !tags.isEmpty else { return }
        try db.transaction {
            for tag in tags {
                try db.execute(
                    "INSERT OR IGNORE INTO message_tags(account, message_id, tag, source) SELECT ?, ?, name, 'rule' FROM tags WHERE name = ?",
                    [account, messageId, tag]
                )
            }
            try db.execute("UPDATE messages SET tagged = 1 WHERE account = ? AND id = ?", [account, messageId])
            try ThreadIndex.refresh(db, try ThreadIndex.keys(db, account: account, messageIds: [messageId]))
        }
    }

    /// Recent received mail with its text, newest first, for previewing a rule and applying it to mail you have.
    public func recentReceivedMessages(limit: Int) -> [MailMessage] {
        let rows = (try? reader.query(
            """
            SELECT m.*, '' AS body_html, COALESCE(b.body_text, '') AS body_text
            FROM messages m LEFT JOIN message_bodies b ON b.account = m.account AND b.id = m.id
            WHERE m.labels NOT LIKE '%,SENT,%' AND m.labels NOT LIKE '%,TRASH,%'
            ORDER BY m.date DESC LIMIT ?
            """,
            [limit]
        )) ?? []
        return rows.map(Self.message(from:))
    }
}
