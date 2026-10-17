import Foundation

/// Orders command palette matches by what you've picked before. With nothing typed the list stays in its fixed order;
/// once you type, the command you usually choose for those letters comes first. Typing "t" and picking Move to Trash
/// a couple of times puts Trash above Tag… for "t".
public struct PaletteRanking: Codable, Equatable, Sendable {
    public static let defaultsKey = "palette.picks"
    /// Queries longer than this are specific enough already, and the history stays small.
    static let maxQueryLength = 12
    static let maxQueries = 300

    /// How often each command was picked after typing a query, by query and then command title.
    var picks: [String: [String: Int]] = [:]

    public init() {}

    /// The titles that match the query, best first. Empty query: all titles, in their given order.
    public func rank(_ titles: [String], query: String) -> [String] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return titles }
        let chosen = picks[needle] ?? [:]
        return titles.enumerated()
            .compactMap { index, title -> (title: String, picked: Int, tier: Int, index: Int)? in
                guard let tier = Self.matchTier(title.lowercased(), needle) else { return nil }
                return (title, chosen[title] ?? 0, tier, index)
            }
            .sorted { a, b in
                if a.picked != b.picked { return a.picked > b.picked }
                if a.tier != b.tier { return a.tier < b.tier }
                return a.index < b.index
            }
            .map(\.title)
    }

    /// Remembers the pick for the query and each shorter start of it, so "t" learns from "tr" too.
    public mutating func record(query: String, title: String) {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return }
        for length in 1...min(needle.count, Self.maxQueryLength) {
            picks[String(needle.prefix(length)), default: [:]][title, default: 0] += 1
        }
        if picks.count > Self.maxQueries {
            // Forget the queries used least.
            let keep = picks.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }.prefix(Self.maxQueries)
            picks = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Lower is better: prefix match, then word-start match, then substring, then in-order characters.
    static func matchTier(_ title: String, _ needle: String) -> Int? {
        if title.hasPrefix(needle) { return 0 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if title.contains(needle) { return 2 }
        var remaining = Substring(needle)
        for character in title where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 3 }
        }
        return nil
    }

    public static func load(_ defaults: UserDefaults = .standard) -> PaletteRanking {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(PaletteRanking.self, from: $0) } ?? PaletteRanking()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
