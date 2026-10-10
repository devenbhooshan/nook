import Foundation
import SQLCipher

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DatabaseError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    /// The store is encrypted and this key doesn't open it.
    public static let wrongKey = DatabaseError(message: "The mail store couldn't be unlocked with this key.")
}

/// A result row, keyed by column name.
public struct Row {
    fileprivate var values: [String: Any] = [:]

    public func string(_ column: String) -> String { values[column] as? String ?? "" }
    public func optionalString(_ column: String) -> String? { values[column] as? String }

    public func int(_ column: String) -> Int {
        if let v = values[column] as? Int64 { return Int(v) }
        if let v = values[column] as? Double { return Int(v) }
        return 0
    }

    public func double(_ column: String) -> Double {
        if let v = values[column] as? Double { return v }
        if let v = values[column] as? Int64 { return Double(v) }
        return 0
    }

    public func isNull(_ column: String) -> Bool { values[column] == nil }
}

/// A small, thread-safe wrapper over SQLite. Every call is serialized through one lock,
/// which is plenty for a single-user mail store and keeps the code easy to reason about.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Nested `transaction` calls join the outer one instead of failing on a second BEGIN.
    private var transactionDepth = 0

    /// `~/Library/Application Support/Nook/nook.sqlite`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Nook", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nook.sqlite")
    }

    /// Opens (or creates) a database. Pass `":memory:"` for an in-memory store.
    ///
    /// - Parameters:
    ///   - key: A 256-bit key. The store is encrypted with SQLCipher (AES-256), so its file is unreadable without it.
    ///     `nil` opens an unencrypted store (tests, and legacy stores before they're converted).
    ///   - readOnly: Opens a second, read-only connection to an existing store. With WAL, reads on it
    ///     never wait for writes on the main connection, which keeps the UI responsive while a sync is writing.
    public init(path: String, key: Data? = nil, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError(message: "Could not open database at \(path): \(message)")
        }
        if let key {
            try run("PRAGMA key = \"x'\(key.hexString)'\"")
            // SQLCipher only checks the key on first read.
            guard (try? query("SELECT count(*) AS n FROM sqlite_master")) != nil else { throw DatabaseError.wrongKey }
        }
        do {
            // Another process (nook-mcp, or the app while nook-mcp runs) may hold a write lock briefly.
            try run("PRAGMA busy_timeout = 3000")
            guard !readOnly else { return }
            try run("PRAGMA journal_mode=WAL")
            try run("PRAGMA synchronous=NORMAL")
            try Schema.migrate(self)
        } catch let error as DatabaseError where error.message == "file is not a database" {
            // An encrypted store opened without its key looks like garbage to SQLite.
            throw DatabaseError.wrongKey
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: Encryption at rest

    /// Whether the file at `path` is an unencrypted SQLite database. Encrypted files start with random bytes.
    public static func isPlaintext(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Data("SQLite format 3\0".utf8)
    }

    /// Converts an unencrypted store to an encrypted one, in place. Writes an encrypted copy, checks it opens,
    /// then swaps it in, so the original stays untouched if anything fails along the way.
    public static func encryptInPlace(path: String, key: Data) throws {
        let fileManager = FileManager.default
        let staging = path + ".encrypting"
        try? fileManager.removeItem(atPath: staging)
        do {
            let plain = try Database(path: path)
            try plain.run("PRAGMA wal_checkpoint(TRUNCATE)")
            let version = try plain.query("PRAGMA user_version").first?.int("user_version") ?? 0
            let quoted = staging.replacingOccurrences(of: "'", with: "''")
            try plain.run("ATTACH DATABASE '\(quoted)' AS encrypted KEY \"x'\(key.hexString)'\"")
            _ = try plain.query("SELECT sqlcipher_export('encrypted')")
            try plain.run("PRAGMA encrypted.user_version = \(version)")
            try plain.run("DETACH DATABASE encrypted")
        }
        // Make sure the copy opens with the key before replacing anything.
        do { _ = try Database(path: staging, key: key, readOnly: true) }
        _ = try fileManager.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: staging))
        for suffix in ["-wal", "-shm"] { try? fileManager.removeItem(atPath: path + suffix) }
    }

    /// Runs one or more statements that take no arguments.
    public func run(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    public func execute(_ sql: String, _ arguments: [Any?] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
    }

    public func query(_ sql: String, _ arguments: [Any?] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }

            var row = Row()
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row.values[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT: row.values[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT: row.values[name] = String(cString: sqlite3_column_text(statement, i))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// The rowid of the last row inserted on this connection. Call while holding a transaction.
    public func lastInsertRowID() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try run("BEGIN IMMEDIATE")
        transactionDepth = 1
        defer { transactionDepth = 0 }
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ arguments: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }

        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            guard let argument else {
                sqlite3_bind_null(statement, index)
                continue
            }
            switch argument {
            case let v as String: sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as Bool: sqlite3_bind_int64(statement, index, v ? 1 : 0)
            case let v as Date: sqlite3_bind_double(statement, index, v.timeIntervalSince1970)
            default:
                sqlite3_finalize(statement)
                throw DatabaseError(message: "Unsupported argument type \(type(of: argument))")
            }
        }
        return statement
    }

    private func lastError() -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
    }
}

