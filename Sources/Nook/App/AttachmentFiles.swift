import AppKit
import NookCore
import UniformTypeIdentifiers

/// One attachment and the message it came with.
struct AttachmentRef: Hashable, Identifiable {
    var attachment: Attachment
    var account: String
    var messageId: String

    var id: String { "\(account)/\(messageId)/\(attachment.partId)" }
}

/// Opens, previews and saves attachments.
///
/// Bytes come from Gmail the first time a file is used and stay in memory for the session. Quick Look, Open and
/// drag-and-drop need a real file, so those go to a temporary folder only you can read, emptied at launch and quit.
@MainActor
final class AttachmentFiles {
    typealias Fetch = @Sendable (AttachmentRef) async throws -> Data

    private let fetch: Fetch
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<Data, Error>] = [:]

    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Nook Attachments", isDirectory: true)

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// The bytes, fetched once however many views ask at the same time.
    func data(_ ref: AttachmentRef) async throws -> Data {
        if let cached = cache.object(forKey: ref.id as NSString) { return cached as Data }
        if let task = inFlight[ref.id] { return try await task.value }
        let fetch = fetch
        let task = Task { try await fetch(ref) }
        inFlight[ref.id] = task
        defer { inFlight[ref.id] = nil }
        let data = try await task.value
        cache.setObject(data as NSData, forKey: ref.id as NSString, cost: data.count)
        return data
    }

    /// Already fetched this session, so showing it costs nothing.
    func cachedData(_ ref: AttachmentRef) -> Data? {
        cache.object(forKey: ref.id as NSString) as Data?
    }

    /// The attachment as a file under its own name, for Quick Look, Open and dragging.
    func temporaryFile(_ ref: AttachmentRef) async throws -> URL {
        // One folder per attachment keeps the real file name without clashes.
        let folder = Self.temporaryRoot.appendingPathComponent(Self.folderName(for: ref.id), isDirectory: true)
        let url = folder.appendingPathComponent(Self.safeFilename(ref.attachment.filename))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await data(ref)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.temporaryRoot.path)
        try data.write(to: url, options: [.atomic])
        try AttachmentQuarantine.mark(url)
        return url
    }

    /// The bytes of a file going out with a draft.
    func data(_ attachment: OutgoingAttachment) async throws -> Data {
        switch attachment.source {
        case .data(let data): return data
        case .gmail(let account, let messageId, let original):
            return try await data(AttachmentRef(attachment: original, account: account, messageId: messageId))
        }
    }

    /// A file going out with a draft as a real file, for Quick Look.
    func temporaryFile(_ attachment: OutgoingAttachment) async throws -> URL {
        if case .gmail(let account, let messageId, let original) = attachment.source {
            return try await temporaryFile(AttachmentRef(attachment: original, account: account, messageId: messageId))
        }
        let folder = Self.temporaryRoot.appendingPathComponent(Self.folderName(for: attachment.id.uuidString), isDirectory: true)
        let url = folder.appendingPathComponent(Self.safeFilename(attachment.filename))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await data(attachment)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.temporaryRoot.path)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Saves into Downloads, numbering the name if a file is already there. Returns where each one went.
    func saveToDownloads(_ refs: [AttachmentRef]) async throws -> [URL] {
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var saved: [URL] = []
        for ref in refs {
            let data = try await data(ref)
            let url = Self.unusedURL(in: downloads, for: Self.safeFilename(ref.attachment.filename))
            try data.write(to: url, options: [.withoutOverwriting])
            try AttachmentQuarantine.mark(url)
            saved.append(url)
            // Bounces the Downloads stack in the Dock, the way a finished browser download does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
        return saved
    }

    /// Asks where to save, then saves there.
    func saveWithPanel(_ ref: AttachmentRef) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeFilename(ref.attachment.filename)
        if let type = UTType(mimeType: ref.attachment.mimeType) { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try await data(ref).write(to: url, options: [.atomic])
        try AttachmentQuarantine.mark(url)
        return url
    }

    static func clearTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    /// A file name that can't escape its folder or hide itself.
    static func safeFilename(_ name: String) -> String {
        let cleaned = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Attachment" : String(cleaned.prefix(200))
    }

    static func unusedURL(in folder: URL, for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var url = folder.appendingPathComponent(filename)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }

    private static func folderName(for id: String) -> String {
        // Stable per attachment, and free of the slashes in the id.
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}

extension Attachment {
    /// The Finder icon for this kind of file.
    var icon: NSImage {
        let type = UTType(mimeType: mimeType)
            ?? UTType(filenameExtension: (filename as NSString).pathExtension)
            ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    var formattedSize: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : ""
    }
}

/// What ⌘V would attach to a draft. Text on the clipboard stays text, even with a picture of it alongside,
/// which is how Word and Excel copy; only a copied file, or an image on its own such as a screenshot, is attached.
enum PastedFiles: Equatable {
    case files([URL])
    case image(Data)

    static func read(_ pasteboard: NSPasteboard) -> PastedFiles? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        guard pasteboard.string(forType: .string)?.isEmpty != false else { return nil }
        if let png = pasteboard.data(forType: .png) { return .image(png) }
        guard let tiff = pasteboard.data(forType: .tiff),
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return .image(png)
    }
}

extension OutgoingAttachment {
    var icon: NSImage {
        let type = UTType(mimeType: mimeType) ?? UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Reads a file someone picked or dropped.
    static func fromFile(_ url: URL) throws -> OutgoingAttachment {
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        return OutgoingAttachment(
            filename: url.lastPathComponent,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }
}
