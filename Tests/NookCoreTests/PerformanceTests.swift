import Foundation
import Testing
@testable import NookCore

/// Every switch and action must feel instant. These run on a mailbox far bigger than any test fixture, against
/// a real file (as the app uses), and fail if a user-facing operation exceeds its budget.
///
/// The budget is 100 ms end to end, so each database step here gets a fraction of it. `scripts/test.sh` runs this
/// suite on its own, in a release build, which is what people actually run.
@Suite("Performance", .serialized)
struct PerformanceTests {
    static let messages = 10_000
    static let threads = 4_000

    /// Shared CI machines (GitHub's macOS runners) run this workload 2-3x slower than a recent Mac, and the same
    /// commit varies by about 30% from one runner to the next. The budgets are about people's Macs, so CI gets a 3x
    /// allowance: still tight enough to catch a regression like the multi-second tab switch these tests were
    /// written for. Locally the budgets apply as written.
    static let machineAllowance: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3
    static let budget: Duration = .milliseconds(25 * machineAllowance)

    /// Built once for the suite: a store with two accounts, tags, and a realistic mix of read/unread/archived mail.
    static let fixture: (repo: MailRepository, url: URL) = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-perf-\(UUID().uuidString).sqlite")
        // Encrypted, like the app's store, so the budgets include SQLCipher's cost.
        let repo = try! MailStore.open(path: url.path, secrets: MemorySecretStore()).repository
        try! repo.addAccount(email: "me@example.com", name: "Me")
        try! repo.addAccount(email: "work@example.com", name: "Work")

        let body = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40)
        let html = "<div>" + String(repeating: "<p>\(body)</p>", count: 4) + "</div>"
        var batch: [MailMessage] = []
        for i in 0..<messages {
            var labels: Set<String> = i % 3 == 0 ? [] : [SystemLabel.inbox]
            if i % 17 == 0 { labels.insert(SystemLabel.unread) }
            if i % 29 == 0 { labels.insert(SystemLabel.starred) }
            batch.append(MailMessage(
                id: "m\(i)", account: i % 2 == 0 ? "me@example.com" : "work@example.com", threadId: "t\(i % threads)",
                fromName: "Sender \(i % 300)", fromEmail: "sender\(i % 300)@example.com", to: "me@example.com",
                subject: "Subject \(i % 900) invoice report", snippet: "Snippet \(i)", bodyHTML: html, bodyText: body,
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60), labels: labels
            ))
            if batch.count == 500 {
                try! repo.upsert(batch)
                batch.removeAll()
            }
        }
        let tags = ["Needs Reply", "Newsletter", "Receipt", "Finance"]
        for i in stride(from: 0, to: messages, by: 3) {
            try! repo.setAutoTags([tags[i % tags.count]], account: i % 2 == 0 ? "me@example.com" : "work@example.com", messageId: "m\(i)")
        }
        return (repo, url)
    }()

    var repo: MailRepository { Self.fixture.repo }

    /// The median of several runs, so one hiccup on a busy machine doesn't fail the suite.
    func measure(_ body: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock()
        try body() // warm caches
        var samples: [Duration] = []
        for _ in 0..<5 { samples.append(try clock.measure { try body() }) }
        return samples.sorted()[samples.count / 2]
    }

    @Test func browsingAnyViewIsInstant() {
        let views: [(String, ThreadQuery)] = [
            ("inbox", ThreadQuery(limit: 100)),
            ("unread only", ThreadQuery(unreadOnly: true, limit: 100)),
            ("tag tab", ThreadQuery(split: .tag("Receipt"), limit: 100)),
            ("other tab", ThreadQuery(split: .other, limit: 100)),
            ("one account", ThreadQuery(account: "work@example.com", limit: 100)),
            ("all mail", ThreadQuery(mailbox: .all, limit: 100)),
            ("starred", ThreadQuery(mailbox: .starred, limit: 100)),
            ("third page", ThreadQuery(limit: 300)),
        ]
        for (name, query) in views {
            var count = 0
            let elapsed = measure { count = repo.threads(query).count }
            #expect(count > 0, "\(name) should have results")
            #expect(elapsed < Self.budget, "\(name) took \(elapsed)")
        }
    }

    @Test func tabCountsAreInstant() {
        #expect(measure { _ = repo.splitCounts(account: nil) } < Self.budget)
        #expect(measure { _ = repo.splitCounts(account: nil, unreadOnly: true) } < Self.budget)
        #expect(measure { _ = repo.unreadInboxCounts() } < Self.budget)
    }

    /// Search has to look at every match, so it gets its own, still well-inside-100 ms, budget.
    /// "invoice" is the worst case here: it appears in every one of the 10,000 messages.
    static let searchBudget: Duration = .milliseconds(60 * machineAllowance)

    @Test func searchIsInstant() {
        #expect(measure { _ = repo.threads(ThreadQuery(search: SearchQuery.parse("invoice"), limit: 100)) } < Self.searchBudget)
        #expect(measure { _ = repo.threads(ThreadQuery(search: SearchQuery.parse("report sender"), limit: 100)) } < Self.searchBudget)
        #expect(measure { _ = repo.threads(ThreadQuery(search: SearchQuery.parse("from:sender42"), limit: 100)) } < Self.searchBudget)
    }

    @Test func openingAThreadIsInstant() {
        let thread = repo.threads(ThreadQuery(limit: 1))[0]
        #expect(measure { _ = repo.threadMessages(account: thread.account, threadId: thread.threadId) } < Self.budget)
    }

    @Test func actionsAreInstant() throws {
        let thread = repo.threads(ThreadQuery(limit: 1))[0]
        let archive = try measure {
            let snapshots = try repo.modifyThread(account: thread.account, threadId: thread.threadId, add: [], remove: [SystemLabel.inbox])
            try repo.restore(snapshots)
        }
        // Two actions (archive, then undo), so twice the single-action budget.
        #expect(archive < Self.budget * 2, "archive + undo took \(archive)")
        let tag = try measure {
            try repo.toggleTag("Finance", account: thread.account, threadId: thread.threadId)
            try repo.toggleTag("Finance", account: thread.account, threadId: thread.threadId)
        }
        #expect(tag < Self.budget * 2, "tagging and untagging took \(tag)")
    }

    @Test func aSyncBatchHoldsTheWriteLockBriefly() throws {
        // Actions wait behind whatever sync batch is writing, so a batch must be well inside the budget.
        let template = repo.threadMessages(account: "me@example.com", threadId: "t0")[0]
        var round = 0
        let elapsed = try measure {
            round += 1
            let batch = (0..<20).map { i -> MailMessage in
                var message = template
                message.id = "perf-\(round)-\(i)"
                message.threadId = "perf-thread-\(i)"
                return message
            }
            try repo.upsert(batch)
        }
        #expect(elapsed < .milliseconds(50 * Self.machineAllowance), "20-message batch took \(elapsed)")
    }
}
