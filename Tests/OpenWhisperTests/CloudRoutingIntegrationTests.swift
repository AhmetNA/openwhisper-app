import XCTest
@testable import OpenWhisper

private struct PlanClient: LLMClient {
    var answer: String
    var delay: Duration = .zero
    func generate(_ request: LLMRequest) async throws -> String {
        try await Task.sleep(for: delay)
        return answer
    }
    func chat(_ request: LLMChatRequest) async throws -> String { throw LLMError.malformed }
    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.malformed) }
    }
    func installedModels(timeout: TimeInterval) async throws -> [String] { [] }
    func load(model: String, timeout: TimeInterval) async throws {}
    func unload(model: String, timeout: TimeInterval) async throws {}
}

@MainActor
final class CloudRoutingIntegrationTests: XCTestCase {
    func withCloud(_ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.object(forKey: SetFitDecider.defaultsKey)
        UserDefaults.standard.set("cloud", forKey: SetFitDecider.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: SetFitDecider.defaultsKey) }
        try await body()
    }
    func session(id: UInt64 = 77) -> RecordingTranscriptionSession {
        let session = RecordingTranscriptionSession(id: id, targetApp: nil,
            targetSpeakerEnabled: false, targetSpeakerProfile: nil)
        session.trigger = .typed
        session.isVoiceCommand = true
        session.wakeSpeakerVerified = true
        session.segmentTexts = ["saat kaç"]
        session.allSegmentTexts = session.segmentTexts
        return session
    }
    func testValidatedCloudPlanReachesNativeExecutor() async throws {
        try await withCloud {
            let state = AppState()
            state.nextTranscriptionID = 77
            state.voiceRepliesEnabled = false
            state.cloudPlanningClient = PlanClient(answer: #"{"version":1,"requestID":"77","steps":[{"kind":"command","source":"saat kaç","text":"saat kaç"}]}"#)
            await state.finishTranscription(session())
            XCTAssertEqual(state.lastTranscription, "saat kaç")
            XCTAssertTrue(state.flowBarMessage?.contains(":") == true)
        }
    }
    func testInvalidCloudResponseDoesNotExecuteOrDictate() async throws {
        try await withCloud {
            let state = AppState()
            state.nextTranscriptionID = 77
            state.voiceRepliesEnabled = false
            state.cloudPlanningClient = PlanClient(answer: "not json")
            await state.finishTranscription(session())
            XCTAssertTrue(state.lastTranscription.isEmpty)
            XCTAssertTrue(state.flowBarMessage?.contains("işlem yapmadım") == true)
        }
    }
    func testOlderCloudResponseCannotActAfterNewCapture() async throws {
        try await withCloud {
            let state = AppState()
            state.nextTranscriptionID = 77
            state.voiceRepliesEnabled = false
            state.cloudPlanningClient = PlanClient(answer: #"{"version":1,"requestID":"77","steps":[{"kind":"command","source":"saat kaç","text":"saat kaç"}]}"#, delay: .milliseconds(80))
            let old = session()
            let work = Task { await state.finishTranscription(old) }
            try await Task.sleep(for: .milliseconds(15))
            state.nextTranscriptionID = 78
            await work.value
            XCTAssertTrue(state.lastTranscription.isEmpty)
        }
    }
}
