import Foundation
import Testing
@testable import NookCore

@Suite("Rules")
struct RuleTests {
    let account = "me@example.com"
    /// Before the fixtures' dates, so rules act on them as new mail.
    let longAgo = Date(timeIntervalSince1970: 1_600_000_000)

    func stripeRenewals() -> MailRule {
        MailRule(
            name: "Stripe renewals",
            conditions: [
                RuleCondition(field: .from, value: "notifications@stripe.com"),
                RuleCondition(field: .text, value: "Subscription update"),
            ],
            actions: RuleActions(skipInbox: true, markRead: true, tag: "Receipt"),
            createdAt: longAgo
        )
    }

    // MARK: Matching

    @Test func everyConditionMustMatchIgnoringCase() {
        let rule = stripeRenewals()
        let renewal = MailMessage.fixture(id: "1", from: "NOTIFICATIONS@stripe.com", body: "subscription UPDATE - pi_123")
        let newCustomer = MailMessage.fixture(id: "2", from: "notifications@stripe.com", body: "Subscription creation - pi_456")
        let lookalike = MailMessage.fixture(id: "3", from: "anna@example.com", body: "Subscription update")
        #expect(rule.matches(renewal))
        #expect(!rule.matches(newCustomer))
        #expect(!rule.matches(lookalike))
    }

    @Test func fromMatchesTheNameAndToMatchesCc() {
        let byName = MailRule(conditions: [RuleCondition(field: .from, value: "stripe")], actions: RuleActions(markRead: true))
        #expect(byName.matches(.fixture(id: "1", from: "billing@example.com", fromName: "Stripe Billing")))
        let toTeam = MailRule(conditions: [RuleCondition(field: .to, value: "team@acme.com")], actions: RuleActions(markRead: true))
        #expect(toTeam.matches(.fixture(id: "2", to: "me@example.com", cc: "Team <team@acme.com>")))
    }

    @Test func aRuleWithNothingToMatchOrNothingToDoNeverMatches() {
        let anything = MailMessage.fixture(id: "1")
        #expect(!MailRule(conditions: [], actions: RuleActions(skipInbox: true)).matches(anything))
        #expect(!MailRule(conditions: [RuleCondition(field: .from, value: "  ")], actions: RuleActions(skipInbox: true)).matches(anything))
        #expect(!MailRule(conditions: [RuleCondition(field: .from, value: "anna")], actions: RuleActions()).matches(anything))
    }

    @Test func sentMailAndTrashNeverMatch() {
        let rule = MailRule(conditions: [RuleCondition(field: .subject, value: "Hello")], actions: RuleActions(skipInbox: true))
        #expect(!rule.matches(.fixture(id: "1", labels: [SystemLabel.sent, SystemLabel.inbox])))
        #expect(!rule.matches(.fixture(id: "2", labels: [SystemLabel.trash])))
        #expect(rule.matches(.fixture(id: "3")))
    }

    @Test func outcomesOnlyIncludeRealChanges() {
        let rule = MailRule(
            conditions: [RuleCondition(field: .subject, value: "Hello")],
            actions: RuleActions(skipInbox: true, markRead: true, star: true), createdAt: longAgo
        )
        let alreadyArchivedAndRead = MailMessage.fixture(id: "1", labels: [SystemLabel.starred])
        #expect(RuleOutcome.evaluate(alreadyArchivedAndRead, rules: [rule], onlyArrivedAfterCreation: true).isEmpty)

        let fresh = MailMessage.fixture(id: "2", labels: [SystemLabel.inbox, SystemLabel.unread])
        let outcome = RuleOutcome.evaluate(fresh, rules: [rule], onlyArrivedAfterCreation: true)
        #expect(outcome.removeLabels == [SystemLabel.inbox, SystemLabel.unread])
        #expect(outcome.addLabels == [SystemLabel.starred])
        #expect(outcome.labels(for: fresh) == [SystemLabel.starred])
    }

    @Test func newRulesLeaveOlderMailAloneUntilYouApplyThem() {
        var rule = stripeRenewals()
        rule.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let older = MailMessage.fixture(id: "1", from: "notifications@stripe.com", body: "Subscription update")
        #expect(RuleOutcome.evaluate(older, rules: [rule], onlyArrivedAfterCreation: true).isEmpty)
        #expect(!RuleOutcome.evaluate(older, rules: [rule], onlyArrivedAfterCreation: false).isEmpty)
    }

    @Test func disabledRulesDoNothing() {
        var rule = stripeRenewals()
        rule.isEnabled = false
        let renewal = MailMessage.fixture(id: "1", from: "notifications@stripe.com", body: "Subscription update")
        #expect(RuleOutcome.evaluate(renewal, rules: [rule], onlyArrivedAfterCreation: false).isEmpty)
    }

    // MARK: Storage

