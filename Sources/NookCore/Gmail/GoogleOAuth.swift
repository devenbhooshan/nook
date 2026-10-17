import CryptoKit
import Foundation

/// The OAuth client Nook signs in with. Each user (or distributor) creates their own "Desktop app"
/// client in Google Cloud. For installed apps Google doesn't treat the secret as confidential,
/// but Nook still keeps it in the Keychain.
public struct GoogleClientConfig: Sendable, Equatable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { !clientId.isEmpty && !clientSecret.isEmpty }

    static let clientIdKey = "google.clientId"
    static let clientSecretKey = "google.clientSecret"

    /// Reads from the environment (`NOOK_GOOGLE_CLIENT_ID`/`NOOK_GOOGLE_CLIENT_SECRET`) first, then the store.
    public static func load(from store: SecretStore, environment: [String: String] = ProcessInfo.processInfo.environment) -> GoogleClientConfig {
        GoogleClientConfig(
            clientId: environment["NOOK_GOOGLE_CLIENT_ID"] ?? store.string(for: clientIdKey) ?? "",
            clientSecret: environment["NOOK_GOOGLE_CLIENT_SECRET"] ?? store.string(for: clientSecretKey) ?? ""
        )
    }

    public func save(to store: SecretStore) throws {
        try store.setString(clientId, for: Self.clientIdKey)
        try store.setString(clientSecret, for: Self.clientSecretKey)
    }
}

public enum OAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case stateMismatch
    case denied(String)
    case missingCode
    case missingRefreshToken
    case tokenRequestFailed(String)
    /// Google revoked or expired the sign-in (a password change, removed access, or a 7-day testing-mode limit).
    case signInExpired

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Google OAuth client ID and secret first."
        case .stateMismatch: "The sign-in response didn't match the request. Please try again."
        case .denied(let reason): "Google sign-in was cancelled (\(reason))."
        case .missingCode: "Google didn't return an authorization code."
        case .missingRefreshToken: "Google didn't return a refresh token. Remove Nook's access at myaccount.google.com/permissions and try again."
        case .tokenRequestFailed(let message): "Google sign-in failed: \(message)"
        case .signInExpired: "Google ended Nook's sign-in. Sign in again to resume syncing."
        }
    }
}

/// Google OAuth 2.0 for installed apps: authorization code + PKCE over a loopback redirect.
public enum GoogleOAuth {
    /// Whether an error means the account has to be signed in again, rather than something that passes on its own.
    public static func requiresSignIn(_ error: Error) -> Bool {
        switch error {
        case OAuthError.signInExpired, GmailError.unauthorized, GmailError.notSignedIn: true
        default: false
        }
    }

    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify", "openid", "email", "profile",
        // Profile photos for senders: your contacts, the people you've emailed, and your Workspace directory.
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly",
        "https://www.googleapis.com/auth/directory.readonly",
    ]
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let userInfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

    public struct SignInResult: Sendable {
        public var email: String
        public var name: String
        public var tokens: TokenSet
    }

    /// Runs the whole flow: open the browser, wait for the redirect, exchange the code, look up who signed in.
    public static func signIn(
        config: GoogleClientConfig,
        transport: HTTPTransport = URLSession.shared,
        loginHint: String? = nil,
        openURL: @Sendable (URL) -> Void,
        timeout: Duration = .seconds(300)
    ) async throws -> SignInResult {
        guard config.isComplete else { throw OAuthError.notConfigured }

        let pkce = PKCE()
        let state = PKCE.randomString(length: 32)
        let server = LoopbackServer(expectedState: state)
        let port = try await server.start()
        defer { server.stop() }

        let redirectURI = "http://127.0.0.1:\(port)"
        openURL(authorizationURL(config: config, redirectURI: redirectURI, challenge: pkce.challenge, state: state, loginHint: loginHint))

        let callback = try await server.waitForCallback(timeout: timeout)
        if let error = callback["error"] { throw OAuthError.denied(error) }
        guard callback["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = callback["code"] else { throw OAuthError.missingCode }

        let tokens = try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI, config: config, transport: transport)
        let (email, name) = try await userInfo(accessToken: tokens.accessToken, transport: transport)
        return SignInResult(email: email, name: name, tokens: tokens)
    }

    /// - Parameter loginHint: The account to preselect when signing an existing account in again.
    public static func authorizationURL(
        config: GoogleClientConfig, redirectURI: String, challenge: String, state: String, loginHint: String? = nil
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ]
        if let loginHint { components.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        return components.url!
    }

    static func exchange(code: String, verifier: String, redirectURI: String, config: GoogleClientConfig, transport: HTTPTransport) async throws -> TokenSet {
        let response = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
        ], transport: transport)
        guard let refreshToken = response.refresh_token else { throw OAuthError.missingRefreshToken }
        return TokenSet(accessToken: response.access_token, refreshToken: refreshToken, expiry: Date().addingTimeInterval(response.expires_in ?? 3600))
    }

    public static func refresh(_ tokens: TokenSet, config: GoogleClientConfig, transport: HTTPTransport = URLSession.shared) async throws -> TokenSet {
        let response = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
        ], transport: transport)
        return TokenSet(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? tokens.refreshToken,
            expiry: Date().addingTimeInterval(response.expires_in ?? 3600)
        )
    }

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
    }

    static func tokenRequest(_ form: [String: String], transport: HTTPTransport) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { var error: String?; var error_description: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if failure?.error == "invalid_grant" { throw OAuthError.signInExpired }
            throw OAuthError.tokenRequestFailed(failure?.error_description ?? failure?.error ?? "HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func userInfo(accessToken: String, transport: HTTPTransport) async throws -> (email: String, name: String) {
        struct Info: Decodable { var email: String; var name: String? }
        var request = URLRequest(url: userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw OAuthError.tokenRequestFailed("Couldn't read the account's email address.") }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return (info.email, info.name ?? "")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { key in
            "\(key)=\(form[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// Proof Key for Code Exchange (RFC 7636).
public struct PKCE: Sendable {
    public let verifier: String
    public var challenge: String { Self.challenge(for: verifier) }

    public init(verifier: String = PKCE.randomString(length: 64)) {
        self.verifier = verifier
    }

    public static func challenge(for verifier: String) -> String {
        MIMEBuilder.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

/// Holds an account's tokens and refreshes them when they're about to expire. Refreshed tokens are saved back to the store.
public actor OAuthTokenProvider: AccessTokenProvider {
    private let email: String
    private let config: GoogleClientConfig
    private let store: SecretStore
    private let transport: HTTPTransport
    private var tokens: TokenSet

    public init(email: String, tokens: TokenSet, config: GoogleClientConfig, store: SecretStore, transport: HTTPTransport = URLSession.shared) {
        self.email = email
        self.tokens = tokens
        self.config = config
        self.store = store
        self.transport = transport
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, tokens.expiry > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        tokens = try await GoogleOAuth.refresh(tokens, config: config, transport: transport)
        try? store.setTokens(tokens, for: email)
        return tokens.accessToken
    }
}
