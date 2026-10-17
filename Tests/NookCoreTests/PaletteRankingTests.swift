import Foundation
import Testing
@testable import NookCore

@Suite("Command palette ranking")
struct PaletteRankingTests {
    let titles = ["Mark done", "Reply", "Reply all", "Star", "Tag…", "Move to Trash", "New message"]

    @Test func emptyQueryKeepsTheFixedOrder() {
        var ranking = PaletteRanking()
        ranking.record(query: "t", title: "Move to Trash")
        #expect(ranking.rank(titles, query: "") == titles)
    }

    @Test func withoutHistoryTheClosestMatchWins() {
        #expect(PaletteRanking().rank(titles, query: "t") == ["Tag…", "Move to Trash", "Star"])
        #expect(PaletteRanking().rank(titles, query: "zz").isEmpty)
    }

    @Test func whatYouPickForTheLettersComesFirst() {
        var ranking = PaletteRanking()
        ranking.record(query: "tr", title: "Move to Trash")
        // Learned from "tr" for "t" as well.
        #expect(ranking.rank(titles, query: "t").first == "Move to Trash")
        #expect(ranking.rank(titles, query: "TR ").first == "Move to Trash")
        ranking.record(query: "t", title: "Tag…")
        ranking.record(query: "t", title: "Tag…")
        #expect(ranking.rank(titles, query: "t").first == "Tag…")
        // Picks never bring in commands that don't match.
        #expect(!ranking.rank(titles, query: "rep").contains("Move to Trash"))
    }

    @Test func historySurvivesARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "palette-\(UUID())"))
        var ranking = PaletteRanking()
        ranking.record(query: "s", title: "Star")
        ranking.save(defaults)
        #expect(PaletteRanking.load(defaults) == ranking)
    }
}
