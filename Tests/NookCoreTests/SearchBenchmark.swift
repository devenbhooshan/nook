import Foundation
import Testing
@testable import NookCore

/// A mailbox the size of a real one (120,000 messages of English text over four years, three accounts), for
/// measuring what people feel. Off by default because building it takes about 30 seconds: run `scripts/benchmark.sh`.
/// The store is kept at NOOK_BENCH_DB (or a temporary file) so later runs skip building it. Fails when a search,
/// list or count goes over its budget.
@Suite("SearchBenchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NOOK_BENCH"] == "1"))
struct SearchBenchmark {
    static let path = ProcessInfo.processInfo.environment["NOOK_BENCH_DB"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("nook-bench.sqlite").path
    static let secrets = MemorySecretStore()

    static let repo: MailRepository = {
        let fresh = !FileManager.default.fileExists(atPath: path)
        let keyFile = path + ".key"
        if !fresh, let key = try? Data(contentsOf: URL(fileURLWithPath: keyFile)) { try! secrets.set(key, for: MailStore.keyName) }
        let repo = try! MailStore.open(path: path, secrets: secrets).repository
        if fresh {
            try! secrets.lookup(MailStore.keyName)!.write(to: URL(fileURLWithPath: keyFile))
            build(repo)
        }
        return repo
    }()

    static func build(_ repo: MailRepository) {
        let accounts = ["me@example.com", "work@example.com", "side@example.com"]
        for account in accounts { try! repo.addAccount(email: account, name: account) }
        let dictionary = try! String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)
            .split(separator: "\n").map { $0.lowercased() }
        var rng = SeededGenerator(seed: 42)
        let vocabulary = Array(dictionary.shuffled(using: &rng).prefix(30_000)) + ["linkedin", "stripe", "invoice", "meeting", "developer", "github"]
        // Zipf: a few words are everywhere, most are rare, like real text.
        var cumulative: [Double] = []
        var total = 0.0
        for rank in 1...vocabulary.count { total += 1 / Double(rank); cumulative.append(total) }
        func word() -> String {
            let x = Double.random(in: 0..<total, using: &rng)
            var lo = 0, hi = cumulative.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if cumulative[mid] < x { lo = mid + 1 } else { hi = mid } }
            return vocabulary[lo]
        }
        func words(_ n: Int) -> String { (0..<n).map { _ in word() }.joined(separator: " ") }

        let count = 120_000
        let start = 1_700_000_000.0
        var batch: [MailMessage] = []
        for i in 0..<count {
            var labels: Set<String> = i % 5 == 0 ? [SystemLabel.inbox] : []
            if i % 11 == 0 { labels.insert(SystemLabel.unread) }
            if i % 97 == 0 { labels.insert(SystemLabel.trash) }
            let body = words(200)
            batch.append(MailMessage(
                id: "m\(i)", account: accounts[i % 3], threadId: "t\(i / 3)",
                fromName: "Sender \(i % 2000)", fromEmail: "sender\(i % 2000)@example.com", to: accounts[i % 3],
                subject: words(6), snippet: String(body.prefix(120)), bodyHTML: "", bodyText: body,
                date: Date(timeIntervalSince1970: start + Double(i) * 1000), labels: labels
            ))
            if batch.count == 1000 {
                try! repo.upsert(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try! repo.upsert(batch)
    }

    /// The median of three runs. `before` runs ahead of each one, untimed.
    static func time(before: () -> Void = {}, _ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<3 {
            before()
            let t = ContinuousClock().measure(body)
            samples.append(Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1000)
        }
        return samples.sorted()[1]
    }

    /// A small write, like the ones a sync or loading older mail makes all the time. Any change to the store makes
    /// SQLite drop every other connection's page cache, so the next read starts cold.
    static func write() {
        let labels: Set<String> = Int.random(in: 0...1) == 0 ? [SystemLabel.inbox] : [SystemLabel.inbox, SystemLabel.starred]
        try? repo.setLabels(labels, account: "me@example.com", messageId: "m0")
    }

    static let queries = ["s", "st", "str", "stri", "dev", "deve", "linked", "linkedin", "invoice", "meeting notes", "the"]

    @Test func searchTimes() throws {
        let repo = Self.repo
        var lines = ["query              warm       after a write   fts-only   matches"]
        for q in Self.queries {
            let search = SearchQuery.parse(q)!
            let query = ThreadQuery(search: search, limit: 100)
            let warm = Self.time { _ = repo.threads(query) }
            let cold = Self.time(before: Self.write) { _ = repo.threads(query) }
            let fts = search.ftsExpression!
            var matches = 0
            let ftsOnly = Self.time {
                matches = (try? repo.db.query("SELECT count(*) AS n FROM messages_fts WHERE messages_fts MATCH ?", [fts]).first?.int("n")) ?? 0
            }
            lines.append(q.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: "%7.0f ms   %7.0f ms     %7.0f ms   %d", warm, cold, ftsOnly, matches))
            #expect(max(warm, cold) < 50, "searching \(q) took \(Int(max(warm, cold))) ms")
        }
        print("\n" + lines.joined(separator: "\n"))
    }

    /// How long compacting a store this size takes, on a copy, so the real one is left alone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOOK_BENCH_COMPACT"] == "1")) func compactTime() throws {
        _ = Self.repo
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("nook-compact-\(UUID().uuidString).sqlite").path
        try Self.repo.db.run("VACUUM INTO '\(copy)'")
        defer { try? FileManager.default.removeItem(atPath: copy) }
        let repo = try MailStore.open(path: copy, secrets: Self.secrets).repository
        let size = (try FileManager.default.attributesOfItem(atPath: copy)[.size] as? Int) ?? 0
        let elapsed = try ContinuousClock().measure { try repo.compact() }
        print("compacting \(size / 1_000_000) MB took \(elapsed)")
    }

