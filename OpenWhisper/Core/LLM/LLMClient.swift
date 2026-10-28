import Foundation

/// One completion from the local model: the prompt and the exact options a caller wants.
/// Only what is set here is sent, so each call keeps its own timeout, budget and stops.
struct LLMRequest: @unchecked Sendable {
    var model: String
    var prompt: String
    var timeout: TimeInterval
    var temperature: Double
    /// Ollama's `num_predict`.
    var maxTokens: Int
    var stop: [String]?
    /// A JSON schema for Ollama's `format`: the answer then follows it.
    var schema: [String: Any]?
    /// The file that built the request, logged so the feature that loaded the model shows.
    var caller: String

    init(model: String, prompt: String, timeout: TimeInterval, temperature: Double, maxTokens: Int,
         stop: [String]? = nil, schema: [String: Any]? = nil, caller: String = #fileID) {
        self.model = model
        self.prompt = prompt
        self.timeout = timeout
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stop = stop
        self.schema = schema
        self.caller = caller
    }
}

/// A conversation turn list for `/api/chat`.
struct LLMChatRequest: Sendable {
    var model: String
    var messages: [[String: String]]
    var timeout: TimeInterval
    var temperature: Double
    var maxTokens: Int
    var caller: String

    init(model: String, messages: [[String: String]], timeout: TimeInterval, temperature: Double,
         maxTokens: Int, caller: String = #fileID) {
        self.model = model
        self.messages = messages
        self.timeout = timeout
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.caller = caller
    }
}

enum LLMError: Error, Equatable {
    /// The server answered with another status than 200 (-1: not an HTTP answer).
    case http(Int)
    /// 200, but not the JSON shape Ollama sends.
    case malformed
}

/// Everything Jarvis asks the local language model goes through this, so the server, the
/// wire format and a test fake live in one place. Errors are thrown, not swallowed: callers
/// log the status, and tell a cancelled request (SetFit answered first) from a failed one.
protocol LLMClient: Sendable {
    /// The `response` text of one `/api/generate` call.
    func generate(_ request: LLMRequest) async throws -> String
    /// The answer of one `/api/chat` call, at once.
    func chat(_ request: LLMChatRequest) async throws -> String
    /// The answer of one `/api/chat` call, piece by piece; cancelling the consumer cancels it.
    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error>
    /// Names of the installed models (`/api/tags`), e.g. "gemma4:e4b-it-qat".
    func installedModels(timeout: TimeInterval) async throws -> [String]
    /// Loads `model` into memory without generating anything.
    func load(model: String, timeout: TimeInterval) async throws
    /// Drops `model` from memory right away.
    func unload(model: String, timeout: TimeInterval) async throws
}

enum LLM {
    /// The local Ollama server.
    static let `default`: any LLMClient = OllamaClient()

    /// The model picked in Settings, for callers that have no `AppState` at hand.
    static var selectedModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
    }
}

/// Ollama on localhost. Bodies are built by pure functions, so tests check the wire format.
struct OllamaClient: LLMClient {
    var baseURL = URL(string: "http://localhost:11434")!

    static func generateBody(_ request: LLMRequest) -> [String: Any] {
        var options: [String: Any] = ["temperature": request.temperature, "num_predict": request.maxTokens]
        if let stop = request.stop { options["stop"] = stop }
        var body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
            "stream": false,
            // Qwen 3.5 / Gemma 4 think by default: the answer then arrives only after a long
            // hidden reasoning pass, or the num_predict budget runs out inside it.
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "options": options,
        ]
        if let schema = request.schema { body["format"] = schema }
        return body
    }

    static func chatBody(_ request: LLMChatRequest, stream: Bool) -> [String: Any] {
        [
            "model": request.model,
            "messages": request.messages,
            "stream": stream,
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "options": ["temperature": request.temperature, "num_predict": request.maxTokens],
        ]
    }

    func generate(_ request: LLMRequest) async throws -> String {
        owLog("[Ollama] generate \(request.model) from \(request.caller)")
        let json = try await post("api/generate", Self.generateBody(request), timeout: request.timeout)
        guard let response = json["response"] as? String else { throw LLMError.malformed }
        return response
    }

    func chat(_ request: LLMChatRequest) async throws -> String {
        owLog("[Ollama] chat \(request.model) from \(request.caller)")
        let json = try await post("api/chat", Self.chatBody(request, stream: false), timeout: request.timeout)
        guard let content = (json["message"] as? [String: Any])?["content"] as? String else { throw LLMError.malformed }
        return content
    }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        owLog("[Ollama] streamChat \(request.model) from \(request.caller)")
        let urlRequest = Self.urlRequest(baseURL.appendingPathComponent("api/chat"), timeout: request.timeout,
                                         body: Self.chatBody(request, stream: true))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try urlRequest.get())
                    try Self.check(response)
                    for try await line in bytes.lines {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        if let piece = (json["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func installedModels(timeout: TimeInterval) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw LLMError.malformed }
        return models.compactMap { $0["name"] as? String }
    }

    func load(model: String, timeout: TimeInterval) async throws {
        // An empty prompt makes Ollama load the model without generating.
        _ = try await post("api/generate", ["model": model, "prompt": "", "keep_alive": LLMCleanup.keepAlive],
                           timeout: timeout, decode: false)
    }

    func unload(model: String, timeout: TimeInterval) async throws {
        _ = try await post("api/generate", ["model": model, "keep_alive": 0], timeout: timeout, decode: false)
    }

    // MARK: - HTTP

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval,
                      decode: Bool = true) async throws -> [String: Any] {
        let request = try Self.urlRequest(baseURL.appendingPathComponent(path), timeout: timeout, body: body).get()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard decode else { return [:] }
        try Self.check(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed }
        return json
    }

    private static func urlRequest(_ url: URL, timeout: TimeInterval, body: [String: Any]) -> Result<URLRequest, Error> {
        Result {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LLMError.http(status) }
    }
}
