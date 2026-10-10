import Foundation
import NookCore

/// Remembers each message's prepared HTML and whether it loads remote content, so SwiftUI redraws of the reader
/// don't rebuild documents or rescan long bodies with regular expressions on the main thread.
///
/// A message's body never changes once it's stored, so its account and id are enough to key it.
@MainActor
enum MessageRenderCache {
    private final class Box<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let documents: NSCache<NSString, Box<String>> = {
        let cache = NSCache<NSString, Box<String>>()
        cache.countLimit = 200
        return cache
    }()

    private static let remoteContent: NSCache<NSString, Box<Bool>> = {
        let cache = NSCache<NSString, Box<Bool>>()
        cache.countLimit = 1000
        return cache
    }()

    static func document(for message: MailMessage, allowRemoteContent: Bool) -> String {
        let key = "\(message.account)/\(message.id)/\(allowRemoteContent)" as NSString
        if let cached = documents.object(forKey: key) { return cached.value }
        let document = EmailHTML.document(for: message, allowRemoteContent: allowRemoteContent)
        documents.setObject(Box(document), forKey: key)
        return document
    }

    static func containsRemoteContent(_ message: MailMessage) -> Bool {
        let key = "\(message.account)/\(message.id)" as NSString
        if let cached = remoteContent.object(forKey: key) { return cached.value }
        let result = EmailHTML.containsRemoteContent(message.bodyHTML)
        remoteContent.setObject(Box(result), forKey: key)
        return result
    }
}
