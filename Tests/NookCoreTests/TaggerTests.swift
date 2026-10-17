import Foundation
import Testing
@testable import NookCore

@Suite("Tagging")
struct TaggerTests {
    let tags = Tag.defaults

    @Test(arguments: [
        ("Receipt", ["Receipt"]),
        ("receipt, finance", ["Receipt", "Finance"]),
        ("- Needs Reply\n- Calendar", ["Needs Reply", "Calendar"]),
        ("Tags: \"Newsletter\".", ["Newsletter"]),
        ("NONE", []),
        ("None of these apply.", []),
        ("", []),
        ("Receipts", []),
        ("Shopping", []),
        ("Needs Reply, Newsletter", ["Newsletter"]),
    ])
    func parsesModelResponses(response: String, expected: [String]) {
        #expect(TagPrompt.parse(response, allowed: tags) == expected)
    }

    @Test func promptListsTagsAndTrimsLongBodies() {
        let message = MailMessage.fixture(id: "1", from: "shop@x.com", fromName: "Shop", subject: "Order shipped", body: String(repeating: "word ", count: 2000))
        let prompt = TagPrompt.prompt(for: message, tags: tags)
        #expect(prompt.contains("- Receipt: Receipts, invoices"))
        #expect(prompt.contains("From: Shop <shop@x.com>"))
        #expect(prompt.contains("Subject: Order shipped"))
        #expect(prompt.count < TagPrompt.maxBodyCharacters + 2000)
    }

    @Test func bulkMailIsNeverOfferedNeedsReply() {
        let promo = MailMessage.fixture(id: "1", from: "info@members.netflix.com", labels: [SystemLabel.inbox, "CATEGORY_PROMOTIONS"])
        let noReply = MailMessage.fixture(id: "2", from: "noreply@github.com")
        let person = MailMessage.fixture(id: "3", from: "ravi@gmail.com", labels: [SystemLabel.inbox, "CATEGORY_PERSONAL"])
        #expect(!TagPrompt.allowedTags(for: promo, tags: tags).map(\.name).contains("Needs Reply"))
        #expect(!TagPrompt.allowedTags(for: noReply, tags: tags).map(\.name).contains("Needs Reply"))
        #expect(TagPrompt.allowedTags(for: person, tags: tags).map(\.name).contains("Needs Reply"))
        #expect(TagPrompt.prompt(for: promo, tags: tags).contains("Gmail filed it under: Promotions"))
        #expect(TagPrompt.system(tags: tags).contains("Examples:"))
        #expect(!TagPrompt.system(tags: TagPrompt.allowedTags(for: promo, tags: tags)).contains("Needs Reply"))
    }

    @Test func upgradeDropsNeedsReplyFromBulkMailAndRetagsRecentMail() throws {
        let repo = try makeRepository()
        try repo.upsert([
            .fixture(id: "1", from: "info@members.netflix.com", labels: [SystemLabel.inbox, "CATEGORY_PROMOTIONS"]),
            .fixture(id: "2", from: "andy@substack.com"),
            .fixture(id: "3", from: "ravi@gmail.com"),
            .fixture(id: "4", from: "old@gmail.com", minutesAgo: 60 * 24 * 60),
        ])
        try repo.setAutoTags(["Needs Reply"], account: "me@example.com", messageId: "1")
        try repo.setAutoTags(["Needs Reply", "Newsletter"], account: "me@example.com", messageId: "2")
        try repo.setAutoTags(["Needs Reply", "Receipt"], account: "me@example.com", messageId: "3")
        try repo.setAutoTags(["Personal"], account: "me@example.com", messageId: "4")

        try repo.upgradeTags(since: Date(timeIntervalSince1970: 1_700_000_000 - 30 * 86400))
        #expect(repo.tags(account: "me@example.com", messageId: "1").isEmpty)
        #expect(repo.tags(account: "me@example.com", messageId: "2") == ["Newsletter"])
        #expect(repo.tags(account: "me@example.com", messageId: "3") == ["Needs Reply", "Receipt"])
        #expect(repo.untaggedCount() == 3)
    }

    @Test func tagsEveryWaitingMessage() async throws {
        let repo = try makeRepository()
        try repo.upsert([
            .fixture(id: "1", subject: "Your receipt"),
            .fixture(id: "2", subject: "Weekly digest"),
            .fixture(id: "3", subject: "lunch?"),
        ])
        let model = ScriptedModel { prompt in
            if prompt.contains("Subject: Your receipt") { return "Receipt" }
            if prompt.contains("Subject: Weekly digest") { return "Newsletter" }
            return "NONE"
        }
        let updates = Counter()
        let tagger = Tagger(repo: repo, batchSize: 2, modelProvider: { model }, onUpdate: { _ in updates.increment() })

        await tagger.run()
        #expect(repo.tags(account: "me@example.com", messageId: "1") == ["Receipt"])
        #expect(repo.tags(account: "me@example.com", messageId: "2") == ["Newsletter"])
        #expect(repo.tags(account: "me@example.com", messageId: "3").isEmpty)
        #expect(repo.untaggedCount() == 0)
        #expect(updates.count >= 3)
    }

    @Test func skipsMessagesTheModelRefuses() async throws {
        let repo = try makeRepository()
        try repo.upsert([.fixture(id: "1"), .fixture(id: "2", minutesAgo: 1)])
        let model = ScriptedModel { prompt in
            if prompt.contains("<1@") || prompt.contains("Body: Body") && !prompt.isEmpty {
                throw TagModelSkip(reason: "guardrail")
            }
            return "Receipt"
        }
        await Tagger(repo: repo, modelProvider: { model }).run()
        #expect(repo.untaggedCount() == 0)
    }

