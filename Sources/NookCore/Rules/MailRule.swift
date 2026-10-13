import Foundation

/// A rule you set up: when an email matches every condition, Nook does the actions as it arrives.
///
/// Rules are exact, so they handle predictable mail (receipts, notifications, newsletters) better than the
/// on-device model. They run first; mail a rule tags is left alone by the tagger.
public struct MailRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// All of these must match.
    public var conditions: [RuleCondition]
    public var actions: RuleActions
    /// Rules act on mail that arrives after they're created. Older mail only changes when you apply a rule to it.
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String = "", isEnabled: Bool = true, conditions: [RuleCondition] = [],
        actions: RuleActions = RuleActions(), createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.actions = actions
        self.createdAt = createdAt
    }

    /// A rule needs at least one condition with text, so an empty rule never matches everything.
    public var isValid: Bool {
        conditions.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty } && actions.doesSomething
    }

    /// Whether this email matches. Only mail you received counts: your own sent mail and trash never match.
    public func matches(_ message: MailMessage) -> Bool {
        guard isValid, !message.labels.contains(SystemLabel.sent), !message.labels.contains(SystemLabel.trash) else {
            return false
        }
        return conditions.allSatisfy { $0.matches(message) }
    }

    /// One line describing the rule, for lists.
    public var summary: String {
        let when = conditions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.field.title) contains “\($0.value.trimmingCharacters(in: .whitespaces))”" }
            .joined(separator: " and ")
        return "\(when) → \(actions.summary)"
    }
}

public struct RuleCondition: Codable, Hashable, Sendable, Identifiable {
    public enum Field: String, Codable, CaseIterable, Sendable, Identifiable {
        case from
        case to
        case subject
        /// The subject or the text of the email.
        case text

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .from: "From"
            case .to: "To"
            case .subject: "Subject"
            case .text: "Subject or body"
            }
        }
    }

    public var id: UUID
    public var field: Field
    /// Matched as a case-insensitive "contains".
    public var value: String

    public init(id: UUID = UUID(), field: Field, value: String) {
        self.id = id
        self.field = field
        self.value = value
    }

    public func matches(_ message: MailMessage) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        func has(_ haystack: String) -> Bool {
            haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        switch field {
        case .from: return has(message.fromEmail) || has(message.fromName)
        case .to: return has(message.to) || has(message.cc)
        case .subject: return has(message.subject)
        case .text: return has(message.subject) || has(message.bodyText) || has(message.snippet)
        }
    }
}

public struct RuleActions: Codable, Hashable, Sendable {
    /// Archive it: it stays in All Mail and search, but not the inbox.
    public var skipInbox: Bool
    public var markRead: Bool
    public var star: Bool
    /// A tag to add, by name.
    public var tag: String?

    public init(skipInbox: Bool = false, markRead: Bool = false, star: Bool = false, tag: String? = nil) {
        self.skipInbox = skipInbox
        self.markRead = markRead
        self.star = star
        self.tag = tag
    }

    public var doesSomething: Bool { skipInbox || markRead || star || !(tag ?? "").isEmpty }

    public var summary: String {
        var parts: [String] = []
        if skipInbox { parts.append("skip the inbox") }
        if markRead { parts.append("mark as read") }
        if star { parts.append("star") }
        if let tag, !tag.isEmpty { parts.append("tag “\(tag)”") }
        return parts.joined(separator: ", ")
    }
}

/// What the matching rules do to one email.
public struct RuleOutcome: Equatable, Sendable {
    public var addLabels: Set<String> = []
    public var removeLabels: Set<String> = []
    public var tags: [String] = []

    public init(addLabels: Set<String> = [], removeLabels: Set<String> = [], tags: [String] = []) {
        self.addLabels = addLabels
        self.removeLabels = removeLabels
        self.tags = tags
    }

    public var isEmpty: Bool { addLabels.isEmpty && removeLabels.isEmpty && tags.isEmpty }

    /// Applies every enabled rule that matches.
    /// - Parameter onlyArrivedAfterCreation: For new mail, a rule only acts on email dated after the rule was made.
    public static func evaluate(_ message: MailMessage, rules: [MailRule], onlyArrivedAfterCreation: Bool) -> RuleOutcome {
        var outcome = RuleOutcome()
        for rule in rules where rule.isEnabled && rule.matches(message) {
            if onlyArrivedAfterCreation, message.date < rule.createdAt { continue }
            outcome.add(rule.actions, to: message)
        }
        return outcome
    }

    /// The label changes, limited to ones that actually change this email.
    mutating func add(_ actions: RuleActions, to message: MailMessage) {
        if actions.skipInbox, message.labels.contains(SystemLabel.inbox) { removeLabels.insert(SystemLabel.inbox) }
        if actions.markRead, message.labels.contains(SystemLabel.unread) { removeLabels.insert(SystemLabel.unread) }
        if actions.star, !message.labels.contains(SystemLabel.starred) { addLabels.insert(SystemLabel.starred) }
        if let tag = actions.tag, !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
    }

    /// The email's labels after the rules.
    public func labels(for message: MailMessage) -> Set<String> {
        message.labels.subtracting(removeLabels).union(addLabels)
    }
}
