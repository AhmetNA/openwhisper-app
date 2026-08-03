import XCTest
@testable import OpenWhisper

@MainActor
final class AppStateTargetSpeakerIntegrationTests: XCTestCase {
    func testEnrollmentCanRetryFromStepZeroAndDeleteResetsWizardState() throws {
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(),
            transcriptionService: RecordingWhisperService()
        )
        appState.beginTargetSpeakerEnrollment()
        XCTAssertTrue(appState.targetSpeakerEnrollmentActive)
        XCTAssertEqual(appState.targetSpeakerEnrollmentStep, 0)
        XCTAssertFalse(appState.targetSpeakerEnrollmentPrompt.isEmpty)

        appState.targetSpeakerEnrollmentStep = 1
        appState.targetSpeakerPreparationProgress = 0.8
        appState.targetSpeakerPreparationMessage = "preparing"
        appState.deleteTargetSpeakerProfile()

        XCTAssertFalse(appState.targetSpeakerEnrollmentActive)
        XCTAssertEqual(appState.targetSpeakerEnrollmentStep, 0)
        XCTAssertNil(appState.targetSpeakerPreparationProgress)
        XCTAssertEqual(appState.targetSpeakerPreparationMessage, "")
    }

    func testNewRecordingClearsStaleNoMatchMessage() {
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(),
            transcriptionService: RecordingWhisperService()
        )
        appState.flowBarMessage = "Ses eşleşmedi"
        appState.modelLoaded = false
        appState.startRecording()
        XCTAssertNil(appState.flowBarMessage)
    }

    func testFeatureOffPassesOriginalOverlapMetadataToWhisperService() async throws {
        let whisper = RecordingWhisperService()
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(),
            transcriptionService: whisper
        )
        let session = RecordingTranscriptionSession(
            id: 1,
            targetApp: nil,
            targetSpeakerEnabled: false,
            targetSpeakerProfile: nil
        )
        let segment = CompletedAudioSegment(samples: [0.1, 0.2, 0.3], overlapSampleCount: 2)
        session.enqueue(segment)

        await appState.transcribeStreamingSegment(segment, session: session)

        XCTAssertEqual(whisper.requests.count, 1)
        XCTAssertEqual(whisper.requests[0].samples, segment.samples)
        XCTAssertEqual(whisper.requests[0].overlapSampleCount, segment.overlapSampleCount)
    }

    func testNoMatchStopsAtSessionBoundaryBeforeWhisperOrPostProcessing() async throws {
        let whisper = RecordingWhisperService()
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: [false, false, false, false, false, false, false, false]),
            transcriptionService: whisper
        )
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[1] + [Float](repeating: 0, count: 255)]
        )
        let session = RecordingTranscriptionSession(
            id: 2,
            targetApp: nil,
            targetSpeakerEnabled: true,
            targetSpeakerProfile: profile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000),
            overlapSampleCount: 1
        )
        session.enqueue(segment)

        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(whisper.requests.isEmpty)
        XCTAssertEqual(appState.lastTranscription, "")
        XCTAssertEqual(appState.flowBarMessage, "Ses eşleşmedi")
    }

    func testCancelWhileEnrollmentProcessingInvalidatesLaterStateAndStoreSave() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let model = BlockingEnrollmentModel()
        let appState = AppState(profileStore: store, targetSpeakerModel: model)
        appState.beginTargetSpeakerEnrollment()

        model.blockNextPreparation()
        appState.processTargetSpeakerEnrollmentSamples(validEnrollmentSamples())
        try await waitUntil { appState.targetSpeakerEnrollmentIsProcessing }
        appState.cancelTargetSpeakerEnrollment()
        model.releasePreparation()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(appState.targetSpeakerEnrollmentActive)
        XCTAssertFalse(appState.targetSpeakerEnrollmentIsProcessing)
        XCTAssertNil(try store.load())
    }

    func testDeleteDuringEnrollmentRecordingResetsAudioTeardownState() throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let appState = AppState(profileStore: store, targetSpeakerModel: IntegrationSpeakerModel())
        appState.targetSpeakerEnrollmentActive = true
        appState.targetSpeakerEnrollmentIsRecording = true
        appState.recordingState = .recording
        appState.recordingDuration = 4
        appState.audioLevel = 0.8

        appState.deleteTargetSpeakerProfile()

        XCTAssertFalse(appState.targetSpeakerEnrollmentIsRecording)
        XCTAssertEqual(appState.recordingState, .idle)
        XCTAssertEqual(appState.recordingDuration, 0)
        XCTAssertEqual(appState.audioLevel, 0)
        XCTAssertFalse(appState.targetSpeakerEnrollmentActive)
    }

    func testIncompatibleStoredProfileIsNotToggleEligibleButRemainsManageable() throws {
        let store = InMemoryTargetSpeakerProfileStore()
        try store.save(try TargetSpeakerProfile(
            modelIdentifier: "FluidAudio-Diarizer-old",
            embeddings: [[1] + [Float](repeating: 0, count: 255)]
        ))
        let appState = AppState(profileStore: store, targetSpeakerModel: IntegrationSpeakerModel())
        appState.targetSpeakerEnabled = true
        appState.loadTargetSpeakerProfile()

        XCTAssertFalse(appState.hasTargetSpeakerProfile)
        XCTAssertTrue(appState.hasStoredTargetSpeakerProfile)
        XCTAssertFalse(appState.targetSpeakerEnabled)
    }

    private func validEnrollmentSamples() -> [Float] {
        Array(repeating: Float(0.2), count: 24 * TargetSpeakerFilterConfiguration.vadFrameSamples)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for enrollment state")
    }
}

private final class RecordingWhisperService: WhisperTranscriptionService, @unchecked Sendable {
    struct Request: Sendable {
        let samples: [Float]
        let overlapSampleCount: Int
    }

    private(set) var requests: [Request] = []

    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String {
        requests.append(Request(samples: audioData, overlapSampleCount: overlapSampleCount))
        return "test transcript"
    }
}

private final class IntegrationSpeakerModel: TargetSpeakerModelProvider, @unchecked Sendable {
    let modelIdentifier = FluidAudioTargetSpeakerModel.identifier
    private let voiceFrames: [Bool]

    init(voiceFrames: [Bool] = Array(repeating: true, count: 8)) {
        self.voiceFrames = voiceFrames
    }

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {}

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        voiceFrames.map { TargetSpeakerVADFrame(isVoiceActive: $0, probability: $0 ? 1 : 0) }
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        [1] + [Float](repeating: 0, count: 255)
    }
}

private final class BlockingEnrollmentModel: TargetSpeakerModelProvider, @unchecked Sendable {
    let modelIdentifier = FluidAudioTargetSpeakerModel.identifier
    private let lock = NSLock()
    private var shouldBlock = false
    private var released = false

    func blockNextPreparation() {
        lock.lock()
        shouldBlock = true
        released = false
        lock.unlock()
    }

    func releasePreparation() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {
        lock.lock()
        let block = shouldBlock
        shouldBlock = false
        lock.unlock()
        guard block else { return }

        while true {
            lock.lock()
            let isReleased = released
            lock.unlock()
            if isReleased { return }
            await Task.yield()
        }
    }

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        Array(repeating: TargetSpeakerVADFrame(isVoiceActive: true, probability: 1), count: 24)
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        [1] + [Float](repeating: 0, count: 255)
    }
}
