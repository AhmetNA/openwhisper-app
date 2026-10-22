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
        case done
        case skip
    }

    /// One server-sent-events line. Reasoning text (`reasoning_content`) is never spoken.
    static func parse(line: String) -> Line {
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return .skip }
        return .piece(content)
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
        let urlRequest = Result {
            try self.request(path: "chat/completions", body: Self.chatBody(request, thinkingOff: thinkingOff),
                             timeout: request.timeout)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try urlRequest.get())
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard status == 200 else { throw LLMError.http(status) }
                    lines: for try await line in bytes.lines {
                        switch Self.parse(line: line) {
                        case .piece(let piece): continuation.yield(piece)
                        case .done: break lines
                        case .skip: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The cloud first, the local model when the cloud is slow or failing. Ollama takes over when
/// the cloud errors or sends nothing within `deadline`; once the cloud's first piece is out it
/// keeps the reply, since Jarvis may already be speaking it.
enum ChatFallback {
    static let deadline: TimeInterval = 1.5

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
