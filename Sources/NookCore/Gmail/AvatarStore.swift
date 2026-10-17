import CryptoKit
import Foundation

/// Profile photos on disk, one file per address, in Nook's Caches folder.
///
/// Photos are downloaded once and shown from here, never loaded from Google while you read. Files are named by a hash
/// of the address, so the folder doesn't list who writes to you, and an index remembers each photo's source link so a
/// changed photo is fetched again. macOS may clear Caches; the next refresh downloads what's missing.
public final class AvatarStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var index: [String: String]
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        index = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))) ?? [:]
    }

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.devenbhooshan.nook/Avatars", isDirectory: true)
    }

    static func key(for email: String) -> String {
        SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key)
    }

    /// The stored photo for an address, if there is one.
    public func image(for email: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: Self.key(for: email)))
    }

    public func save(_ image: Data, for email: String, from url: URL) throws {
        let key = Self.key(for: email)
        try image.write(to: fileURL(forKey: key), options: .atomic)
        let snapshot = lock.withLock { () -> [String: String] in
            index[key] = url.absoluteString
            return index
        }
        try JSONEncoder().encode(snapshot).write(to: indexURL, options: .atomic)
    }

    /// The addresses whose photo is missing or has changed.
    public func outdated(_ photos: [String: URL]) -> [String: URL] {
        let index = lock.withLock { self.index }
        return photos.filter { email, url in
            let key = Self.key(for: email)
            return index[key] != url.absoluteString || !FileManager.default.fileExists(atPath: fileURL(forKey: key).path)
        }
    }

    /// Downloads the photos that are missing or changed. Returns the addresses that got a new photo.
    @discardableResult
    public func download(
        _ photos: [String: URL], transport: HTTPTransport = AvatarStore.session, concurrent: Int = 8
    ) async -> Set<String> {
        let todo = Array(outdated(photos))
        var updated: Set<String> = []
        // In batches, so a few downloads run at once without a long-lived task group.
        for start in stride(from: 0, to: todo.count, by: max(1, concurrent)) {
            let batch = todo[start..<min(start + max(1, concurrent), todo.count)]
            let saved = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                for (email, url) in batch {
                    group.addTask { [self] in
                        // Photo links are public and need no sign-in.
                        guard let (data, response) = try? await transport.send(URLRequest(url: url)),
                              response.statusCode == 200, !data.isEmpty, data.count < 1_000_000,
                              (try? save(data, for: email, from: url)) != nil else { return nil }
                        return email
                    }
                }
                var saved: [String] = []
                for await email in group { if let email { saved.append(email) } }
                return saved
            }
            updated.formUnion(saved)
        }
        return updated
    }

    /// Downloads skip the HTTP cache: the files above are the only copy kept.
    public static let session: URLSession = URLSession(configuration: .ephemeral)
}