    /// Slimming a store from before (compressing bodies, the lean search index) runs while you use Nook. Measures,
    /// on a copy, the worst wait it causes for what you do: marking mail read, loading the inbox, searching.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOOK_BENCH_SLIM"] == "1")) func slimmingDoesntHoldYouUp() async throws {
        _ = Self.repo
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("nook-slim-\(UUID().uuidString).sqlite").path
        try Self.repo.db.run("VACUUM INTO '\(copy)'")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy + suffix) } }
        let repo = try MailStore.open(path: copy, secrets: Self.secrets).repository
        #expect(!repo.searchIndexIsLean, "the copy starts in the old format")

        let done = ManagedFlag()
        let phase = ManagedFlag()
        let started = ContinuousClock.now
        let slimming = Task.detached {
            var cursor = 0
            while let next = try repo.compressBodies(after: cursor, limit: 200) { cursor = next; try? await Task.sleep(for: .milliseconds(100)) }
            let bodies = ContinuousClock.now - started
            phase.set()
            cursor = 0
            while let next = try repo.slimSearchIndex(after: cursor, limit: 100) { cursor = next; try? await Task.sleep(for: .milliseconds(100)) }
            done.set()
            return (bodies, ContinuousClock.now - started)
        }
        var worstWrite = Duration.zero, worstList = Duration.zero, worstSearch = Duration.zero
        var worstWriteBodies = Duration.zero, worstWriteIndex = Duration.zero
        var rounds = 0
        while !done.isSet {
            let write = try ContinuousClock().measure { try repo.setLabels(rounds % 2 == 0 ? [SystemLabel.inbox] : [SystemLabel.inbox, SystemLabel.unread], account: "me@example.com", messageId: "m0") }
            worstWrite = max(worstWrite, write)
            if phase.isSet { worstWriteIndex = max(worstWriteIndex, write) } else { worstWriteBodies = max(worstWriteBodies, write) }
            worstList = max(worstList, ContinuousClock().measure { _ = repo.threadsForDisplay(ThreadQuery(limit: 100)) })
            worstSearch = max(worstSearch, ContinuousClock().measure { _ = repo.threadsForDisplay(ThreadQuery(search: SearchQuery.parse("invoice"), limit: 100)) })
            rounds += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        let (bodies, total) = try await slimming.value
        #expect(repo.searchIndexIsLean)
        let before = (try FileManager.default.attributesOfItem(atPath: copy)[.size] as? Int) ?? 0
        try repo.compact()
        let after = (try FileManager.default.attributesOfItem(atPath: copy)[.size] as? Int) ?? 0
        print("""

        slimming: bodies \(bodies), everything \(total), \(rounds) rounds of your actions meanwhile
        worst wait: mark read \(worstWrite) (while compressing bodies \(worstWriteBodies), while slimming the index \(worstWriteIndex)) · inbox \(worstList) · search \(worstSearch)
        store \(before / 1_000_000) MB → \(after / 1_000_000) MB after compacting
        """)
        #expect(worstWrite < .milliseconds(100) && worstList < .milliseconds(100) && worstSearch < .milliseconds(100))
    }

    @Test func listsAndCounts() {
        let repo = Self.repo
        let cases: [(String, () -> Void)] = [
            ("inbox list", { _ = repo.threads(ThreadQuery(limit: 100)) }),
            ("all mail list", { _ = repo.threads(ThreadQuery(mailbox: .all, limit: 100)) }),
            ("tab counts", { _ = repo.splitCounts(account: nil) }),
            ("unread counts", { _ = repo.unreadInboxCounts() }),
        ]
        var lines = ["step               warm       after a write"]
        for (name, body) in cases {
            let warm = Self.time(body)
            let cold = Self.time(before: Self.write, body)
            lines.append(name.padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: "%7.0f ms   %7.0f ms", warm, cold))
            #expect(max(warm, cold) < 50, "\(name) took \(Int(max(warm, cold))) ms")
        }
        print("\n" + lines.joined(separator: "\n"))
    }
}

/// Deterministic random numbers, so every run builds the same mailbox.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
