import Foundation
import Testing
@testable import NookCore

@Suite("Contact suggestions")
struct ContactBookTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func peopleYouWroteToOutrankPeopleWhoOnlyWroteToYou() {
        let book = ContactBook(history: ContactHistory(
            senders: [.init(name: "Jane Fan", email: "jane.fan@example.com", count: 6, lastDate: now)],
            sent: [.init(to: "Jane Doe <jane@acme.com>", cc: "", date: now)]
        ), now: now)
        #expect(book.suggestions(for: "jane").map(\.email) == ["jane@acme.com", "jane.fan@example.com"])
    }

    @Test func recentCorrespondentsOutrankOldOnes() {
        let book = ContactBook(history: ContactHistory(sent: [
            .init(to: "sam.old@example.com", cc: "", date: daysAgo(400)),
            .init(to: "sam.old@example.com", cc: "", date: daysAgo(380)),
            .init(to: "sam.new@example.com", cc: "", date: daysAgo(2)),
        ]), now: now)
        #expect(book.suggestions(for: "sam").map(\.email) == ["sam.new@example.com", "sam.old@example.com"])
    }

    @Test func matchesTheStartOfAnyWordInTheNameOrAddress() {
        let book = ContactBook(history: ContactHistory(sent: [
            .init(to: "\"Doe, Jane\" <jdoe@acme.com>", cc: "Priya Raman <priya_r@studio.io>", date: now),
        ]), now: now)
        #expect(book.suggestions(for: "doe").map(\.email) == ["jdoe@acme.com"])
        #expect(book.suggestions(for: "JANE").map(\.email) == ["jdoe@acme.com"])
        #expect(book.suggestions(for: "acme").map(\.email) == ["jdoe@acme.com"])
        #expect(book.suggestions(for: "jdoe@ac").map(\.email) == ["jdoe@acme.com"])
        #expect(book.suggestions(for: "raman pri").map(\.email) == ["priya_r@studio.io"])
        #expect(book.suggestions(for: "r").map(\.email).contains("priya_r@studio.io"))
        // Nor does the end of the domain, which nearly everyone shares.
        #expect(book.suggestions(for: "com").isEmpty)
        #expect(book.suggestions(for: "studio.io").map(\.email) == ["priya_r@studio.io"])
        // Middle of a word doesn't count.
        #expect(book.suggestions(for: "ane").isEmpty)
        #expect(book.suggestions(for: "  ").isEmpty)
    }

    @Test func leavesOutAutomatedSendersUnlessYouWroteToThem() {
        let book = ContactBook(history: ContactHistory(
            senders: [
                .init(name: "Stripe", email: "notifications@stripe.com", count: 300, lastDate: now),
                .init(name: "GitHub", email: "noreply@github.com", count: 80, lastDate: now),
                .init(name: "Support", email: "support-noreply@vendor.com", count: 3, lastDate: now),
                .init(name: "Stripe Support", email: "support@stripe.com", count: 2, lastDate: now),
            ],
            sent: [.init(to: "support-noreply@vendor.com", cc: "", date: now)]
        ), now: now)
        #expect(book.suggestions(for: "stripe").map(\.email) == ["support@stripe.com"])
        #expect(book.suggestions(for: "github").isEmpty)
        #expect(book.suggestions(for: "vendor").map(\.email) == ["support-noreply@vendor.com"])
    }

    @Test func neverSuggestsYourOwnAddressesOrJunk() {
        let book = ContactBook(
            history: ContactHistory(
                senders: [.init(name: "Me", email: "Me@Example.com", count: 50, lastDate: now)],
                sent: [.init(to: "undisclosed-recipients:;, not an address, a@b", cc: "", date: now)]
            ),
            own: ["me@example.com"], now: now
        )
        #expect(book.contacts.isEmpty)
    }

    @Test func mergesAddressesCaseInsensitivelyAndKeepsAName() {
        let book = ContactBook(history: ContactHistory(
            senders: [.init(name: "Anna Lee", email: "Anna@Example.com", count: 1, lastDate: now)],
            sent: [.init(to: "anna@example.com", cc: "", date: now)]
        ), now: now)
        #expect(book.contacts.count == 1)
        #expect(book.contacts.first?.name == "Anna Lee")
        #expect(book.contacts.first?.address.formatted == "Anna Lee <anna@example.com>")
    }

    @Test func addressBookNamesWinAndItsPeopleAreSuggested() {
        let book = ContactBook(
            history: ContactHistory(senders: [.init(name: "ANNA LEE (via Docs)", email: "anna@example.com", count: 1, lastDate: now)]),
            addressBook: [EmailAddress(name: "Anna Lee", email: "anna@example.com"), EmailAddress(name: "Mom", email: "mom@family.org")],
            now: now
        )
        #expect(book.suggestions(for: "anna").first?.name == "Anna Lee")
        #expect(book.suggestions(for: "mom").map(\.email) == ["mom@family.org"])
    }

    @Test func skipsRecipientsAlreadyInTheFieldAndStopsAtTheLimit() {
        let sent = (1...10).map { ContactHistory.Sent(to: "dev\($0)@team.dev", cc: "", date: now) }
        let book = ContactBook(history: ContactHistory(sent: sent), now: now)
        #expect(book.suggestions(for: "dev", limit: 4).count == 4)
        #expect(!book.suggestions(for: "dev", excluding: ["DEV1@team.dev"], limit: 20).map(\.email).contains("dev1@team.dev"))
    }

    @Test func findsTheAddressBeingTyped() {
        #expect(Addresses.splitTyping("") == ("", ""))
        #expect(Addresses.splitTyping("jan") == ("", "jan"))
        #expect(Addresses.splitTyping("a@x.com, jan") == ("a@x.com, ", "jan"))
        #expect(Addresses.splitTyping("a@x.com;b@y.com,") == ("a@x.com;b@y.com,", ""))
        #expect(Addresses.splitTyping("\"Doe, Jane\" <j@x.com>, Pri") == ("\"Doe, Jane\" <j@x.com>, ", "Pri"))
        #expect(Addresses.splitTyping("\"Doe, Ja") == ("", "\"Doe, Ja"))
    }

    @Test func completesTheAddressBeingTyped() {
        let jane = EmailAddress(name: "Jane Doe", email: "jane@acme.com")
        #expect(Addresses.complete("ja", with: jane) == "Jane Doe <jane@acme.com>, ")
        #expect(Addresses.complete("bo@x.com,ja", with: jane) == "bo@x.com, Jane Doe <jane@acme.com>, ")
        #expect(Addresses.complete("bo@x.com,  ja", with: jane) == "bo@x.com,  Jane Doe <jane@acme.com>, ")
        let bare = EmailAddress(name: "", email: "x@y.com")
        #expect(Addresses.parseList(Addresses.complete("bo@x.com, x", with: bare)).map(\.email) == ["bo@x.com", "x@y.com"])
    }

    @Test func readsHistoryFromTheStore() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        try repo.upsert([
            .fixture(id: "1", from: "anna@example.com", fromName: "Anna", minutesAgo: 60),
            .fixture(id: "2", from: "ANNA@example.com", fromName: "Anna Lee", minutesAgo: 1),
            .fixture(id: "3", from: "spam@bad.biz", labels: [SystemLabel.spam]),
            .fixture(id: "4", from: "me@example.com", fromName: "Me", labels: [SystemLabel.sent], to: "Bo <bo@example.com>", cc: "cy@example.com"),
        ])
        let history = repo.contactHistory()
        #expect(history.senders.count == 1)
        #expect(history.senders.first?.count == 2)
        #expect(history.senders.first?.name == "Anna Lee")
        #expect(history.sent == [ContactHistory.Sent(to: "Bo <bo@example.com>", cc: "cy@example.com", date: Date(timeIntervalSince1970: 1_700_000_000))])

        let book = ContactBook(history: history, own: ["me@example.com"], now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Set(book.contacts.map { $0.email.lowercased() }) == ["anna@example.com", "bo@example.com", "cy@example.com"])
    }

    @Test func suggestingFromAThousandsOfContactsIsInstant() {
        let sent = (0..<5_000).map { ContactHistory.Sent(to: "Person \($0) <person\($0)@company\($0 % 50).com>", cc: "", date: now) }
        let book = ContactBook(history: ContactHistory(sent: sent), now: now)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for query in ["p", "pe", "per", "person 49", "company7", "zzz"] { _ = book.suggestions(for: query) }
        }
        #expect(elapsed < .milliseconds(100))
    }
}
