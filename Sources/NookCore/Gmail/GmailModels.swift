import Foundation

// Wire types for the Gmail REST API (https://developers.google.com/gmail/api/reference/rest).

public struct GmailProfile: Decodable, Sendable, Equatable {
    public var emailAddress: String
    public var historyId: String

    public init(emailAddress: String, historyId: String) {
        self.emailAddress = emailAddress
        self.historyId = historyId
    }
}

public struct GmailMessage: Decodable, Sendable, Equatable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: String?
    /// Milliseconds since 1970, as a string.
    public var internalDate: String?
    public var payload: GmailMessagePart?

    public init(
        id: String, threadId: String? = nil, labelIds: [String]? = nil, snippet: String? = nil,
        historyId: String? = nil, internalDate: String? = nil, payload: GmailMessagePart? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.payload = payload
    }
}

public struct GmailMessagePart: Decodable, Sendable, Equatable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeader]?
    public var body: GmailBody?
    public var parts: [GmailMessagePart]?

    public init(
        partId: String? = nil, mimeType: String? = nil, filename: String? = nil,
        headers: [GmailHeader]? = nil, body: GmailBody? = nil, parts: [GmailMessagePart]? = nil
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }
}

public struct GmailHeader: Decodable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct GmailBody: Decodable, Sendable, Equatable {
    public var size: Int?
    /// base64url-encoded content.
    public var data: String?
    public var attachmentId: String?

    public init(size: Int? = nil, data: String? = nil, attachmentId: String? = nil) {
        self.size = size
        self.data = data
        self.attachmentId = attachmentId
    }
}

struct GmailMessageList: Decodable {
    struct Ref: Decodable { var id: String; var threadId: String? }
    var messages: [Ref]?
    var nextPageToken: String?
}

/// A message reference inside a history record. `labelIds` are the message's labels after the change.
public struct GmailMessageRef: Decodable, Sendable, Equatable {
    public var id: String
    public var threadId: String?
    public var labelIds: [String]?

    public init(id: String, threadId: String? = nil, labelIds: [String]? = nil) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
    }
}

public struct GmailHistoryRecord: Decodable, Sendable, Equatable {
    public struct MessageChange: Decodable, Sendable, Equatable {
        public var message: GmailMessageRef
        public init(message: GmailMessageRef) { self.message = message }
    }

    public struct LabelChange: Decodable, Sendable, Equatable {
        public var message: GmailMessageRef
        public var labelIds: [String]?
        public init(message: GmailMessageRef, labelIds: [String]? = nil) {
            self.message = message
            self.labelIds = labelIds
        }
    }

    public var id: String
    public var messagesAdded: [MessageChange]?
    public var messagesDeleted: [MessageChange]?
    public var labelsAdded: [LabelChange]?
    public var labelsRemoved: [LabelChange]?

    public init(
        id: String, messagesAdded: [MessageChange]? = nil, messagesDeleted: [MessageChange]? = nil,
        labelsAdded: [LabelChange]? = nil, labelsRemoved: [LabelChange]? = nil
    ) {
        self.id = id
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }
}

/// Every history record since a cursor, plus the new cursor.
public struct GmailHistory: Sendable, Equatable {
    public var records: [GmailHistoryRecord]
    public var historyId: String

    public init(records: [GmailHistoryRecord], historyId: String) {
        self.records = records
        self.historyId = historyId
    }
}

struct GmailHistoryPage: Decodable {
    var history: [GmailHistoryRecord]?
    var nextPageToken: String?
    var historyId: String
}

public enum GmailMessageFormat: String, Sendable {
    case full, minimal, metadata
}
