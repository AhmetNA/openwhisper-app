import XCTest
@testable import OpenWhisper

private final class SearchTestLLM: LLMClient, @unchecked Sendable {
    var plan = #"{"query":"2026 Dünya Kupası şampiyonu"}"#
    var requests: [LLMChatRequest] = []
    func generate(_ request: LLMRequest) async throws -> String { plan }
    func chat(_ request: LLMChatRequest) async throws -> String { "" }
    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        return AsyncThrowingStream { $0.yield("Yanıt."); $0.finish() }
    }
    func installedModels(timeout: TimeInterval) async throws -> [String] { [] }
    func load(model: String, timeout: TimeInterval) async throws {}
    func unload(model: String, timeout: TimeInterval) async throws {}
}

final class LocalSearchChatClientTests: XCTestCase {
    private var request: LLMChatRequest {
        LLMChatRequest(model: "local", messages: [["role": "system", "content": "Private screen context"],
            ["role": "user", "content": "2026 Dünya Kupası'nı kim kazandı?"]], timeout: 10, temperature: 0.6, maxTokens: 110)
    }
    private func collect(_ client: LocalSearchChatClient) async throws -> String {
        var output = ""
        for try await piece in client.streamChat(request) { output += piece }
        return output
    }
    func testSearchEvidenceReachesLocalModel() async throws {
        let llm = SearchTestLLM()
        let client = LocalSearchChatClient(client: llm, key: "test", search: { query, key in
            XCTAssertEqual(query, "2026 Dünya Kupası şampiyonu")
            XCTAssertEqual(key, "test")
            return "Verified test evidence"
        })
        let output = try await collect(client)
        XCTAssertEqual(output, "Yanıt.")
        XCTAssertTrue(llm.requests[0].messages.last!["content"]!.contains("Verified test evidence"))
        XCTAssertEqual(llm.requests[0].temperature, 0)
    }
    func testSearchFailureDoesNotGenerateUngroundedAnswer() async throws {
        let llm = SearchTestLLM()
        let client = LocalSearchChatClient(client: llm, key: "test", search: { _, _ in throw LLMError.http(401) })
        let output = try await collect(client)
        XCTAssertTrue(output.contains("doğrulayamıyorum"))
        XCTAssertTrue(llm.requests.isEmpty)
    }
    func testNoKeySkipsSearch() async throws {
        let llm = SearchTestLLM()
        let client = LocalSearchChatClient(client: llm, key: nil, search: { _, _ in XCTFail("Unexpected search"); return "" })
        _ = try await collect(client)
        XCTAssertEqual(llm.requests[0].messages, request.messages)
    }
    func testGreetingDoesNotSearch() async throws {
        let llm = SearchTestLLM()
        llm.plan = #"{"query":""}"#
        let client = LocalSearchChatClient(client: llm, key: "test", search: { _, _ in XCTFail("Unexpected search"); return "" })
        _ = try await collect(client)
        XCTAssertTrue(llm.requests[0].messages.last!["content"]!.contains("yapılmadı"))
    }
    func testMalformedPlanDoesNotAnswerFromMemory() async throws {
        let llm = SearchTestLLM()
        llm.plan = "Not JSON"
        let output = try await collect(LocalSearchChatClient(client: llm, key: "test"))
        XCTAssertTrue(output.contains("doğrulayamıyorum"))
        XCTAssertTrue(llm.requests.isEmpty)
    }
    func testPlannerExcludesPrivateSystemContext() {
        let prompt = LocalSearchChatClient.planRequest(request).prompt
        XCTAssertFalse(prompt.contains("Private screen context"))
        XCTAssertTrue(prompt.contains("2026 Dünya Kupası"))
    }

    // Explicit opt-in only: exercises the selected local model and the saved Exa key.
    @MainActor func testLiveLocalSearch() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_SEARCH_TEST"] == "1" else { throw XCTSkip("Live search is opt-in") }
        let key = try XCTUnwrap(APIKeys.exa.key())
        var live = request
        live.model = LLM.selectedModel
        live.messages[0]["content"] = JarvisChat.systemPrompt(now: Date(), canSearch: true)
        let receipt = JarvisChat.Backend()
        var output = ""
        for try await piece in LocalSearchChatClient(client: LLM.default, key: key, onSearch: { receipt.searched = $0 }).streamChat(live) { output += piece }
        XCTAssertNotNil(receipt.searched, "Live answer must actually use Exa")
        print("LIVE LOCAL SEARCH ANSWER: \(output)")
        XCTAssertFalse(output.isEmpty)
        XCTAssertFalse(output.contains("henüz oynanmadı"))
    }
}