enum Schema {
    static let version = 6

    static func migrate(_ db: Database) throws {
        let current = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        guard current < version else { return }
        if current < 1 { try createTables(db) }
        if current < 2 { try addSplitTags(db, seeded: current < 1) }
        if current < 3 { try splitOutBodies(db) }
        if current < 4 {
            try db.run(ThreadIndex.createSQL)
            try ThreadIndex.rebuild(db)
        }
        if current < 5 {
            // Full-text rows were found by account and id, which FTS can't index, so every update scanned
            // the whole search index. Remember each message's search rowid instead.
            try db.run("""
            CREATE TABLE IF NOT EXISTS fts_map(
                account TEXT NOT NULL, id TEXT NOT NULL, fts_rowid INTEGER NOT NULL, PRIMARY KEY(account, id));
            INSERT OR REPLACE INTO fts_map(account, id, fts_rowid) SELECT account, id, rowid FROM messages_fts;
            """)
        }
        if current < 6 {
            // Where an unfinished first sync started, so an interrupted one resumes instead of starting over.
            let columns = Set(try db.query("PRAGMA table_info(accounts)").map { $0.string("name") })
            if !columns.contains("pending_history_id") {
                try db.run("ALTER TABLE accounts ADD COLUMN pending_history_id TEXT")
            }
        }
        try db.run("PRAGMA user_version = \(version)")
    }

    /// Version 1: the original schema.
    private static func createTables(_ db: Database) throws {
        try db.run("""
        CREATE TABLE IF NOT EXISTS accounts(
            email TEXT PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            history_id TEXT,
            color INTEGER NOT NULL DEFAULT 0,
            last_sync REAL,
            position INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages(
            account TEXT NOT NULL,
            id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            from_name TEXT NOT NULL DEFAULT '',
            from_email TEXT NOT NULL DEFAULT '',
            reply_to TEXT NOT NULL DEFAULT '',
            to_addr TEXT NOT NULL DEFAULT '',
            cc TEXT NOT NULL DEFAULT '',
            subject TEXT NOT NULL DEFAULT '',
            snippet TEXT NOT NULL DEFAULT '',
            body_html TEXT NOT NULL DEFAULT '',
            body_text TEXT NOT NULL DEFAULT '',
            date REAL NOT NULL,
            labels TEXT NOT NULL DEFAULT ',',
            message_id TEXT NOT NULL DEFAULT '',
            refs TEXT NOT NULL DEFAULT '',
            tagged INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(account, id)
        );
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(account, thread_id);
        CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC);
        CREATE INDEX IF NOT EXISTS messages_untagged ON messages(tagged, date DESC);
        CREATE TABLE IF NOT EXISTS tags(
            name TEXT PRIMARY KEY,
            description TEXT NOT NULL DEFAULT '',
            color INTEGER NOT NULL DEFAULT 0,
            position INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS message_tags(
            account TEXT NOT NULL,
            message_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'auto',
            PRIMARY KEY(account, message_id, tag)
        );
        CREATE INDEX IF NOT EXISTS message_tags_tag ON message_tags(tag);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            account UNINDEXED, id UNINDEXED, subject, sender, body,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)

    }

    /// Version 3: bodies move to their own table. Lists and counts scan `messages` constantly; with bodies inline,
    /// every scan dragged megabytes of HTML through memory (hundreds of milliseconds on a real mailbox).
    private static func splitOutBodies(_ db: Database) throws {
        try db.transaction {
            try db.run("""
            CREATE TABLE IF NOT EXISTS message_bodies(
                account TEXT NOT NULL,
                id TEXT NOT NULL,
                body_html TEXT NOT NULL DEFAULT '',
                body_text TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(account, id)
            )
            """)
            // Safe to re-run: only move bodies if they're still inline.
            let columns = Set(try db.query("PRAGMA table_info(messages)").map { $0.string("name") })
            guard columns.contains("body_html") else { return }
            try db.run("""
            INSERT OR REPLACE INTO message_bodies(account, id, body_html, body_text)
                SELECT account, id, body_html, body_text FROM messages;
            ALTER TABLE messages DROP COLUMN body_html;
            ALTER TABLE messages DROP COLUMN body_text;
            """)
        }
    }

    /// Version 2: tags can be inbox tabs. New stores get the default tags; upgraded ones get tabs for the default names.
    private static func addSplitTags(_ db: Database, seeded: Bool) throws {
        try db.run("ALTER TABLE tags ADD COLUMN split INTEGER NOT NULL DEFAULT 0")
        let tagCount = try db.query("SELECT COUNT(*) AS n FROM tags").first?.int("n") ?? 0
        if seeded || tagCount == 0 {
            for (position, tag) in Tag.defaults.enumerated() {
                try db.execute(
                    "INSERT OR IGNORE INTO tags(name, description, color, position, split) VALUES (?, ?, ?, ?, ?)",
                    [tag.name, tag.description, tag.colorIndex, position, tag.isSplit]
                )
            }
        } else {
            for tag in Tag.defaults where tag.isSplit {
                try db.execute("UPDATE tags SET split = 1 WHERE name = ?", [tag.name])
            }
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
