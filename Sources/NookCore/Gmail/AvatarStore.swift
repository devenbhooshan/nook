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

    // MARK: Verified marks

    /// The last check of a domain's Verified Mark Certificate: which certificate, when it was checked, and when it
    /// expires if it passed (nil if it didn't).
    public struct VerifiedMark: Codable, Equatable, Sendable {
        public var certificate: String
        public var expires: Date?
        public var checked: Date

        public init(certificate: String, expires: Date?, checked: Date = Date()) {
            self.certificate = certificate
            self.expires = expires
            self.checked = checked
        }

        /// Whether to check `certificate` (the one the domain lists now) again: it's a different certificate, or this
        /// one failed or has expired and wasn't checked in the last week (it may have been renewed in place).
        public func needsCheck(of certificate: String, at date: Date = Date()) -> Bool {
            if certificate != self.certificate { return true }
            if let expires, expires > date { return false }
            return date.timeIntervalSince(checked) > 7 * 86_400
        }
    }

    private var verifiedURL: URL { directory.appendingPathComponent("verified.json") }
    private lazy var verified: [String: VerifiedMark] = {
        (try? JSONDecoder().decode([String: VerifiedMark].self, from: Data(contentsOf: verifiedURL))) ?? [:]
    }()

    /// Whether the domain has a mark that passed its check and is still valid.
    public func isVerified(_ domain: String, at date: Date = Date()) -> Bool {
        guard let expires = lock.withLock({ verified[domain.lowercased()] })?.expires else { return false }
        return expires > date
    }

    /// The last check of the domain's mark, passed or not.
    public func verifiedMark(for domain: String) -> VerifiedMark? {
        lock.withLock { verified[domain.lowercased()] }
    }

    /// Records a check of a domain's mark, or forgets it with nil. Returns whether the domain's verified state changed.
    @discardableResult
    public func setVerifiedMark(_ mark: VerifiedMark?, for domain: String, at date: Date = Date()) -> Bool {
        let before = isVerified(domain, at: date)
        let snapshot = lock.withLock { () -> [String: VerifiedMark]? in
            guard verified[domain.lowercased()] != mark else { return nil }
            verified[domain.lowercased()] = mark
            return verified
        }
        guard let snapshot else { return false }
        try? JSONEncoder().encode(snapshot).write(to: verifiedURL, options: .atomic)
        return isVerified(domain, at: date) != before
    }
}
