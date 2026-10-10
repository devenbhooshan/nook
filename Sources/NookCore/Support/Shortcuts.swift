import Foundation

/// Everything the keyboard can do in the mail view.
public enum KeyCommand: Equatable, Sendable {
    case next, previous, open, close
    case archive, trash, toggleStar, toggleRead
    case reply, replyAll, forward, compose
    case search, commandPalette, tagPicker, help, undo
    case nextSplit, previousSplit
    case toggleUnreadFilter
    case go(Mailbox)

    /// Whether holding the key down should repeat the command. Only movement does: a held "e" or Delete must
    /// not archive or trash a dozen conversations a second.
    public var repeatsWhenHeld: Bool {
        self == .next || self == .previous
    }
}

/// Turns single key presses into commands. Superhuman-style: one key per action, and `g` starts
/// a two-key "go to" sequence (`g i` inbox, `g s` starred, `g t` sent, `g a` all mail, `g #` trash).
public struct ShortcutInterpreter: Sendable {
    public enum KeyCode {
        public static let returnKey: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let escape: UInt16 = 53
        public static let delete: UInt16 = 51
        public static let forwardDelete: UInt16 = 117
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126
        public static let tab: UInt16 = 48
    }

    /// How long after `g` the second key still counts.
    public var sequenceTimeout: TimeInterval = 1.5
    private var pendingGoSince: Date?

    public init() {}

    public var isAwaitingSequence: Bool { pendingGoSince != nil }

    /// The characters a key press should be matched on, or nil if it isn't a shortcut.
    ///
    /// Uses the characters without modifiers (so Caps Lock doesn't turn "u" into "U", which means something else),
    /// except where a layout needs Option to type a shortcut character: "#" is Option-3 on a UK keyboard.
    public static func shortcutCharacters(characters: String?, ignoringModifiers: String?, option: Bool) -> String? {
        if option { return characters == "#" ? "#" : nil }
        return ignoringModifiers ?? characters
    }

    /// - Parameters:
    ///   - characters: The typed characters, ignoring modifiers except Shift (so Shift-3 is "#").
    ///   - keyCode: The hardware key code, for keys without characters.
    ///   - shift: Whether Shift is held, for keys like Tab whose characters don't show it.
    /// - Returns: The command, or `nil` if the key isn't a shortcut (or only started a sequence).
    public mutating func interpret(characters: String, keyCode: UInt16, shift: Bool = false, now: Date = Date()) -> KeyCommand? {
        if let started = pendingGoSince {
            pendingGoSince = nil
            if now.timeIntervalSince(started) <= sequenceTimeout {
                switch characters {
                case "i": return .go(.inbox)
                case "s": return .go(.starred)
                case "t": return .go(.sent)
                case "a", "e": return .go(.all)
                case "#": return .go(.trash)
                default: break
                }
            }
        }

        switch keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter: return .open
        case KeyCode.escape: return .close
        case KeyCode.downArrow: return .next
        case KeyCode.upArrow: return .previous
        case KeyCode.delete, KeyCode.forwardDelete: return .trash
        case KeyCode.tab: return shift ? .previousSplit : .nextSplit
        default: break
        }

        switch characters {
        case "j": return .next
        case "k": return .previous
        case "o": return .open
        case "e", "y": return .archive
        case "#": return .trash
        case "s": return .toggleStar
        case "u": return .toggleRead
        case "U": return .toggleUnreadFilter
        case "r": return .reply
        case "a": return .replyAll
        case "f": return .forward
        case "c": return .compose
        case "/": return .search
        case "l": return .tagPicker
        case "?": return .help
        case "z": return .undo
        case "g":
            pendingGoSince = now
            return nil
        default:
            return nil
        }
    }

    public struct Entry: Identifiable, Sendable {
        public var id: String { keys + title }
        public let keys: String
        public let title: String
    }

    public struct Section: Identifiable, Sendable {
        public var id: String { title }
        public let title: String
        public let entries: [Entry]
    }

    /// Shown in the help overlay and the README.
    public static let reference: [Section] = [
        Section(title: "Navigate", entries: [
            Entry(keys: "j / k", title: "Next / previous conversation"),
            Entry(keys: "↵", title: "Open conversation"),
            Entry(keys: "esc", title: "Back to list"),
            Entry(keys: "tab", title: "Next split (⇧ for previous)"),
            Entry(keys: "⇧U", title: "Show only unread"),
            Entry(keys: "/", title: "Search"),
            Entry(keys: "⌘K", title: "Command palette"),
            Entry(keys: "⌘0 – ⌘9", title: "All accounts / switch account"),
            Entry(keys: "⌘\\", title: "Show or hide sidebar"),
        ]),
        Section(title: "Act", entries: [
            Entry(keys: "e", title: "Mark done (archive)"),
            Entry(keys: "#", title: "Trash"),
            Entry(keys: "s", title: "Star"),
            Entry(keys: "u", title: "Toggle read"),
            Entry(keys: "l", title: "Tag"),
            Entry(keys: "z", title: "Undo"),
        ]),
        Section(title: "Write", entries: [
            Entry(keys: "c", title: "Compose"),
            Entry(keys: "r", title: "Reply"),
            Entry(keys: "a", title: "Reply all"),
            Entry(keys: "f", title: "Forward"),
            Entry(keys: "⌘↵", title: "Send"),
        ]),
        Section(title: "Go to", entries: [
            Entry(keys: "g i", title: "Inbox"),
            Entry(keys: "g s", title: "Starred"),
            Entry(keys: "g t", title: "Sent"),
            Entry(keys: "g a", title: "All mail"),
            Entry(keys: "g #", title: "Trash"),
        ]),
    ]
}
