// nook-mcp: a local Model Context Protocol server for Nook's mail store.
//
// MCP clients (Claude Code, Claude Desktop, and others) launch this binary and talk to it over stdio.
// It reads the same local database as the app and is off until turned on in Nook → Settings → Integrations.
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
    let repo = MailRepository(db: try Database(path: try databasePath()))
    let server = MCPServer(
        repo: repo,
        isEnabled: { MCPSettings.isEnabled() },
        openURL: { NSWorkspace.shared.open($0) }
    )
    server.run()
} catch {
    // stdout belongs to the protocol, so report problems on stderr.
    FileHandle.standardError.write(Data("nook-mcp: \(error.localizedDescription)\n".utf8))
    exit(1)
}
