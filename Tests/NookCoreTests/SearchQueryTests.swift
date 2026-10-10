import Testing
@testable import NookCore

@Suite("SearchQuery")
struct SearchQueryTests {
    @Test func blankInputIsNil() {
        #expect(SearchQuery.parse("") == nil)
        #expect(SearchQuery.parse("   ") == nil)
    }

    @Test func parsesOperatorsAndFreeText() throws {
        let query = try #require(SearchQuery.parse("from:anna to:ben tag:Receipt is:unread is:starred in:sent account:work invoice 2024"))
        #expect(query.from == ["anna"])
        #expect(query.to == ["ben"])
        #expect(query.tags == ["Receipt"])
        #expect(query.isUnread == true)
        #expect(query.isStarred == true)
        #expect(query.mailbox == .sent)
        #expect(query.accounts == ["work"])
        #expect(query.terms == ["invoice", "2024"])
    }

    @Test func keepsQuotedPhrasesTogether() throws {
        let query = try #require(SearchQuery.parse("from:\"Jane Doe\" \"board meeting\""))
        #expect(query.from == ["Jane Doe"])
        #expect(query.terms == ["board meeting"])
    }

    @Test func unknownOperatorsAreTreatedAsText() throws {
        let query = try #require(SearchQuery.parse("https://example.com subject:hi is:weird in:nowhere"))
        #expect(query.terms == ["https://example.com", "subject:hi", "is:weird", "in:nowhere"])
    }

    @Test func mailboxAliases() {
        #expect(SearchQuery.parse("in:anywhere")?.mailbox == .all)
        #expect(SearchQuery.parse("in:inbox")?.mailbox == .inbox)
        #expect(SearchQuery.parse("in:Trash")?.mailbox == .trash)
        #expect(SearchQuery.parse("is:read")?.isUnread == false)
    }

    @Test func ftsExpressionQuotesEachTermAsAPrefix() {
        #expect(SearchQuery.parse("invoice acme")?.ftsExpression == "\"invoice\"* \"acme\"*")
        #expect(SearchQuery.parse("from:anna")?.ftsExpression == nil)
        #expect(SearchQuery.parse("say \"hi\"")?.ftsExpression == "\"say\"* \"hi\"*")
    }

    @Test func searchingOverridesTheSelectedMailbox() {
        #expect(ThreadQuery(mailbox: .inbox).effectiveMailbox == .inbox)
        #expect(ThreadQuery(mailbox: .inbox, search: SearchQuery.parse("x")).effectiveMailbox == .all)
        #expect(ThreadQuery(mailbox: .inbox, search: SearchQuery.parse("x in:trash")).effectiveMailbox == .trash)
    }
}

@Suite("InboxSplit")
struct InboxSplitTests {
    let tags = [
        Tag(name: "Needs Reply", description: "", colorIndex: 0, isSplit: true),
        Tag(name: "Receipt", description: "", colorIndex: 1, isSplit: true),
        Tag(name: "Travel", description: "", colorIndex: 2, isSplit: true),
        Tag(name: "Finance", description: "", colorIndex: 3, isSplit: false),
    ]

    @Test func showsTagsWithMailInTagOrderThenOther() {
        let counts = SplitCounts(total: 9, tags: ["Travel": 1, "Needs Reply": 3], other: 4)
        #expect(InboxSplit.visible(tags: tags, counts: counts) == [.everything, .tag("Needs Reply"), .tag("Travel"), .other])
    }

    @Test func onlyTabEnabledTagsBecomeTabs() {
        let counts = SplitCounts(total: 3, tags: ["Finance": 2, "Receipt": 1], other: 2)
        #expect(InboxSplit.visible(tags: tags, counts: counts) == [.everything, .tag("Receipt"), .other])
        // Picking a non-tab tag from the sidebar still shows it while selected.
        #expect(InboxSplit.visible(tags: tags, counts: counts, selected: .tag("Finance")) == [.everything, .tag("Receipt"), .tag("Finance"), .other])
    }

    @Test func hidesOtherWhenItWouldDuplicateEverything() {
        #expect(InboxSplit.visible(tags: tags, counts: SplitCounts(total: 4, other: 4)) == [.everything])
        #expect(InboxSplit.visible(tags: tags, counts: SplitCounts(total: 2, tags: ["Receipt": 2])) == [.everything, .tag("Receipt")])
    }

    @Test func keepsTheSelectedSplitEvenWhenEmpty() {
        let empty = SplitCounts()
        #expect(InboxSplit.visible(tags: tags, counts: empty, selected: .tag("Receipt")) == [.everything, .tag("Receipt")])
        #expect(InboxSplit.visible(tags: tags, counts: empty, selected: .other) == [.everything, .other])
    }

    @Test func countsPerSplit() {
        let counts = SplitCounts(total: 5, tags: ["Receipt": 2], other: 1)
        #expect(counts.count(for: .everything) == 5)
        #expect(counts.count(for: .tag("Receipt")) == 2)
        #expect(counts.count(for: .tag("Travel")) == 0)
        #expect(counts.count(for: .other) == 1)
        #expect(InboxSplit.tag("Receipt").title == "Receipt")
    }
}
