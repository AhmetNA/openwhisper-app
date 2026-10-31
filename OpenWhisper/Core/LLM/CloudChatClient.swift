import Foundation

/// Anything that streams one chat answer: Ollama, or the cloud model for Jarvis's free conversation.
protocol ChatStreaming: Sendable {
    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error>
}

extension OllamaClient: ChatStreaming {}

/// Any OpenAI-compatible service (`/chat/completions`, `/models`) at the address the user gave.
/// `JarvisChat` and the Spotify command parse use it; cleanup and other decisions stay local.
struct CloudChatClient: ChatStreaming {
    let baseURL: URL
    let apiKey: String
    /// Whether to send the thinking-off fields. Many open-weight servers think by default and
    /// then start 1–5 s later; strict servers reject the unknown fields (`CloudModelCheck`).
    var thinkingOff = true
    /// When set, the model may search the internet (`WebSearch`) once per reply. Only Jarvis's
    /// free conversation sets it.
    var webSearchKey: String?
    /// Told the query when a reply searched, so the history can keep it (`searchedKey`).
    var onSearch: (@Sendable (String) -> Void)?

    /// On a history reply that came from a search: its query. With search on, the reply goes
    /// out after its call (`withSearches`); without it, only the reply. Without the calls the
    /// model takes its earlier answers as known facts and answers the next result from memory.
    static let searchedKey = "searched"