    @Test func pausesWhenTheModelIsUnreachable() async throws {
        let repo = try makeRepository()
        try repo.upsert([.fixture(id: "1"), .fixture(id: "2")])
        let statuses = StatusLog()
        let model = ScriptedModel { _ in throw URLError(.cannotConnectToHost) }

        await Tagger(repo: repo, modelProvider: { model }, onUpdate: { statuses.append($0) }).run()
        #expect(repo.untaggedCount() == 2)
        #expect(statuses.last?.isRunning == false)
        #expect(statuses.last?.lastError != nil)
    }

    @Test func doesNothingWithoutAModel() async throws {
        let repo = try makeRepository()
        try repo.upsert([.fixture(id: "1")])
        let statuses = StatusLog()
        await Tagger(repo: repo, modelProvider: { nil }, onUpdate: { statuses.append($0) }).run()
        #expect(repo.untaggedCount() == 1)
        #expect(statuses.last?.pending == 1)
    }

    @Test func resolvesTheConfiguredEngine() async {
        let ollamaUp: @Sendable (URL) async -> [String]? = { _ in ["llama3.2:latest", "mistral"] }
        let ollamaDown: @Sendable (URL) async -> [String]? = { _ in nil }

        // Automatic prefers Ollama, then falls back to Apple Intelligence.
        let automatic = TaggingSettings(engine: .automatic)
        #expect(await automatic.resolveModel(appleAvailable: true, ollamaModels: ollamaUp)?.displayName == "Ollama · llama3.2")
        #expect(await automatic.resolveModel(appleAvailable: true, ollamaModels: ollamaDown)?.displayName == "Apple Intelligence")
        #expect(await TaggingSettings(engine: .automatic, ollamaModel: "missing").resolveModel(appleAvailable: true, ollamaModels: ollamaUp)?.displayName == "Apple Intelligence")
        #expect(await automatic.resolveModel(appleAvailable: false, ollamaModels: ollamaDown) == nil)

        #expect(await TaggingSettings(engine: .off).resolveModel(appleAvailable: true, ollamaModels: ollamaUp) == nil)
        #expect(await TaggingSettings(engine: .apple).resolveModel(appleAvailable: false, ollamaModels: ollamaUp) == nil)
        #expect(await TaggingSettings(engine: .ollama, ollamaModel: "mistral").resolveModel(appleAvailable: true, ollamaModels: ollamaUp)?.displayName == "Ollama · mistral")
        #expect(await TaggingSettings(engine: .ollama, ollamaModel: "missing").resolveModel(appleAvailable: true, ollamaModels: ollamaUp) == nil)
    }

    @Test func ollamaModelSpeaksTheChatAPI() async throws {
        let transport = StubTransport([.init(200, #"{"message":{"role":"assistant","content":"Receipt"}}"#)])
        let model = OllamaTagModel(model: "llama3.2", transport: transport)
        #expect(try await model.complete(system: "sys", prompt: "hi") == "Receipt")

        let request = try #require(transport.recorded.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "llama3.2")
        #expect(body["stream"] as? Bool == false)
    }

    @Test func listsInstalledOllamaModels() async {
        let up = StubTransport([.init(200, #"{"models":[{"name":"qwen3"},{"name":"llama3.2:latest"}]}"#)])
        #expect(await OllamaTagModel.installedModels(transport: up) == ["llama3.2:latest", "qwen3"])
        #expect(await OllamaTagModel.installedModels(transport: StubTransport([.init(500)])) == nil)
    }

    @Test func readsSettingsFromDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "nook-tests-\(UUID().uuidString)"))
        #expect(TaggingSettings.load(defaults) == TaggingSettings())
        defaults.set("ollama", forKey: TaggingSettings.engineKey)
        defaults.set("qwen3", forKey: TaggingSettings.ollamaModelKey)
        defaults.set("http://10.0.0.2:11434", forKey: TaggingSettings.ollamaURLKey)
        let settings = TaggingSettings.load(defaults)
        #expect(settings.engine == .ollama)
        #expect(settings.ollamaModel == "qwen3")
        #expect(settings.ollamaURL.host() == "10.0.0.2")
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TaggerStatus] = []
    func append(_ status: TaggerStatus) { lock.withLock { items.append(status) } }
    var last: TaggerStatus? { lock.withLock { items.last } }
}

@Suite("OllamaStatus")
struct OllamaStatusTests {
    @Test func evaluatesWhatsInstalled() {
        #expect(OllamaStatus.evaluate(installedModels: nil, model: "llama3.2") == .notRunning)
        #expect(OllamaStatus.evaluate(installedModels: [], model: "llama3.2") == .missingModel("llama3.2"))
        #expect(OllamaStatus.evaluate(installedModels: ["llama3.2:latest"], model: "llama3.2") == .ready("llama3.2"))
        #expect(OllamaStatus.evaluate(installedModels: ["qwen3:8b"], model: "qwen3:8b").isReady)
    }

    @Test func givesTheCommandsToFinishSetup() {
        #expect(OllamaStatus.notRunning.setupCommands(model: "qwen3") == "brew install ollama\nbrew services start ollama\nollama pull qwen3")
        #expect(OllamaStatus.missingModel("qwen3").setupCommands(model: "qwen3") == "ollama pull qwen3")
        #expect(OllamaStatus.ready("qwen3").setupCommands(model: "qwen3") == nil)
    }
}
