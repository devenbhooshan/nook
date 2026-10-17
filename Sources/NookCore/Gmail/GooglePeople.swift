import Foundation

/// Whether Nook can fetch profile photos for an account.
public enum PhotoAccess: Equatable, Sendable {
    case available
    /// Signed in before Nook asked for contacts. Signing in again grants it.
    case needsPermission
    /// The People API is turned off in the Google Cloud project behind the OAuth client. The link turns it on.
    case apiDisabled(URL?)
}

public enum PeopleError: Error, Equatable {
    case needsPermission
    case apiDisabled(URL?)
    case http(status: Int, message: String)
}

/// Where profile photos come from. The app uses Google's People API; tests use a fake.
public protocol PhotoDirectory: Sendable {
    /// Photo links by lowercased address, for everyone the account knows.
    func photoURLs() async throws -> [String: URL]
}

/// Profile photos from Google: your contacts, "Other contacts" (people you've emailed), and your Workspace directory.
/// Photos come straight from Google, which already handles the account's mail, so no one new learns who writes to you.
public struct GooglePeople: PhotoDirectory {
    private let transport: HTTPTransport
    private let tokens: AccessTokenProvider
    private let baseURL: URL

    public init(transport: HTTPTransport = URLSession.shared, tokens: AccessTokenProvider, baseURL: URL = URL(string: "https://people.googleapis.com/v1/")!) {
        self.transport = transport
        self.tokens = tokens
        self.baseURL = baseURL
    }

    public func photoURLs() async throws -> [String: URL] {
        var photos: [String: URL] = [:]
        // Saved contacts first: if two sources disagree, the photo you chose wins.
        try await collect("people/me/connections", fields: URLQueryItem(name: "personFields", value: "emailAddresses,photos"), into: &photos)
        try await collect("otherContacts", fields: URLQueryItem(name: "readMask", value: "emailAddresses,photos"), into: &photos)
        // Only Workspace accounts have a directory; personal Gmail accounts get an error, which is fine.
        try? await collect(
            "people:listDirectoryPeople", fields: URLQueryItem(name: "readMask", value: "emailAddresses,photos"),
            extra: [URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE")], into: &photos
        )
        return photos
    }

    // MARK: Listing

    struct Person: Decodable {
        struct Email: Decodable { var value: String? }
        struct Photo: Decodable {
            struct Metadata: Decodable { var primary: Bool? }
            var url: String?
            /// A generated letter avatar rather than a real photo.
            var isDefault: Bool?
            var metadata: Metadata?
            enum CodingKeys: String, CodingKey { case url, isDefault = "default", metadata }
        }
        var emailAddresses: [Email]?
        var photos: [Photo]?

        /// The person's own photo, preferring the primary one. Google's generated letter avatars don't count.
        var photoURL: URL? {
            let real = (photos ?? []).filter { $0.isDefault != true && $0.url != nil }
            let photo = real.first { $0.metadata?.primary == true } ?? real.first
            return photo?.url.flatMap(URL.init(string:))
        }
    }

    struct Page: Decodable {
        var connections: [Person]?
        var otherContacts: [Person]?
        var people: [Person]?
        var nextPageToken: String?
        var everyone: [Person] { (connections ?? []) + (otherContacts ?? []) + (people ?? []) }
    }

    private func collect(_ path: String, fields: URLQueryItem, extra: [URLQueryItem] = [], into photos: inout [String: URL]) async throws {
        var pageToken: String?
        repeat {
            var query = [fields, URLQueryItem(name: "pageSize", value: "1000")] + extra
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try JSONDecoder().decode(Page.self, from: try await get(path, query: query))
            for person in page.everyone {
                guard let url = person.photoURL else { continue }
                for email in person.emailAddresses ?? [] {
                    guard let address = email.value?.lowercased(), !address.isEmpty, photos[address] == nil else { continue }
                    photos[address] = url
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var refreshed = false
        while true {
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(try await tokens.accessToken(forceRefresh: refreshed))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 401 where !refreshed:
                refreshed = true
            default:
                throw Self.error(status: response.statusCode, data: data)
            }
        }
    }

    /// Tells a missing permission and a switched-off API apart from other failures; both need you to do something.
    static func error(status: Int, data: Data) -> PeopleError {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                struct Detail: Decodable {
                    var reason: String?
                    var metadata: [String: String]?
                }
                var message: String?
                var details: [Detail]?
            }
            var error: Inner?
        }
        let error = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        let message = error?.message ?? String(decoding: data.prefix(300), as: UTF8.self)
        let reasons = Set((error?.details ?? []).compactMap(\.reason))
        if status == 403, reasons.contains("SERVICE_DISABLED") || message.contains("has not been used") || message.contains("is disabled") {
            let link = error?.details?.lazy.compactMap { $0.metadata?["activationUrl"] }.first
                ?? message.range(of: #"https://console\.developers\.google\.com/\S+"#, options: .regularExpression).map { String(message[$0]) }
            return .apiDisabled(link.flatMap(URL.init(string:)))
        }
        if status == 403, reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || message.lowercased().contains("insufficient authentication scopes") {
            return .needsPermission
        }
        return .http(status: status, message: message)
    }
}

/// Gathers every account's photo links. Photos themselves are never stored: the app downloads the ones it shows
/// and keeps them in memory.
public enum PhotoSync {
    public struct Result: Sendable, Equatable {
        /// Photo links by lowercased address, across all accounts.
        public var photos: [String: URL] = [:]
        /// What each account allowed. Accounts that failed for other reasons (offline, say) are left out.
        public var access: [String: PhotoAccess] = [:]
    }

    public static func run(directories: [String: PhotoDirectory]) async -> Result {
        var result = Result()
        // One account at a time: there are only a few, and each is a handful of requests.
        for (account, directory) in directories.sorted(by: { $0.key < $1.key }) {
            do {
                let photos = try await directory.photoURLs()
                result.access[account] = .available
                result.photos.merge(photos) { first, _ in first }
            } catch PeopleError.needsPermission {
                result.access[account] = .needsPermission
            } catch PeopleError.apiDisabled(let link) {
                result.access[account] = .apiDisabled(link)
            } catch {
                continue
            }
        }
        return result
    }
}
