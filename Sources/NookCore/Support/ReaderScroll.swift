import Foundation

/// Keyboard scrolling in an open conversation: the arrow keys move a few lines, Space and Page Up/Down move a page,
/// Home and End jump to the ends. `j` and `k` still move between conversations.
public enum ReaderScroll: Equatable, Sendable {
    case by(Double)
    case toTop
    case toBottom

    public enum KeyCode {
        public static let space: UInt16 = 49
        public static let pageUp: UInt16 = 116
        public static let pageDown: UInt16 = 121
        public static let home: UInt16 = 115
        public static let end: UInt16 = 119
    }

    /// How far one arrow press moves.
    public static let lineHeight: Double = 48

    /// - Parameter viewportHeight: The visible height of the conversation, so a page leaves a little overlap.
    /// - Returns: The scroll for this key, or nil if it doesn't scroll.
    public static func forKey(_ keyCode: UInt16, shift: Bool, viewportHeight: Double) -> ReaderScroll? {
        let page = max(viewportHeight - 2 * lineHeight, lineHeight)
        switch keyCode {
        case ShortcutInterpreter.KeyCode.downArrow: return .by(lineHeight)
        case ShortcutInterpreter.KeyCode.upArrow: return .by(-lineHeight)
        case KeyCode.space: return .by(shift ? -page : page)
        case KeyCode.pageDown: return .by(page)
        case KeyCode.pageUp: return .by(-page)
        case KeyCode.home: return .toTop
        case KeyCode.end: return .toBottom
        default: return nil
        }
    }

    /// The new distance from the top, kept within the content.
    public func offset(from current: Double, contentHeight: Double, viewportHeight: Double) -> Double {
        let maximum = max(contentHeight - viewportHeight, 0)
        switch self {
        case .by(let delta): return min(max(current + delta, 0), maximum)
        case .toTop: return 0
        case .toBottom: return maximum
        }
    }
}

/// Recognizes the "go back" swipe from horizontal scroll deltas, for when the system's own swipe tracking is off.
public struct BackSwipe: Sendable {
    /// How far (in points) the fingers must travel, mostly sideways, to count as a swipe.
    public var threshold: Double = 90
    private var horizontal: Double = 0
    private var vertical: Double = 0

    public init() {}

    public mutating func begin() {
        horizontal = 0
        vertical = 0
    }

    /// - Parameter deltaX: Positive when the content moves right, which is the "back" direction.
    /// - Returns: True once, when the gesture crosses the threshold going back.
    public mutating func add(deltaX: Double, deltaY: Double) -> Bool {
        let wasBelow = horizontal < threshold
        horizontal += deltaX
        vertical += abs(deltaY)
        return wasBelow && horizontal >= threshold && horizontal > 2 * vertical
    }
}
