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
    case inbox, starred, sent, drafts, all, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .all: "All Mail"
        case .trash: "Trash"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc.text"
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
        case .drafts: SystemLabel.draft
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
    /// Files sent with the message, including images shown inside an HTML body.
    public var attachments: [Attachment]

    /// The attachments to list under the message. Images the body already shows aren't listed again.
    public var listedAttachments: [Attachment] { attachments.filter { !$0.isInline } }

    public var isUnread: Bool { labels.contains(SystemLabel.unread) }
    public var isStarred: Bool { labels.contains(SystemLabel.starred) }

    public init(
        id: String, account: String, threadId: String,
        fromName: String = "", fromEmail: String = "", replyTo: String = "",
        to: String = "", cc: String = "", subject: String = "", snippet: String = "",
        bodyHTML: String = "", bodyText: String = "", date: Date = Date(),
        labels: Set<String> = [], messageIdHeader: String = "", references: String = "",
        attachments: [Attachment] = []
    ) {
        self.attachments = attachments
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
    public var hasAttachments: Bool

    public init(
        account: String, threadId: String, latestMessageId: String, fromName: String, fromEmail: String,
        subject: String, snippet: String, date: Date, messageCount: Int, isUnread: Bool, isStarred: Bool,
        tags: [String], hasAttachments: Bool = false
    ) {
        self.hasAttachments = hasAttachments
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
    /// The Gmail draft this was opened from, by its message id. Sending sends that draft; saving updates it.
    public var gmailDraftMessageId: String?
    public var attachments: [OutgoingAttachment]
    /// The message being replied to or forwarded. Kept out of the editor and added below what you write when sending.
    public var quoted: String = ""

    /// What's sent: your text, then the quoted message.
    public var fullBody: String {
        guard !quoted.isEmpty else { return body }
        let mine = body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return mine.isEmpty ? quoted : mine + "\n\n" + quoted
    }

    public init(
        from: String, to: String = "", cc: String = "", subject: String = "", body: String = "",
        threadId: String? = nil, inReplyTo: String? = nil, references: String? = nil, gmailDraftMessageId: String? = nil,
        attachments: [OutgoingAttachment] = []
    ) {
        self.attachments = attachments
        self.gmailDraftMessageId = gmailDraftMessageId
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

/// A file that came with a message. The bytes stay in Gmail until you open or save it.
public struct Attachment: Identifiable, Hashable, Sendable, Codable {
    public var id: String { partId }
    /// Where the file sits in the message's MIME tree, like "1.2". Unique within a message.
    public var partId: String
    public var filename: String
    public var mimeType: String
    /// Size in bytes, as Gmail reports it.
    public var size: Int
    /// Gmail's handle for fetching the bytes. Small parts have none; their bytes come with the message.
    public var attachmentId: String?
    /// The `Content-ID` an HTML body uses to show the file inline, without angle brackets.
    public var contentId: String?
    /// Shown inside the body (a pasted screenshot, a logo in a signature) rather than as a file to open.
    public var isInline: Bool

    public init(
        partId: String, filename: String, mimeType: String, size: Int,
        attachmentId: String? = nil, contentId: String? = nil, isInline: Bool = false
    ) {
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.attachmentId = attachmentId
        self.contentId = contentId
        self.isInline = isInline
    }

    public var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

/// A file going out with a draft.
public struct OutgoingAttachment: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// Bytes already on this Mac: a file you picked or dropped.
        case data(Data)
        /// A file still in Gmail, from the message being forwarded or the draft being finished. Fetched when sending.
        case gmail(account: String, messageId: String, attachment: Attachment)
    }

    public var id = UUID()
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var source: Source

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = data.count
        self.source = .data(data)
    }

    public init(forwarding attachment: Attachment, account: String, messageId: String) {
        self.filename = attachment.filename
        self.mimeType = attachment.mimeType
        self.size = attachment.size
        self.source = .gmail(account: account, messageId: messageId, attachment: attachment)
    }

    public var data: Data? {
        if case .data(let data) = source { return data }
        return nil
    }

    /// Gmail refuses messages whose attachments add up to more than 25 MB.
    public static let gmailLimit = 25 * 1024 * 1024
}
