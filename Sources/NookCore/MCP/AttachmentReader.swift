import CryptoKit
import Foundation
import PDFKit

/// Turns an attachment's bytes into text an assistant can read. The contents are whatever the sender put there,
/// so callers must treat them as untrusted.
enum AttachmentReader {
    struct Extraction: Equatable {
        /// Nil when the file holds no text to read here.
        var text: String?
        var truncated = false
        var pages: Int?
        var note: String?
    }

    static let maxTextCharacters = 100_000

    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log", "ics", "vcf", "eml", "html", "htm",
    ]
    private static let textTypes: Set<String> = [
        "application/json", "application/xml", "application/yaml", "application/x-yaml", "application/csv",
    ]

    static func read(_ data: Data, attachment: Attachment) -> Extraction {
        if isPDF(data, attachment: attachment) { return readPDF(data) }
        guard isTextLike(attachment), !data.contains(0), let decoded = decode(data) else {
            return Extraction(note: "Not a text file. Use the saved copy at `path`.")
        }
        let isHTML = attachment.mimeType.lowercased() == "text/html" || ["html", "htm"].contains(fileExtension(of: attachment))
        return clipped(isHTML ? MIMEParser.plainText(fromHTML: decoded) : decoded)
    }

    private static func readPDF(_ data: Data) -> Extraction {
        guard let document = PDFDocument(data: data) else {
            return Extraction(note: "This PDF couldn't be read. Use the saved copy at `path`.")
        }
        if document.isLocked {
            return Extraction(pages: document.pageCount, note: "This PDF is password-protected, so its text can't be read.")
        }
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return Extraction(pages: document.pageCount, note: "This PDF has no text layer; it's probably scanned. Use the saved copy at `path`.")
        }
        var extraction = clipped(text)
        extraction.pages = document.pageCount
        return extraction
    }

    private static func clipped(_ text: String) -> Extraction {
        guard text.count > maxTextCharacters else { return Extraction(text: text) }
        return Extraction(text: String(text.prefix(maxTextCharacters)), truncated: true, note: "Text cut short. The whole file is at `path`.")
    }

    private static func isPDF(_ data: Data, attachment: Attachment) -> Bool {
        attachment.mimeType.lowercased() == "application/pdf" || fileExtension(of: attachment) == "pdf" || data.starts(with: Data("%PDF-".utf8))
    }

    private static func isTextLike(_ attachment: Attachment) -> Bool {
        let type = attachment.mimeType.lowercased()
        return type.hasPrefix("text/") || textTypes.contains(type) || textExtensions.contains(fileExtension(of: attachment))
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func fileExtension(of attachment: Attachment) -> String {
        (attachment.filename as NSString).pathExtension.lowercased()
    }
}

/// Copies of attachments for assistants to open, in a folder only you can read. Attachments otherwise never touch
/// the disk, so these are kept for a day and then removed.
struct AttachmentCache {
    var root: URL
    var keepFor: TimeInterval = 24 * 60 * 60

    static func standard() throws -> AttachmentCache {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AttachmentCache(root: caches.appendingPathComponent("Nook/mcp-attachments", isDirectory: true))
    }

    /// Saves the bytes and returns where they went. Each attachment gets its own folder, so names can't collide.
    func save(_ data: Data, attachment: Attachment, account: String, messageId: String) throws -> URL {
        let manager = FileManager.default
        try prune()
        let key = SHA256.hash(data: Data("\(account)/\(messageId)/\(attachment.partId)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let url = folder.appendingPathComponent(Self.safeFilename(attachment.filename))
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func prune() throws {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-keepFor)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: folder) }
        }
    }

    /// A sender chooses the name, so it can't be trusted as a path: no folders, no hidden files, nothing unprintable.
    static func safeFilename(_ name: String, maxLength: Int = 120) -> String {
        let allowed = name.unicodeScalars.map { scalar -> Character in
            let unsafe = CharacterSet.controlCharacters.union(.illegalCharacters).union(CharacterSet(charactersIn: "/\\:"))
            return unsafe.contains(scalar) ? "_" : Character(scalar)
        }
        var safe = String(allowed).trimmingCharacters(in: .whitespacesAndNewlines)
        while safe.hasPrefix(".") { safe.removeFirst() }
        guard safe.utf8.count > maxLength else { return safe.isEmpty ? "attachment" : safe }
        let suffix = (safe as NSString).pathExtension
        let tail = suffix.isEmpty || suffix.utf8.count > 16 ? "" : "." + suffix
        var stem = (tail.isEmpty ? safe : (safe as NSString).deletingPathExtension)
        while stem.utf8.count + tail.utf8.count > maxLength { stem.removeLast() }
        return stem + tail
    }
}
