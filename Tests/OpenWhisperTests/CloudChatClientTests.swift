import XCTest
@testable import OpenWhisper

final class CloudChatClientTests: XCTestCase {
    // MARK: - Wire format

    func testChatBodyStreamsWithThinkingOff() {
        let request = LLMChatRequest(model: "qwen3.8-flash-next", messages: [["role": "user", "content": "selam"]],
                                     timeout: 10, temperature: 0.6, maxTokens: 110)
        let body = CloudChatClient.chatBody(request)
        XCTAssertEqual(body["model"] as? String, "qwen3.8-flash-next")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 110)
        XCTAssertEqual(body["temperature"] as? Double, 0.6)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "selam")
    }

    func testParseKeepsContentAndDropsReasoning() {
        XCTAssertEqual(CloudChatClient.parse(line: #"data: {"choices":[{"delta":{"content":"Merhaba"}}]}"#), .piece("Merhaba"))
        XCTAssertEqual(CloudChatClient.parse(line: #"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#), .skip)
        XCTAssertEqual(CloudChatClient.parse(line: #"data: {"choices":[]}"#), .skip)
        XCTAssertEqual(CloudChatClient.parse(line: "data: [DONE]"), .done)
        XCTAssertEqual(CloudChatClient.parse(line: ": keep-alive"), .skip)
    }

    // MARK: - Fallback

    private static func pieces(_ items: [String], thenThrow error: Error? = nil,
                               after delay: Duration? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let delay { try? await Task.sleep(for: delay) }
                for item in items { continuation.yield(item) }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func neverAnswers() -> AsyncThrowingStream<String, Error> {
        pieces([], after: .seconds(30))
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async -> (text: String, failed: Bool) {
        var text = ""
        do {
            for try await piece in stream { text += piece }
            return (text, false)
        } catch {
            return (text, true)
        }
    }

    private final class Reasons: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ reason: String) { lock.withLock { items.append(reason) } }
        var all: [String] { lock.withLock { items } }
    }

    func testPrimaryAnswerIsKept() async {
        let reasons = Reasons()
        let result = await collect(ChatFallback.stream(
            primary: { Self.pieces(["Kara delik ", "çok yoğun."]) },
            fallback: { Self.pieces(["yerel"]) },
            deadline: 1, onFallback: reasons.add))
        XCTAssertEqual(result.text, "Kara delik çok yoğun.")
        XCTAssertFalse(result.failed)
        XCTAssertEqual(reasons.all, [])
    }

    func testSilentPrimaryFallsBackAtTheDeadline() async {
        let reasons = Reasons()
        let started = Date()
        let result = await collect(ChatFallback.stream(
            primary: Self.neverAnswers,
            fallback: { Self.pieces(["yerel cevap"]) },
            deadline: 0.1, onFallback: reasons.add))
        XCTAssertEqual(result.text, "yerel cevap")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(reasons.all, ["100 ms without an answer"])
    }

    func testFailingPrimaryFallsBackRightAway() async {
        let reasons = Reasons()
        let result = await collect(ChatFallback.stream(
            primary: { Self.pieces([], thenThrow: LLMError.http(503)) },
            fallback: { Self.pieces(["yerel cevap"]) },
            deadline: 5, onFallback: reasons.add))
        XCTAssertEqual(result.text, "yerel cevap")
        XCTAssertEqual(reasons.all, ["HTTP 503"])
    }

    func testEmptyPrimaryFallsBack() async {
        let reasons = Reasons()
        let result = await collect(ChatFallback.stream(
            primary: { Self.pieces([]) },
            fallback: { Self.pieces(["yerel cevap"]) },
            deadline: 5, onFallback: reasons.add))
        XCTAssertEqual(result.text, "yerel cevap")
        XCTAssertEqual(reasons.all, ["empty answer"])
    }

    /// Jarvis may already be speaking the first half: no second answer after it.
    func testPrimaryFailingMidReplyDoesNotSwitch() async {
        let reasons = Reasons()
        let result = await collect(ChatFallback.stream(
            primary: { Self.pieces(["Yarım cevap."], thenThrow: LLMError.http(500)) },
            fallback: { Self.pieces(["yerel cevap"]) },
            deadline: 5, onFallback: reasons.add))
        XCTAssertEqual(result.text, "Yarım cevap.")
        XCTAssertTrue(result.failed)
        XCTAssertEqual(reasons.all, [])
    }

    func testChatBodyCanLeaveThinkingFieldsOut() {
        let request = LLMChatRequest(model: "m", messages: [], timeout: 10, temperature: 0.6, maxTokens: 110)
        let body = CloudChatClient.chatBody(request, thinkingOff: false)
        XCTAssertNil(body["chat_template_kwargs"])
        XCTAssertNil(body["reasoning_effort"])
    }

    // MARK: - Model list

    func testModelIDsNeedTheOpenAIShape() {
        XCTAssertEqual(CloudChatClient.modelIDs(from: Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)), ["a", "b"])
        XCTAssertNil(CloudChatClient.modelIDs(from: Data(#"{"models":[{"name":"a"}]}"#.utf8)))
        XCTAssertNil(CloudChatClient.modelIDs(from: Data("<html>".utf8)))
    }

    func testPickerLeavesOutPlainlyNonChatModels() {
        for chat in ["qwen3.8-flash-next", "deepseek-v4.1-flash", "gpt-5-mini", "qwen3-vl-30b"] {
            XCTAssertTrue(CloudChatClient.isLikelyChatModel(chat), chat)
        }
        for other in ["auto", "qwen3-embedding-8b", "qwen3-reranker-8b", "dots-ocr", "qwen3-asr-1.7b", "voxcpm2", "whisper-1"] {
            XCTAssertFalse(CloudChatClient.isLikelyChatModel(other), other)
        }
    }

    // MARK: - Format checks

    func testAddressIsNormalised() {
        XCTAssertEqual(try? CloudLLM.normalize(" https://api.example.com/v1/ ").get().absoluteString, "https://api.example.com/v1")
        XCTAssertEqual(try? CloudLLM.normalize("https://api.example.com/v1/chat/completions").get().absoluteString,
                       "https://api.example.com/v1")
        XCTAssertEqual(try? CloudLLM.normalize("http://localhost:8080/v1").get().absoluteString, "http://localhost:8080/v1")
    }

    func testBadAddressesAreRefused() {
        XCTAssertEqual(CloudLLM.normalize("http://api.example.com/v1"), .failure(.notHTTPS))
        XCTAssertEqual(CloudLLM.normalize("api anahtarım"), .failure(.notAURL))
        XCTAssertEqual(CloudLLM.normalize(""), .failure(.notAURL))
    }

    func testKeyFormat() {
        XCTAssertEqual(APIKeys.cloudLLM.check(key: "sk_live_0123456789abcdef"), .ok)
        if case .invalid = APIKeys.cloudLLM.check(key: "abc def ghi jkl mno pqr") {} else { XCTFail("space") }
        if case .invalid = APIKeys.cloudLLM.check(key: "short") {} else { XCTFail("short") }
        if case .warning = APIKeys.gemini.check(key: "sk_0123456789abcdefghij") {} else { XCTFail("prefix") }
        XCTAssertEqual(APIKeys.gemini.check(key: "AIzaSyD0123456789abcdefghijklmnopqrstu"), .ok)
    }
}
