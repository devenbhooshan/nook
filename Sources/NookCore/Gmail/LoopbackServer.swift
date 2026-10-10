import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
/// It only listens on the loopback interface and shuts down after the first real callback.
final class LoopbackServer: @unchecked Sendable {
    /// The `state` this sign-in sent to Google. Callbacks carrying anything else are answered and ignored, so another
    /// program (or a web page that finds the port) can't end the sign-in early with a fake or failing callback.
    private let expectedState: String?
    private let queue = DispatchQueue(label: "com.devenbhooshan.nook.oauth-loopback")
    private var listener: NWListener?
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    /// Confined to `queue`: whether `start()` has already reported readiness or failure.
    private var startReported = false

    init(expectedState: String? = nil) {
        self.expectedState = expectedState
    }

    /// Starts listening on a random free port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // State updates arrive on `queue`, so `startReported` needs no extra locking.
            listener.stateUpdateHandler = { [self] state in
                guard !startReported else { return }
                switch state {
                case .ready:
                    startReported = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    startReported = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to hit the redirect URI and returns its query parameters.
    func waitForCallback(timeout: Duration) async throws -> [String: String] {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(OAuthError.denied("timed out")))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = result
            self.waiter?.resume(with: result)
            self.waiter = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let parameters = Self.callbackParameters(fromRequest: request)
            let isCallback = parameters?["code"] != nil || parameters?["error"] != nil
            let isOurs = isCallback && (self?.expectedState == nil || parameters?["state"] == self?.expectedState)

            let response = isOurs
                ? Self.response(status: "200 OK", body: Self.successPage)
                : Self.response(status: isCallback ? "400 Bad Request" : "404 Not Found", body: "")
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            if isOurs, let parameters { self?.finish(.success(parameters)) }
        }
    }

    /// Parses `GET /?code=...&state=... HTTP/1.1` into its query parameters.
    static func callbackParameters(fromRequest request: String) -> [String: String]? {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        return parameters
    }

    private static func response(status: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Nook</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 15px -apple-system, sans-serif; display: grid; place-items: center; height: 100vh; margin: 0; }
      div { text-align: center; } h1 { font-weight: 600; font-size: 22px; margin: 0 0 8px; } p { opacity: .6; margin: 0; }
    </style></head>
    <body><div><h1>You're signed in to Nook</h1><p>You can close this tab and go back to the app.</p></div></body></html>
    """
}
