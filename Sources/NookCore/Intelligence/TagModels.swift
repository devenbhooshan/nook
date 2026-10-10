import Foundation
import FoundationModels

/// A language model that can label mail. Every implementation in Nook runs on your Mac.
public protocol TagModel: Sendable {
    var displayName: String { get }
    func complete(system: String, prompt: String) async throws -> String
}

/// The model couldn't handle this particular message (for example, a safety refusal).
/// The tagger skips the message and moves on; any other error pauses tagging.
public struct TagModelSkip: Error, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public enum TagEngine: String, CaseIterable, Identifiable, Sendable {
    /// Ollama when it's running with the chosen model, otherwise Apple Intelligence.
    case automatic
    case ollama
    case apple
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .apple: "Apple Intelligence"
        case .ollama: "Ollama"
        case .off: "Off"
        }
    }
}

// MARK: - Apple Intelligence

/// Apple's on-device foundation model (macOS 26+).
public struct AppleTagModel: TagModel {
    public init() {}

    public var displayName: String { "Apple Intelligence" }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static var statusDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Ready. Runs entirely on this Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use it."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "The model is still downloading."
        case .unavailable:
            return "Unavailable."
        }
    }

    public func complete(system: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 60))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .exceededContextWindowSize, .unsupportedLanguageOrLocale, .refusal:
                throw TagModelSkip(reason: String(describing: error))
            default:
                throw error
            }
        }
    }
}

// MARK: - Ollama

/// Any model served by a local Ollama instance (https://ollama.com), including your own fine-tunes.
public struct OllamaTagModel: TagModel {
    public static let defaultURL = URL(string: "http://localhost:11434")!

    public var baseURL: URL
    public var model: String
    private let transport: HTTPTransport

    public init(baseURL: URL = OllamaTagModel.defaultURL, model: String, transport: HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    public var displayName: String { "Ollama · \(model)" }

    public func complete(system: String, prompt: String) async throws -> String {
        struct Response: Decodable { struct Message: Decodable { var content: String }; var message: Message }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": ["temperature": 0, "num_predict": 60],
        ] as [String: Any])

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw GmailError.http(status: response.statusCode, message: "Ollama: \(GmailClient.message(from: data))")
        }
        return try JSONDecoder().decode(Response.self, from: data).message.content
    }

    /// Names of the models installed in Ollama, or `nil` if it isn't running.
    public static func installedModels(baseURL: URL = defaultURL, transport: HTTPTransport = URLSession.shared) async -> [String]? {
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name).sorted()
    }
}

// MARK: - Settings

/// Tagging preferences, stored in `UserDefaults`.
public struct TaggingSettings: Sendable, Equatable {
    public static let engineKey = "tagging.engine"
    public static let ollamaURLKey = "tagging.ollamaURL"
    public static let ollamaModelKey = "tagging.ollamaModel"
    public static let defaultOllamaModel = "llama3.2"

    public var engine: TagEngine
    public var ollamaURL: URL
    public var ollamaModel: String

    public init(engine: TagEngine = .automatic, ollamaURL: URL = OllamaTagModel.defaultURL, ollamaModel: String = TaggingSettings.defaultOllamaModel) {
        self.engine = engine
        self.ollamaURL = ollamaURL
        self.ollamaModel = ollamaModel
    }

    public static func load(_ defaults: UserDefaults = .standard) -> TaggingSettings {
        TaggingSettings(
            engine: defaults.string(forKey: engineKey).flatMap(TagEngine.init(rawValue:)) ?? .automatic,
            ollamaURL: defaults.string(forKey: ollamaURLKey).flatMap(URL.init(string:)) ?? OllamaTagModel.defaultURL,
            ollamaModel: defaults.string(forKey: ollamaModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultOllamaModel
        )
    }

    /// Picks the model to use right now, or `nil` if none is reachable.
    public func resolveModel(
        appleAvailable: Bool = AppleTagModel.isAvailable,
        ollamaModels: @Sendable (URL) async -> [String]? = { await OllamaTagModel.installedModels(baseURL: $0) }
    ) async -> TagModel? {
        func ollama() async -> TagModel? {
            let status = OllamaStatus.evaluate(installedModels: await ollamaModels(ollamaURL), model: ollamaModel)
            return status.isReady ? OllamaTagModel(baseURL: ollamaURL, model: ollamaModel) : nil
        }
        switch engine {
        case .off: return nil
        case .apple: return appleAvailable ? AppleTagModel() : nil
        case .ollama: return await ollama()
        case .automatic:
            if let model = await ollama() { return model }
            return appleAvailable ? AppleTagModel() : nil
        }
    }
}

/// What it takes to get Ollama tagging, given what's installed.
public enum OllamaStatus: Equatable, Sendable {
    /// Not installed, or not running.
    case notRunning
    /// Running, but the chosen model hasn't been pulled.
    case missingModel(String)
    case ready(String)

    public static func evaluate(installedModels: [String]?, model: String) -> OllamaStatus {
        guard let installedModels else { return .notRunning }
        // Ollama accepts "llama3.2" for "llama3.2:latest".
        let installed = installedModels.contains(model) || installedModels.contains("\(model):latest")
        return installed ? .ready(model) : .missingModel(model)
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Terminal commands that finish the setup from here, using Homebrew.
    public func setupCommands(model: String) -> String? {
        switch self {
        case .notRunning:
            return "brew install ollama\nbrew services start ollama\nollama pull \(model)"
        case .missingModel(let missing):
            return "ollama pull \(missing)"
        case .ready:
            return nil
        }
    }
}