    static func chatBody(_ request: LLMChatRequest, thinkingOff: Bool = true) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages,
            "stream": true,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens,
        ]
        if thinkingOff {
            body["chat_template_kwargs"] = ["enable_thinking": false, "thinking": false]
            body["reasoning_effort"] = "none"
        }
        return body
    }

    enum Line: Equatable {
        case piece(String)
        /// A part of the tool call: the first part has its id and name, the rest more arguments.
        case toolCall(id: String?, name: String?, arguments: String)
        case done
        case skip
    }

    /// One server-sent-events line. Reasoning text (`reasoning_content`) is never spoken.
    static func parse(line: String) -> Line {
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { return .skip }
        if let call = (delta["tool_calls"] as? [[String: Any]])?.first {
            let function = call["function"] as? [String: Any]
            return .toolCall(id: call["id"] as? String, name: function?["name"] as? String,
                             arguments: function?["arguments"] as? String ?? "")
        }
        guard let content = delta["content"] as? String, !content.isEmpty else { return .skip }
        return .piece(content)
    }

    /// The tool call of one answer, put together from its parts.
    struct ToolCall: Equatable {
        var id = ""
        var name = ""
        var arguments = ""

        var query: String? {
            (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])?["query"] as? String
        }
    }

    /// The messages after a search: the model's call and what the search found.
    static func messages(_ messages: [[String: Any]], after call: ToolCall, found: String) -> [[String: Any]] {
        messages + searchTurn(call, found: found)
    }

    private static func searchTurn(_ call: ToolCall, found: String) -> [[String: Any]] {
        [["role": "assistant", "content": "",
          "tool_calls": [["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]]],
         ["role": "tool", "tool_call_id": call.id, "content": found]]
    }

    /// The history as the server takes it: each searched reply after its call (`searchedKey`).
    /// Earlier results aren't sent again, only that there were some; they'd slow every reply.
    static func withSearches(_ messages: [[String: String]], tools: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (index, message) in messages.enumerated() {
            var plain = message
            if let query = plain.removeValue(forKey: searchedKey), tools {
                let arguments = (try? JSONSerialization.data(withJSONObject: ["query": query])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                out += searchTurn(ToolCall(id: "call_\(index)", name: WebSearch.toolName, arguments: arguments), found: "(arama sonuçları)")
            }
            out.append(plain)
        }
        return out
    }

    /// The model ids of a `/models` answer; nil when it isn't the OpenAI shape.
    static func modelIDs(from data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["id"] as? String }
    }

    /// Ids that are plainly not chat models (embeddings, OCR, speech…), left out of the picker.
    static func isLikelyChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let nonChat = ["embed", "rerank", "ocr", "asr", "whisper", "tts", "guard", "moderation", "image", "voxcpm", "transcribe"]
        return lower != "auto" && !nonChat.contains { lower.contains($0) }
    }

    func request(path: String, body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return urlRequest
    }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        var body = Self.chatBody(request, thinkingOff: thinkingOff)
        let messages = Self.withSearches(request.messages, tools: webSearchKey != nil)
        body["messages"] = messages
        if webSearchKey != nil { body["tools"] = [WebSearch.tool] }
        return AsyncThrowingStream { [body] continuation in
            let task = Task {
                do {
                    let call = try await stream(body: body, timeout: request.timeout, into: continuation)
                    // One search per reply. The follow-up goes without the tool: with it the
                    // model only asks to search again, and `tool_choice: none` answers empty.
                    if let webSearchKey, call.name == WebSearch.toolName {
                        let query = call.query ?? ""
                        let found: String
                        do {
                            found = try await WebSearch.search(query, key: webSearchKey)
                            owLog("[Chat] Web search '\(query)' → \(found.count) chars")
                            onSearch?(query)
                        } catch {
                            owLog("[Chat] Web search '\(query)' failed: \(ChatFallback.describe(error))")
                            found = "Arama yapılamadı."
                        }
                        var followUp = body
                        followUp["tools"] = nil
                        followUp["messages"] = Self.messages(messages, after: call, found: found)
                        _ = try await stream(body: followUp, timeout: request.timeout, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One answer, whole, to `messages` whose content may hold images (`image_url` parts).
    func complete(model: String, messages: [[String: Any]], timeout: TimeInterval, maxTokens: Int) async throws -> String {
        var body = Self.chatBody(LLMChatRequest(model: model, messages: [], timeout: timeout, temperature: 0, maxTokens: maxTokens),
                                 thinkingOff: thinkingOff)
        body["messages"] = messages
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    _ = try await self.stream(body: body, timeout: timeout, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var answer = ""
        for try await piece in stream { answer += piece }
        return answer
    }

    /// Streams one answer's text into `continuation` and returns its tool call, if any. The
    /// call's first part yields an empty piece, so `ChatFallback` keeps the reply on the cloud
    /// while the search runs.
    private func stream(body: [String: Any], timeout: TimeInterval,
                        into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> ToolCall {
        let (bytes, response) = try await URLSession.shared.bytes(for: request(path: "chat/completions", body: body, timeout: timeout))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LLMError.http(status) }
        var call = ToolCall()
        lines: for try await line in bytes.lines {
            switch Self.parse(line: line) {
            case .piece(let piece): continuation.yield(piece)
            case .toolCall(let id, let name, let arguments):
                if call.name.isEmpty, name != nil { continuation.yield("") }
                if let id { call.id = id }
                if let name { call.name = name }
                call.arguments += arguments
            case .done: break lines
            case .skip: continue
            }
        }
        return call
    }
}

/// The cloud first, the local model when the cloud is slow or failing. Ollama takes over when
/// the cloud errors or sends nothing within `deadline`; once the cloud's first piece is out it
/// keeps the reply, since Jarvis may already be speaking it.
enum ChatFallback {
    static let deadline: TimeInterval = 1.5
    /// When the cloud model can search (`WebSearch`). At 3 s a "who scored?" follow-up went to
    /// Ollama, which can't search and said it didn't know.
    static let searchDeadline: TimeInterval = 5

    /// `onFallback` gets the reason ("1500 ms without an answer", "HTTP 503") before Ollama starts.
    static func stream(primary: @escaping @Sendable () -> AsyncThrowingStream<String, Error>,
                       fallback: @escaping @Sendable () -> AsyncThrowingStream<String, Error>,
                       deadline: TimeInterval = deadline,
                       onFallback: @escaping @Sendable (String) -> Void) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let gate = Gate()
            let runFallback: @Sendable (String) -> Task<Void, Never> = { reason in
                Task {
                    onFallback(reason)
                    do {
                        for try await piece in fallback() { continuation.yield(piece) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            let primaryTask = Task {
                do {
                    for try await piece in primary() {
                        guard gate.claimPrimary() else { return }
                        continuation.yield(piece)
                    }
                    if gate.claimFallback() {
                        gate.hold(runFallback("empty answer"))
                    } else if gate.owner == .primary {
                        continuation.finish()
                    }
                } catch {
                    if gate.claimFallback() {
                        gate.hold(runFallback(describe(error)))
                    } else if gate.owner == .primary {
                        continuation.finish(throwing: error)
                    }
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(deadline))
                guard !Task.isCancelled, gate.claimFallback() else { return }
                primaryTask.cancel()
                gate.hold(runFallback("\(Int(deadline * 1000)) ms without an answer"))
            }
            continuation.onTermination = { _ in
                primaryTask.cancel()
                watchdog.cancel()
                gate.cancelHeld()
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if case LLMError.http(let status) = error { return "HTTP \(status)" }
        return error.localizedDescription
    }

    /// Who owns the reply, set once. The cloud keeps claiming it piece by piece; the fallback is
    /// claimed (and started) at most once, and only while nobody owns it.
    private final class Gate: @unchecked Sendable {
        enum Owner { case primary, fallback }
        private let lock = NSLock()
        private var _owner: Owner?
        private var held: Task<Void, Never>?

        var owner: Owner? { lock.withLock { _owner } }

        func claimPrimary() -> Bool {
            lock.withLock {
                if _owner == nil { _owner = .primary }
                return _owner == .primary
            }
        }

        func claimFallback() -> Bool {
            lock.withLock {
                guard _owner == nil else { return false }
                _owner = .fallback
                return true
            }
        }

        func hold(_ task: Task<Void, Never>) { lock.withLock { held = task } }
        func cancelHeld() { lock.withLock { held }?.cancel() }
    }
}

/// What Settings checks before a model answers Jarvis: one tiny chat, timed to its first word.
enum CloudModelCheck {
    enum Outcome: Equatable {
        /// Works; `thinkingOff` says whether the thinking-off fields were accepted.
        case ok(firstWordMs: Int, thinkingOff: Bool)
        /// Works but starts after the fallback deadline, so Ollama would answer instead.
        case slow(firstWordMs: Int, thinkingOff: Bool)
        case rejected(String)
        case empty
    }

    static func run(_ client: CloudChatClient, model: String) async -> Outcome {
        let first = await attempt(client, model: model)
        // A strict server rejects the unknown thinking fields; try once without them.
        if case .rejected = first {
            var plain = client
            plain.thinkingOff = false
            let second = await attempt(plain, model: model)
            if case .rejected = second { return first }
            return second
        }
        return first
    }

    private static func attempt(_ client: CloudChatClient, model: String) async -> Outcome {
        let request = LLMChatRequest(model: model, messages: [["role": "user", "content": "Merhaba, tek kelimeyle cevap ver."]],
                                     timeout: 15, temperature: 0, maxTokens: 16)
        let started = Date()
        do {
            for try await _ in client.streamChat(request) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                return Double(ms) / 1000 > ChatFallback.deadline
                    ? .slow(firstWordMs: ms, thinkingOff: client.thinkingOff)
                    : .ok(firstWordMs: ms, thinkingOff: client.thinkingOff)
            }
            return .empty
        } catch {
            return .rejected(ChatFallback.describe(error))
        }
    }
}
