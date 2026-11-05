// nook-mcp: a local Model Context Protocol server for Nook's mail store.
//
// MCP clients (Claude Code, Claude Desktop, and others) launch this binary and talk to it over stdio.
// It reads the same local database as the app and is off until turned on in Nook → Settings → Integrations.
// get_attachment downloads a file Nook hasn't stored yet, with the account's Nook sign-in.
//
//   claude mcp add nook -- /Applications/Nook.app/Contents/MacOS/nook-mcp
//
// Options: --database <path> reads a different store (also NOOK_DATABASE), for development.
import AppKit
import NookCore

func databasePath() throws -> String {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--database"), arguments.indices.contains(flag + 1) {
        return arguments[flag + 1]
    }
    if let path = ProcessInfo.processInfo.environment["NOOK_DATABASE"] { return path }
    return try Database.defaultURL().path
}

do {
    // The store is encrypted; its key comes from the Keychain. nook-mcp is signed with Nook's identity,
    // so the Keychain hands it over without asking.
    let secrets = KeychainStore()
    let repo = try MailStore.openForReading(path: try databasePath(), secrets: secrets)
    let server = MCPServer(
        repo: repo,
        isEnabled: { MCPSettings.isEnabled() },
        openURL: { NSWorkspace.shared.open($0) },
        makeGmail: { email in
            guard let tokens = secrets.tokens(for: email) else { throw GmailError.notSignedIn(email) }
            let provider = OAuthTokenProvider(email: email, tokens: tokens, config: GoogleClientConfig.load(from: secrets), store: secrets)
            return GmailClient(tokens: provider)
        }
    )
    server.run()
} catch {
    // stdout belongs to the protocol, so report problems on stderr.
    FileHandle.standardError.write(Data("nook-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
