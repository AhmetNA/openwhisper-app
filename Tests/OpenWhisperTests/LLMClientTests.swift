import XCTest
@testable import OpenWhisper

/// Answers from a script and remembers what was asked; never touches the network.
private final class FakeLLMClient: LLMClient, @unchecked Sendable {
    var answer: Result<String, Error> = .success("")
    var models: [String] = []
    private(set) var requests: [LLMRequest] = []
    private(set) var chats: [LLMChatRequest] = []

    func generate(_ request: LLMRequest) async throws -> String {
        requests.append(request)
        return try answer.get()
    }

    func chat(_ request: LLMChatRequest) async throws -> String {
        chats.append(request)
        return try answer.get()
    }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        chats.append(request)
        let answer = self.answer
        return AsyncThrowingStream { continuation in
            switch answer {
            case .success(let text): continuation.yield(text); continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    func installedModels(timeout: TimeInterval) async throws -> [String] { models }
    func load(model: String, timeout: TimeInterval) async throws {}
    func unload(model: String, timeout: TimeInterval) async throws {}
}

final class LLMClientTests: XCTestCase {
    // MARK: - Wire format: the same bodies the call sites built by hand

    func testGenerateBodySendsOnlyWhatIsSet() {
        let body = OllamaClient.generateBody(LLMRequest(model: "m", prompt: "p", timeout: 4, temperature: 0, maxTokens: 40, stop: ["\n"]))
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["prompt"] as? String, "p")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, LLMCleanup.keepAlive)
        XCTAssertNil(body["format"])
        let options = body["options"] as? [String: Any]
        XCTAssertEqual(options?["num_predict"] as? Int, 40)
        XCTAssertEqual(options?["temperature"] as? Double, 0)
        XCTAssertEqual(options?["stop"] as? [String], ["\n"])
    }

    func testGenerateBodyWithSchemaAndNoStop() {
        let schema: [String: Any] = ["type": "object"]
        let body = OllamaClient.generateBody(LLMRequest(model: "m", prompt: "p", timeout: 3, temperature: 0, maxTokens: 100, schema: schema))
        XCTAssertEqual((body["format"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertNil((body["options"] as? [String: Any])?["stop"])
    }

    func testChatBodyStreams() {
        let request = LLMChatRequest(model: "m", messages: [["role": "user", "content": "selam"]], timeout: 10, temperature: 0.6, maxTokens: 110)
        XCTAssertEqual(OllamaClient.chatBody(request, stream: true)["stream"] as? Bool, true)
        XCTAssertEqual(OllamaClient.chatBody(request, stream: false)["stream"] as? Bool, false)
        XCTAssertEqual((OllamaClient.chatBody(request, stream: true)["messages"] as? [[String: String]])?.first?["content"], "selam")
    }

    // MARK: - Callers, against the fake

    func testRewriterAsksOnceAndReadsTheAnswer() async {
        let fake = FakeLLMClient()
        fake.answer = .success("\"Wi-Fi'yi aç\"\n")
        let line = await CommandRewriter.rewrite("internet gitti galiba", model: "m", client: fake)
        XCTAssertEqual(line, "Wi-Fi'yi aç")
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests.first?.maxTokens, 40)
        XCTAssertEqual(fake.requests.first?.timeout, 4)

        fake.answer = .success("YOK")
        let none = await CommandRewriter.rewrite("bugün hava güzel", model: "m", client: fake)
        XCTAssertNil(none)
    }

    func testFailuresBecomeNil() async {
        let fake = FakeLLMClient()
        fake.answer = .failure(LLMError.http(500))
        let rewrite = await CommandRewriter.rewrite("x", model: "m", client: fake)
        let spotify = await SpotifyRequestParser.queryOllama(transcript: "x", model: "m", client: fake)
        let translation = await ReplyTranslator.translate("Merhaba", model: "m", client: fake)
        XCTAssertNil(rewrite)
        XCTAssertNil(spotify)
        XCTAssertNil(translation)
    }

    func testCleanupKeepsTheTextWhenTheModelFails() async {
        let fake = FakeLLMClient()
        fake.answer = .failure(LLMError.http(404))
        let text = await LLMCleanup(model: "m", client: fake).cleanup(text: "bugün toplantı var")
        XCTAssertEqual(text, "bugün toplantı var")
        XCTAssertEqual(fake.requests.first?.timeout, 60)
        XCTAssertEqual(fake.requests.first?.stop, ["\n", "\n\n", "</think>", "Transcript:"])
    }

    func testInstalledModelMatchesLatest() async {
        let fake = FakeLLMClient()
        fake.models = ["gemma4:e4b-it-qat", "llama3:latest"]
        let exact = await LLMCleanup.isModelInstalled("gemma4:e4b-it-qat", client: fake)
        let latest = await LLMCleanup.isModelInstalled("llama3", client: fake)
        let missing = await LLMCleanup.isModelInstalled("qwen3.5:4b", client: fake)
        XCTAssertTrue(exact)
        XCTAssertTrue(latest)
        XCTAssertFalse(missing)
    }

    // MARK: - The real server

    /// `LIVE_OLLAMA=1 swift test --filter LLMClientTests`: one call of each kind to Ollama.
    func testLiveOllama() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_OLLAMA"] != nil, "set LIVE_OLLAMA=1 to call the local Ollama")
        let client = OllamaClient()
        let models = try await client.installedModels(timeout: 2)
        let model = models.contains(LLMCleanup.defaultModel) ? LLMCleanup.defaultModel : try XCTUnwrap(models.first)

        let schema: [String: Any] = [
            "type": "object", "properties": ["answer": ["type": "string"]],
            "required": ["answer"], "additionalProperties": false,
        ]
        let json = try await client.generate(LLMRequest(model: model, prompt: "Return {\"answer\": \"ok\"}.",
                                                        timeout: 60, temperature: 0, maxTokens: 20, schema: schema))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json)

        var pieces: [String] = []
        for try await piece in client.streamChat(LLMChatRequest(model: model, messages: [["role": "user", "content": "Say hi in one word."]],
                                                               timeout: 60, temperature: 0, maxTokens: 10)) {
            pieces.append(piece)
        }
        XCTAssertFalse(pieces.joined().isEmpty)
    }
}
