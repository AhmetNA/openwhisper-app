import AppKit
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
            state.cloudPlanningClient = PlanClient(answer: #"{"version":2,"mode":"command","requestID":"77","steps":[{"kind":"command","source":"saat kaç","text":"saat kaç","send":false}]}"#)
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
            state.cloudPlanningClient = PlanClient(answer: #"{"version":2,"mode":"command","requestID":"77","steps":[{"kind":"command","source":"saat kaç","text":"saat kaç","send":false}]}"#, delay: .milliseconds(80))
            let old = session()
            let work = Task { await state.finishTranscription(old) }
            try await Task.sleep(for: .milliseconds(15))
            state.nextTranscriptionID = 78
            await work.value
            XCTAssertTrue(state.lastTranscription.isEmpty)
        }
    }
}

private final class CloudDeliveryRecorder: TextInjecting {
    var pasted: [String] = []
    var sends = 0
    var copied: String?
    func copyToClipboard(_ text: String) { copied = text }
    func pasteText(_ text: String, targetApp: NSRunningApplication?, onPasted: (() -> Void)?) { pasted.append(text); onPasted?() }
    func pasteTextResult(_ text: String, targetApp: NSRunningApplication?, context: PasteContext?, onOutcome: ((PasteOutcome) -> Void)?) {
        pasted.append(text)
        onOutcome?(.pastedVerified)
    }
    func replaceInjectedText(oldText: String, newText: String, targetApp: NSRunningApplication?, context: PasteContext?, onReplaced: (() -> Void)?) { onReplaced?() }
    @MainActor func pressReturnBringingToFront(pid: pid_t, context: PasteContext?) async -> Bool { sends += 1; return true }
    @MainActor func sendExistingMessage(context: PasteContext) -> Bool { sends += 1; return true }
}

extension CloudRoutingIntegrationTests {
    func testCloudDictationPastesAndOnlyExplicitSendSubmits() async throws {
        try await withCloud {
            let foreground = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
            for send in [false, true] {
                let recorder = CloudDeliveryRecorder()
                let state = AppState(textInjector: recorder)
                state.nextTranscriptionID = 90
                state.voiceRepliesEnabled = false
                state.autoPasteEnabled = true
                state.llmCleanupEnabled = true // Cloud-decided text must not be reclassified/rewritten.
                let body = "Bu fonksiyonu düzelt ve testleri çalıştır"
                let source = body + (send ? " sonra gönder" : "")
                let plan = CloudDecisionPlanner.Plan(version: 2, mode: .dictation, requestID: "90",
                    steps: [.init(kind: .dictation, source: source, text: body, send: send)])
                state.cloudPlanningClient = PlanClient(answer: String(decoding: try JSONEncoder().encode(plan), as: UTF8.self))
                let context = PasteContext(targetPID: foreground.processIdentifier, bundleIdentifier: "test.editor",
                    applicationName: "Test Editor", focusedElement: nil, focusStatus: .editable,
                    valueAtCapture: nil, selectedRangeAtCapture: nil, selectedTextAtCapture: nil)
                let capture = RecordingTranscriptionSession(id: 90, targetApp: foreground,
                    targetSpeakerEnabled: false, targetSpeakerProfile: nil, pasteContext: context)
                capture.trigger = .fnHold
                capture.isVoiceCommand = false
                capture.wakeSpeakerVerified = true
                capture.enqueue(.init(samples: Array(repeating: Float(0.1), count: 16_000), overlapSampleCount: 0))
                capture.segmentTexts = [source]
                capture.allSegmentTexts = [source]
                await state.finishTranscription(capture)
                XCTAssertEqual(recorder.pasted, [body], "outcome=\(capture.diagnosticOutcome.summary), message=\(state.flowBarMessage ?? "nil"), text=\(state.lastTranscription)")
                XCTAssertEqual(recorder.sends, send ? 1 : 0)
            }
        }
    }
}
