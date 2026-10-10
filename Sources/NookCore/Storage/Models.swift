import Foundation

/// A connected mail account. Nook identifies accounts by their email address.
public struct Account: Identifiable, Hashable, Sendable {
    public var id: String { email }
    public var email: String
    public var name: String
    /// Gmail history cursor. `nil` until the first full sync completes.
    public var historyId: String?
    public var colorIndex: Int
    public var lastSync: Date?

    public init(email: String, name: String, historyId: String? = nil, colorIndex: Int = 0, lastSync: Date? = nil) {
        self.email = email
        self.name = name
        self.historyId = historyId
        self.colorIndex = colorIndex
        self.lastSync = lastSync
    }
}

/// Gmail's built-in label ids.
public enum SystemLabel {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let starred = "STARRED"
    public static let sent = "SENT"
    public static let trash = "TRASH"
    public static let spam = "SPAM"
    public static let draft = "DRAFT"
}

public enum Mailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox, starred, sent, all, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .all: "All Mail"
        case .trash: "Trash"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .all: "archivebox"
        case .trash: "trash"
        }
    }

    /// The Gmail label a message must carry to appear here. `nil` means any non-trash message.
    public var gmailLabel: String? {
        switch self {
        case .inbox: SystemLabel.inbox
        case .starred: SystemLabel.starred
        case .sent: SystemLabel.sent
        case .trash: SystemLabel.trash
        case .all: nil
        }
    }
}

public struct MailMessage: Identifiable, Hashable, Sendable {
    public var id: String
    public var account: String
    public var threadId: String
    public var fromName: String
    public var fromEmail: String
    /// Raw `Reply-To` header, empty when absent.
    public var replyTo: String
    public var to: String
    public var cc: String
    public var subject: String
    public var snippet: String
    public var bodyHTML: String
    public var bodyText: String
    public var date: Date
    public var labels: Set<String>
    /// The RFC 5322 `Message-ID` header, used for threading replies.
    public var messageIdHeader: String
    public var references: String

    public var isUnread: Bool { labels.contains(SystemLabel.unread) }
    public var isStarred: Bool { labels.contains(SystemLabel.starred) }

    public init(
        id: String, account: String, threadId: String,
        fromName: String = "", fromEmail: String = "", replyTo: String = "",
        to: String = "", cc: String = "", subject: String = "", snippet: String = "",
        bodyHTML: String = "", bodyText: String = "", date: Date = Date(),
        labels: Set<String> = [], messageIdHeader: String = "", references: String = ""
    ) {
        self.id = id
        self.account = account
        self.threadId = threadId
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.subject = subject
        self.snippet = snippet
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.date = date
        self.labels = labels
        self.messageIdHeader = messageIdHeader
        self.references = references
    }
}

/// One row in the message list: a thread, represented by its most recent matching message.
public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public var id: String { "\(account)/\(threadId)" }
    public var account: String
    public var threadId: String
    public var latestMessageId: String
    public var fromName: String
    public var fromEmail: String
    public var subject: String
    public var snippet: String
    public var date: Date
    public var messageCount: Int
    public var isUnread: Bool
    public var isStarred: Bool
    public var tags: [String]

    public init(
        account: String, threadId: String, latestMessageId: String, fromName: String, fromEmail: String,
        subject: String, snippet: String, date: Date, messageCount: Int, isUnread: Bool, isStarred: Bool,
        tags: [String]
    ) {
        self.account = account
        self.threadId = threadId
        self.latestMessageId = latestMessageId
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.messageCount = messageCount
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.tags = tags
    }
}

/// A user-defined tag. The description is what the on-device model reads to decide whether it applies.
public struct Tag: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var colorIndex: Int
    /// Whether the tag gets its own tab in the split inbox. Conversations without any such tag land in "Other".
    public var isSplit: Bool

    public init(name: String, description: String, colorIndex: Int, isSplit: Bool = false) {
        self.name = name
        self.description = description
        self.colorIndex = colorIndex
        self.isSplit = isSplit
    }

    public static let defaults: [Tag] = [
        Tag(name: "Needs Reply", description: "A real person asks me a question or is waiting on my response.", colorIndex: 7, isSplit: true),
        Tag(name: "Newsletter", description: "Newsletters, digests, blogs, marketing and promotional email.", colorIndex: 5, isSplit: true),
        Tag(name: "Receipt", description: "Receipts, invoices, order confirmations, shipping and billing notices.", colorIndex: 4, isSplit: true),
        Tag(name: "Notification", description: "Automated notifications from apps and services: alerts, security codes, activity updates.", colorIndex: 6, isSplit: true),
        Tag(name: "Calendar", description: "Meeting invites, scheduling and calendar updates.", colorIndex: 1),
        Tag(name: "Travel", description: "Flights, hotels, bookings and itineraries.", colorIndex: 2),
        Tag(name: "Finance", description: "Banking, statements, payments, investments and taxes.", colorIndex: 8),
        Tag(name: "Personal", description: "Personal messages from friends and family.", colorIndex: 3),
    ]
}

/// An outgoing message being composed.
public struct Draft: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var from: String
    public var to: String
    public var cc: String
    public var subject: String
    public var body: String
    public var threadId: String?
    public var inReplyTo: String?
    public var references: String?

    public init(
        from: String, to: String = "", cc: String = "", subject: String = "", body: String = "",
        threadId: String? = nil, inReplyTo: String? = nil, references: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.threadId = threadId
        self.inReplyTo = inReplyTo
        self.references = references
    }
}
