import Foundation

/// Builds the classification prompt and reads the model's answer.
///
/// Written for small local models (a 3B Llama, Apple's on-device model): plain steps, hard rules, and worked examples.
/// Left to themselves they pick Needs Reply for almost anything that says "confirm" or "reply", so mail that is clearly
/// sent in bulk never gets offered that tag at all.
public enum TagPrompt {
    /// Bump when the prompt changes enough that recent mail should be tagged again.
    public static let version = 2

    public static let replyTag = "Needs Reply"
    static let newsletterTag = "Newsletter"

    public static func system(tags: [Tag]) -> String {
        let names = Set(tags.map(\.name))
        let examples = Self.examples
            .filter { $0.answer.allSatisfy(names.contains) }
            .map { "\($0.email)\nTags: \($0.answer.isEmpty ? "NONE" : $0.answer.joined(separator: ", "))" }
            .joined(separator: "\n\n")
        var text = """
        You label email for one person. Everything runs privately on their computer.

        For each email, decide:
        1. Who wrote it: a person writing to me, or a company, app or automated system writing to many people?
        2. What it is: a question for me, a newsletter, a receipt, an alert, an invite, and so on.
        3. Which tags clearly fit. Most email gets one tag, some get two, some none. When unsure, leave a tag out.

        Answer with only the tag names, separated by commas, and nothing else. If no tag fits, answer NONE.
        Use only tags from the list you're given.
        """
        if names.contains(replyTag) {
            text += """


            \(replyTag) is the most important tag to get right, and it is rare:
            - Use it only when a real person wrote to me personally and is asking me something or waiting on my answer.
            - Never for email from a company, app, bot or no-reply address, even when it says reply, respond, confirm, \
            verify, action required, or that messages are waiting.
            - Never for newsletters, marketing, receipts, statements, alerts, sign-up or order confirmations.
            - Never for cold sales or partnership pitches sent from a template.
            """
        }
        if !examples.isEmpty {
            text += "\n\nExamples:\n\n" + examples
        }
        return text
    }

    struct Example {
        var email: String
        var answer: [String]
    }

    static let examples: [Example] = [
        Example(email: "From: Priya Shah <priya@acme.com>\nSubject: Release notes\nBody: Hi, can you confirm the release notes are final by tomorrow noon?",
                answer: ["Needs Reply"]),
        Example(email: "From: Spotify <no-reply@spotify.com>\nSubject: Update your payment details\nBody: We couldn't collect your payment. Update your card to keep listening.",
                answer: ["Notification"]),
        Example(email: "From: Andy from Spheres <andy@substack.com>\nSubject: Why the fundamentals matter\nBody: This week's essay is a personal reflection, so grab a cup of tea.",
                answer: ["Newsletter"]),
        Example(email: "From: AppSumo <support@appsumo.com>\nSubject: Order Confirmation\nBody: You've got a brand-new tool! Order #4411, total $59.",
                answer: ["Receipt"]),
        Example(email: "From: GitHub <noreply@github.com>\nSubject: You have used 90% of your Actions minutes\nBody: Your plan includes 2000 minutes per month.",
                answer: ["Notification"]),
        Example(email: "From: Sam Lee <sam@gmail.com>\nSubject: Dinner Saturday?\nBody: We're thinking the new Sichuan place at 7:30. Are you in?",
                answer: ["Needs Reply", "Personal"]),
        Example(email: "From: Cris <cris@outreach.veed.io>\nSubject: Re: Idea to enhance your article\nBody: Just following up in case my note got buried. I have a resource that could add value for your readers.",
                answer: ["Newsletter"]),
        Example(email: "From: HDFC Bank <alerts@hdfcbank.net>\nSubject: Account credited\nBody: Dear Customer, your account XX1273 has been credited with INR 1,727.59.",
                answer: ["Notification", "Finance"]),
        Example(email: "From: Ravi Kumar <ravi@gmail.com>\nSubject: Re: Refund request (Receipt #2803)\nBody: I've emailed three times and had no reply. Please refund the charge.",
                answer: ["Needs Reply"]),
    ]

    /// Bodies are trimmed so prompts stay well inside small on-device context windows.
    public static let maxBodyCharacters = 1500

    /// Gmail's sorting of the message, which is a strong hint about who sent it.
    static func gmailCategory(_ message: MailMessage) -> String? {
        let categories = ["CATEGORY_PROMOTIONS": "Promotions", "CATEGORY_SOCIAL": "Social", "CATEGORY_FORUMS": "Forums",
                          "CATEGORY_UPDATES": "Updates", "CATEGORY_PERSONAL": "Primary"]
        return categories.first { message.labels.contains($0.key) }?.value
    }

    /// Mail sent in bulk: Gmail filed it as promotions, social or a mailing list, or it came from a no-reply style
    /// address. Nobody is waiting on an answer to these.
    public static func isBulk(_ message: MailMessage) -> Bool {
        isBulk(labels: message.labels, fromEmail: message.fromEmail)
    }

    static func isBulk(labels: Set<String>, fromEmail: String) -> Bool {
        !labels.isDisjoint(with: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"]) || ContactBook.isAutomated(fromEmail)
    }

    /// The tags the model may choose for this message.
    public static func allowedTags(for message: MailMessage, tags: [Tag]) -> [Tag] {
        isBulk(message) ? tags.filter { $0.name != replyTag } : tags
    }

    public static func prompt(for message: MailMessage, tags: [Tag]) -> String {
        let tagList = tags.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let body = message.bodyText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .prefix(maxBodyCharacters)
        let hint = gmailCategory(message).map { "Gmail filed it under: \($0)\n" } ?? ""
        return """
        Allowed tags:
        \(tagList)

        Email:
        From: \(EmailAddress(name: message.fromName, email: message.fromEmail).formatted)
        To: \(message.to)
        \(hint)Subject: \(message.subject)
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
        let found = allowed.map(\.name).filter { name in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name.lowercased()) + "(?![\\p{L}\\p{N}])"
            return lowered.range(of: pattern, options: .regularExpression) != nil
        }
        // A newsletter never waits on you, whatever the model says.
        return found.contains(newsletterTag) ? found.filter { $0 != replyTag } : found
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
                    let allowed = TagPrompt.allowedTags(for: message, tags: tags)
                    let response = try await model.complete(system: TagPrompt.system(tags: allowed), prompt: TagPrompt.prompt(for: message, tags: allowed))
                    try repo.setAutoTags(TagPrompt.parse(response, allowed: allowed), account: message.account, messageId: message.id)
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
