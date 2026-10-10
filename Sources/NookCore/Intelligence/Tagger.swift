import Foundation

/// Builds the classification prompt and reads the model's answer.
public enum TagPrompt {
    public static let system = """
    You sort email for one person. All processing happens privately on their computer.
    Choose which of the allowed tags apply to the email. An email can have several tags or none.
    Answer with only the tag names, separated by commas. If no tag fits, answer NONE.
    Never invent tags that aren't in the list.
    """

    /// Bodies are trimmed so prompts stay well inside small on-device context windows.
    public static let maxBodyCharacters = 1500

    public static func prompt(for message: MailMessage, tags: [Tag]) -> String {
        let tagList = tags.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let body = message.bodyText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .prefix(maxBodyCharacters)
        return """
        Allowed tags:
        \(tagList)

        Email:
        From: \(EmailAddress(name: message.fromName, email: message.fromEmail).formatted)
        To: \(message.to)
        Subject: \(message.subject)
        Body: \(body)

        Tags:
        """
    }

    /// Finds the allowed tag names mentioned in the response, in the user's tag order.
    /// Tolerates the usual model noise: bullets, quotes, casing, extra words.
    public static func parse(_ response: String, allowed: [Tag]) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("NONE") { return [] }
        let lowered = trimmed.lowercased()
        return allowed.map(\.name).filter { name in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name.lowercased()) + "(?![\\p{L}\\p{N}])"
            return lowered.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

public struct TaggerStatus: Sendable, Equatable {
    public var isRunning: Bool
    public var modelName: String?
    public var pending: Int
    public var lastError: String?

    public init(isRunning: Bool = false, modelName: String? = nil, pending: Int = 0, lastError: String? = nil) {
        self.isRunning = isRunning
        self.modelName = modelName
        self.pending = pending
        self.lastError = lastError
    }
}

/// Tags new mail in the background, newest first, one message at a time.
public actor Tagger {
    public typealias ModelProvider = @Sendable () async -> TagModel?

    private let repo: MailRepository
    private let modelProvider: ModelProvider
    private let onUpdate: @Sendable (TaggerStatus) -> Void
    private let batchSize: Int
    private var isRunning = false
    private var needsAnotherPass = false

    public init(
        repo: MailRepository,
        batchSize: Int = 10,
        modelProvider: @escaping ModelProvider,
        onUpdate: @escaping @Sendable (TaggerStatus) -> Void = { _ in }
    ) {
        self.repo = repo
        self.batchSize = batchSize
        self.modelProvider = modelProvider
        self.onUpdate = onUpdate
    }

    /// Tags everything that's waiting. If a run is already going, it does one more pass when it finishes.
    public func run() async {
        if isRunning {
            needsAnotherPass = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            needsAnotherPass = false
            await drain()
        } while needsAnotherPass
    }

    private func drain() async {
        let tags = repo.tags()
        guard !tags.isEmpty else { return }
        guard let model = await modelProvider() else {
            onUpdate(TaggerStatus(pending: repo.untaggedCount(), lastError: "No on-device model available"))
            return
        }

        var status = TaggerStatus(isRunning: true, modelName: model.displayName, pending: repo.untaggedCount())
        onUpdate(status)

        while !Task.isCancelled {
            let batch = repo.untaggedMessages(limit: batchSize)
            if batch.isEmpty { break }

            for message in batch {
                do {
                    let response = try await model.complete(system: TagPrompt.system, prompt: TagPrompt.prompt(for: message, tags: tags))
                    try repo.setAutoTags(TagPrompt.parse(response, allowed: tags), account: message.account, messageId: message.id)
                } catch is TagModelSkip {
                    try? repo.setAutoTags([], account: message.account, messageId: message.id)
                } catch {
                    // The model is unreachable or broken. Stop, and try again after the next sync.
                    status.isRunning = false
                    status.lastError = error.localizedDescription
                    status.pending = repo.untaggedCount()
                    onUpdate(status)
                    return
                }
            }
            status.pending = repo.untaggedCount()
            onUpdate(status)
        }

        status.isRunning = false
        status.pending = repo.untaggedCount()
        onUpdate(status)
    }
}
