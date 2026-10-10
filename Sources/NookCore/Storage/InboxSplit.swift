import Foundation

/// A tab of the split inbox: everything, one tag, or the conversations no tag claimed.
public enum InboxSplit: Hashable, Sendable {
    case everything
    case tag(String)
    case other

    public var title: String {
        switch self {
        case .everything: "Everything"
        case .tag(let name): name
        case .other: "Other"
        }
    }

    /// The tabs worth showing: always Everything, then each tab-enabled tag with conversations (in the user's order),
    /// then Other when some conversations aren't in any tab. The selected split stays visible even when empty,
    /// so the tab you're on never disappears under you.
    public static func visible(tags: [Tag], counts: SplitCounts, selected: InboxSplit? = nil) -> [InboxSplit] {
        var splits: [InboxSplit] = [.everything]
        for tag in tags where (tag.isSplit && (counts.tags[tag.name] ?? 0) > 0) || selected == .tag(tag.name) {
            splits.append(.tag(tag.name))
        }
        if counts.other > 0 && counts.other < counts.total || selected == .other {
            splits.append(.other)
        }
        return splits
    }
}

/// Conversation counts for each split of one mailbox.
public struct SplitCounts: Equatable, Sendable {
    public var total: Int
    public var tags: [String: Int]
    public var other: Int

    public init(total: Int = 0, tags: [String: Int] = [:], other: Int = 0) {
        self.total = total
        self.tags = tags
        self.other = other
    }

    public func count(for split: InboxSplit) -> Int {
        switch split {
        case .everything: total
        case .tag(let name): tags[name] ?? 0
        case .other: other
        }
    }
}
