import Foundation

/// Where a person is in first-run setup: connect mail, choose how tagging runs, then (optionally) connect an assistant.
public enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    /// No mail account yet.
    case connectAccount
    /// Mail is connected; pick the on-device model for tagging (Ollama, Apple Intelligence, or off).
    case setUpTagging
    /// Optionally let an AI assistant use Nook over MCP.
    case connectAssistant
    case done

    public static let completedKey = "onboarding.completed"
    public static let taggingReviewedKey = "onboarding.taggingReviewed"

    /// - Parameters:
    ///   - hasAccounts: Whether any mail account is connected.
    ///   - completed: The stored completion flag. `nil` means it was never written, which is the case for
    ///     people who set Nook up before onboarding had more than one step. They have accounts, so they skip the rest.
    ///   - taggingReviewed: Whether the tagging step has been passed in this run of onboarding.
    public static func current(hasAccounts: Bool, completed: Bool?, taggingReviewed: Bool) -> OnboardingStep {
        guard hasAccounts else { return .connectAccount }
        guard completed == false else { return .done }
        return taggingReviewed ? .connectAssistant : .setUpTagging
    }
}

/// MCP clients Nook knows how to explain, with the exact setup text for each.
public enum MCPClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case claudeDesktop
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .other: "Other clients"
        }
    }

    /// One sentence on where the snippet goes.
    public var instructions: String {
        switch self {
        case .claudeCode: "Run this in Terminal:"
        case .claudeDesktop: "Add this to \"mcpServers\" in claude_desktop_config.json, then restart Claude:"
        case .other: "Add a stdio server that runs this command:"
        }
    }

    /// - Parameter serverPath: The absolute path to `nook-mcp`.
    public func snippet(serverPath: String) -> String {
        switch self {
        case .claudeCode:
            return "claude mcp add nook -- \(Self.shellQuoted(serverPath))"
        case .claudeDesktop:
            let escaped = serverPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"nook\": {\n  \"command\": \"\(escaped)\"\n}"
        case .other:
            return serverPath
        }
    }

    /// Quotes a path for the shell only when it needs it, so the common case stays readable.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        guard path.unicodeScalars.contains(where: { !safe.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