    @Test func rulesAreSavedInOrderAndCanBeEditedAndDeleted() throws {
        let repo = try makeRepository()
        var first = stripeRenewals()
        let second = MailRule(name: "Newsletters", conditions: [RuleCondition(field: .from, value: "substack")], actions: RuleActions(skipInbox: true))
        try repo.saveRule(first)
        try repo.saveRule(second)
        first.name = "Renewals"
        try repo.saveRule(first)
        #expect(repo.rules().map(\.name) == ["Renewals", "Newsletters"])
        try repo.deleteRule(id: first.id)
        #expect(repo.rules().map(\.id) == [second.id])
    }

    @Test func renamingATagUpdatesRulesAndRemovingItStopsThem() throws {
        let repo = try makeRepository()
        try repo.saveRule(stripeRenewals())
        var tags = repo.tags()
        let index = try #require(tags.firstIndex { $0.name == "Receipt" })
        tags[index].name = "Payments"
        try repo.saveTags(tags, renames: ["Receipt": "Payments"])
        #expect(repo.rules().first?.actions.tag == "Payments")

        try repo.saveTags(tags.filter { $0.name != "Payments" })
        #expect(repo.rules().first?.actions.tag == nil)
    }

    // MARK: Sync

    func syncedEngine(_ messages: [GmailMessage], rules: [MailRule]) async throws -> (MailRepository, FakeGmail, SyncEngine) {
        let repo = try makeRepository()
        try repo.addAccount(email: account, name: "Me")
        for rule in rules { try repo.saveRule(rule) }
        let gmail = FakeGmail(messages: messages)
        let engine = SyncEngine(repo: repo, makeService: { _ in gmail })
        try await engine.sync(account)
        return (repo, gmail, engine)
    }

    @Test func newMailIsFiledBeforeItReachesTheInbox() async throws {
        let (repo, gmail, engine) = try await syncedEngine([], rules: [stripeRenewals()])
        await gmail.add(gmailMessage(
            id: "renewal", labels: [SystemLabel.inbox, SystemLabel.unread],
            from: "Stripe <notifications@stripe.com>", body: "Subscription update - pi_1"
        ), historyId: "101")
        await gmail.add(gmailMessage(
            id: "customer", labels: [SystemLabel.inbox, SystemLabel.unread],
            from: "Stripe <notifications@stripe.com>", body: "Subscription creation - pi_2"
        ), historyId: "102")
        try await engine.sync(account)

        let renewal = try #require(repo.message(account: account, id: "renewal"))
        #expect(renewal.labels.isEmpty)
        #expect(repo.tags(account: account, messageId: "renewal") == ["Receipt"])
        // The model leaves rule-tagged mail alone.
        #expect(!repo.untaggedMessages(limit: 10).contains { $0.id == "renewal" })

        let customer = try #require(repo.message(account: account, id: "customer"))
        #expect(customer.labels == [SystemLabel.inbox, SystemLabel.unread])

        // Gmail got the change too, in one request.
        let modified = await gmail.modifiedMessages
        #expect(modified.count == 1)
        #expect(modified.first?.ids == ["renewal"])
        #expect(Set(modified.first?.remove ?? []) == [SystemLabel.inbox, SystemLabel.unread])
    }

    @Test func ifGmailRefusesTheChangeTheMailArrivesAsItWas() async throws {
        let (repo, gmail, engine) = try await syncedEngine([], rules: [stripeRenewals()])
        await gmail.failModifications(true)
        await gmail.add(gmailMessage(
            id: "renewal", labels: [SystemLabel.inbox], from: "notifications@stripe.com", body: "Subscription update"
        ), historyId: "101")
        try await engine.sync(account)
        #expect(repo.message(account: account, id: "renewal")?.labels == [SystemLabel.inbox])
    }

    @Test func ruleTagsSurviveRetagging() async throws {
        let (repo, gmail, engine) = try await syncedEngine([], rules: [stripeRenewals()])
        await gmail.add(gmailMessage(id: "r", from: "notifications@stripe.com", body: "Subscription update"), historyId: "101")
        try await engine.sync(account)
        try repo.resetAutoTags()
        #expect(repo.tags(account: account, messageId: "r") == ["Receipt"])
    }

    @Test func applyingARuleTidiesMailYouAlreadyHave() async throws {
        let renewals = (1...3).map {
            gmailMessage(id: "r\($0)", labels: [SystemLabel.inbox, SystemLabel.unread], from: "notifications@stripe.com", body: "Subscription update")
        }
        let other = gmailMessage(id: "o", labels: [SystemLabel.inbox], from: "anna@example.com", body: "Lunch?")
        var rule = stripeRenewals()
        rule.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let (repo, gmail, engine) = try await syncedEngine(renewals + [other], rules: [rule])
        // Mail from before the rule wasn't touched by the sync.
        #expect(repo.message(account: account, id: "r1")?.labels.contains(SystemLabel.inbox) == true)

        let changed = try await engine.apply(rule)
        #expect(changed == 3)
        for id in ["r1", "r2", "r3"] {
            #expect(repo.message(account: account, id: id)?.labels.isEmpty == true)
            #expect(repo.tags(account: account, messageId: id) == ["Receipt"])
        }
        #expect(repo.message(account: account, id: "o")?.labels == [SystemLabel.inbox])
        #expect(await gmail.modifiedMessages.count == 1)
    }
}
