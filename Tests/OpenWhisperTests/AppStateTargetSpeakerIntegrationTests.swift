import AppKit
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

    /// Requirement A: a fail-closed gate (here, no profile at all) must not cost the user their
    /// dictation. Whisper must still run on the *original* samples and the result must take the
    /// completely normal paste path -- not the below-threshold clipboard fallback.
    func testFailClosedGateTranscribesOriginalAudioAndTakesNormalPastePath() async throws {
        let whisper = RecordingWhisperService()
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(),
            transcriptionService: whisper
        )
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false
        let session = RecordingTranscriptionSession(
            id: 3,
            targetApp: nil,
            targetSpeakerEnabled: true,
            targetSpeakerProfile: nil // triggers the "no profile" fail-closed path
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000),
            overlapSampleCount: 1
        )
        session.enqueue(segment)

        await appState.transcribeStreamingSegment(segment, session: session)

        XCTAssertEqual(whisper.requests.count, 1)
        XCTAssertEqual(whisper.requests[0].samples, segment.samples)
        XCTAssertEqual(session.segmentTexts, ["test transcript"])
        XCTAssertTrue(session.unmatchedSegmentTexts.isEmpty)
        XCTAssertTrue(session.hadFailClosedPassthrough)
        XCTAssertNotNil(appState.lastError)

        await appState.finishTranscription(session)

        XCTAssertNil(appState.flowBarMessage)
        XCTAssertFalse(appState.lastTranscription.isEmpty)
    }

    /// Requirement B (partial match): when some segments in a recording matched and others did
    /// not, the matched text must still take the normal paste path and the clipboard fallback
    /// must not fire -- only a recording where *nothing* matched triggers it.
    func testPartialMatchPastesNormallyWithoutClipboardFallback() async throws {
        let whisper = RecordingWhisperService()
        let model = VariableEmbeddingSpeakerModel()
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: model,
            transcriptionService: whisper
        )
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[1] + [Float](repeating: 0, count: 255)]
        )
        let session = RecordingTranscriptionSession(
            id: 5,
            targetApp: nil,
            targetSpeakerEnabled: true,
            targetSpeakerProfile: profile
        )
        let acceptedSegment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), // matches profile
            overlapSampleCount: 1
        )
        let rejectedSegment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.4), count: 32_000), // orthogonal to profile
            overlapSampleCount: 1
        )
        session.enqueue(acceptedSegment)
        session.enqueue(rejectedSegment)

        await appState.transcribeStreamingSegment(acceptedSegment, session: session)
        await appState.transcribeStreamingSegment(rejectedSegment, session: session)

        XCTAssertEqual(whisper.requests.count, 2)
        XCTAssertEqual(session.segmentTexts.count, 1)
        XCTAssertEqual(session.unmatchedSegmentTexts.count, 1)

        await appState.finishTranscription(session)

        XCTAssertNotEqual(appState.flowBarMessage, "Ses eşleşmedi (panoda)")
        XCTAssertNotEqual(appState.flowBarMessage, "Ses eşleşmedi")
        XCTAssertFalse(appState.lastTranscription.isEmpty)
    }

    func testMixedVoicesInsideOneSegmentPasteOnlyStrongTargetWindows() async throws {
        let whisper = RecordingWhisperService()
        let store = InMemoryTargetSpeakerProfileStore()
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[1] + [Float](repeating: 0, count: 255)]
        )
        try store.save(profile)
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: ScriptedWindowSpeakerModel(
                voiceFrames: Array(repeating: true, count: 12),
                embeddings: [
                    [1] + [Float](repeating: 0, count: 255),
                    [0, 1] + [Float](repeating: 0, count: 254)
                ]
            ),
            transcriptionService: whisper
        )
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 6, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: profile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 12 * TargetSpeakerFilterConfiguration.vadFrameSamples),
            overlapSampleCount: 1
        )
        session.enqueue(segment)

        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertEqual(whisper.requests.count, 1)
        XCTAssertGreaterThan(whisper.requests[0].samples.prefix(28_000).filter { $0 != 0 }.count, 0)
        XCTAssertTrue(whisper.requests[0].samples.suffix(from: 31_000).allSatisfy { $0 == 0 })
        XCTAssertFalse(appState.targetSpeakerAppendOfferActive)
        XCTAssertNotEqual(appState.flowBarMessage, "Sesin bir kısmı eşleşmedi (panoda)")
        XCTAssertFalse(appState.lastTranscription.isEmpty)
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

    func testEnrollmentBuildsProfileFromTwoSpeakingConditions() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(
                voiceFrames: Array(repeating: true, count: 48)
            )
        )
        let recording = validEnrollmentSamples()

        appState.beginTargetSpeakerEnrollment()
        appState.processTargetSpeakerEnrollmentSamples(recording)
        try await waitUntil {
            !appState.targetSpeakerEnrollmentIsProcessing
                && appState.targetSpeakerEnrollmentStep == 1
        }
        XCTAssertTrue(appState.targetSpeakerEnrollmentActive)

        appState.processTargetSpeakerEnrollmentSamples(recording)
        try await waitUntil {
            !appState.targetSpeakerEnrollmentIsProcessing
                && !appState.targetSpeakerEnrollmentActive
        }

        XCTAssertTrue(appState.hasTargetSpeakerProfile)
        XCTAssertEqual(try store.load()?.embeddings.count, 30)
    }

    /// Regression test for a retry-loop bug: `createProfile`'s per-recording coherence check can
    /// name recording 0 as the contaminated one, even though recording 0 is never the *most
    /// recently captured* recording once recording 1 exists. The generic catch-all (correct for
    /// `invalidSample`/`crossRecordingMismatch`, which can only ever implicate the most recent
    /// capture) must not blindly reset to `sampleIndex` and `removeLast()` here -- that would keep
    /// discarding the clean recording 1 and re-prompting for it forever while the actually-bad
    /// recording 0 sits untouched, re-failing identically on every retry. The wizard must instead
    /// rewind all the way to the recording the error names and clear both slots.
    func testEnrollmentDiscardsBothRecordingsWhenAnEarlierOneFailsCoherenceCheck() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        // Every capture through this model replays the same 7-cluster-A/8-cluster-B script (the
        // window index resets on each `vadFrames` call), so both recordings look identically
        // contaminated -- but `createProfile`'s loop always reaches recording 0 first, so index 0
        // is what the thrown error names.
        let clusterA: [Float] = [1] + [Float](repeating: 0, count: 255)
        var clusterB = [Float](repeating: 0, count: 256)
        clusterB[1] = 1
        let model = ScriptedWindowSpeakerModel(
            voiceFrames: Array(repeating: true, count: 48),
            embeddings: Array(repeating: clusterA, count: 7) + [clusterB]
        )
        let appState = AppState(profileStore: store, targetSpeakerModel: model)
        let recording = validEnrollmentSamples()

        appState.beginTargetSpeakerEnrollment()
        appState.processTargetSpeakerEnrollmentSamples(recording)
        try await waitUntil {
            !appState.targetSpeakerEnrollmentIsProcessing && appState.targetSpeakerEnrollmentStep == 1
        }

        appState.processTargetSpeakerEnrollmentSamples(recording)
        try await waitUntil { !appState.targetSpeakerEnrollmentIsProcessing }

        XCTAssertTrue(appState.targetSpeakerEnrollmentActive, "a recoverable failure must not abandon the wizard")
        XCTAssertEqual(appState.targetSpeakerEnrollmentStep, 0, "the coherence error named recording 0, so the wizard must rewind to it, not to recording 1")
        XCTAssertTrue(appState.lastError?.contains("Ses kaydı 1") == true, "the surfaced message should name the recording that actually failed")

        // Prove recording 0 was actually discarded (not just the step counter reset): resubmitting
        // now must be treated as a fresh "first recording" (step -> 1), not immediately re-trigger
        // `createProfile` against a stale leftover recording (which would instead show "Kayıt
        // sırası değişti" and never reach step 1).
        appState.processTargetSpeakerEnrollmentSamples(recording)
        try await waitUntil {
            !appState.targetSpeakerEnrollmentIsProcessing && appState.targetSpeakerEnrollmentStep == 1
        }
        XCTAssertEqual(
            appState.targetSpeakerEnrollmentStatus,
            "İlk kayıt tamamlandı. Duruşunu değiştir ve ikinci kaydı başlat.",
            "both prior recordings must have been cleared, letting this submission re-enter as recording 1"
        )
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

    // MARK: - Rejected-recording confirmation (one-time paste only)



    /// Requirement (e): the fail-closed path never decided anything, so nothing is retained --
    /// no offer, and confirming (with nothing retained) is a harmless no-op.
    func testFailClosedRecordingRetainsNothingForAppend() async throws {
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(),
            transcriptionService: RecordingWhisperService()
        )
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false
        let session = RecordingTranscriptionSession(
            id: 103, targetApp: nil, targetSpeakerEnabled: true,
            targetSpeakerProfile: nil // triggers the fail-closed "no profile" path
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(session.belowThresholdRejectedSamples.isEmpty, "fail-closed must not accumulate retained audio")
        XCTAssertFalse(appState.targetSpeakerAppendOfferActive, "fail-closed must never offer to append")

        appState.confirmRetainedRecordingWasTargetSpeaker()
        XCTAssertNil(appState.flowBarMessage, "confirming with nothing retained must be a no-op")
    }

    // MARK: - "Bu benim sesimdi" paste-on-click

    /// Requirement (b): the paste must use the *retained* transcript, never whatever the
    /// clipboard currently holds -- during the 8s offer window the user may have copied
    /// something else entirely, and reading the clipboard back at click time would silently
    /// paste the wrong text (and the user would lose track of what they'd just copied).
    func testPasteUsesRetainedTextEvenWhenClipboardWasOverwrittenDuringOfferWindow() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)
        let injector = RecordingTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 8)),
            transcriptionService: RecordingWhisperService(),
            textInjector: injector
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 400, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "test transcript")

        // Simulate the user copying something unrelated during the 8s offer window.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("something the user copied in the meantime", forType: .string)

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertEqual(
            injector.pasteCalls.map(\.text),
            ["test transcript"],
            "must paste the retained transcript, not whatever is currently on the clipboard"
        )
    }

    /// Requirement (d), part 1: starting a new dictation clears the retained rejection samples
    /// and salvaged text together. `startRecording` calls `clearFlowBarMessage()` (which tears
    /// down the offer) before its `modelLoaded` guard -- same trick as
    /// `testNewRecordingClearsStaleNoMatchMessage` -- so this can be proven without a real model.
    func testNewDictationClearsRetainedRejectionSamplesAndTextTogether() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)
        let injector = RecordingTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 8)),
            transcriptionService: RecordingWhisperService(),
            textInjector: injector
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 403, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)
        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)

        appState.modelLoaded = false
        appState.startRecording() // bails on the modelLoaded guard, but only after clearFlowBarMessage() already tore down the offer + retained state

        XCTAssertFalse(appState.targetSpeakerAppendOfferActive)

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertTrue(
            injector.pasteCalls.isEmpty,
            "nothing should be pasted -- the retained samples/text must have been cleared by the new dictation"
        )
        XCTAssertNil(appState.flowBarMessage, "confirming with nothing retained is a no-op")
    }

    /// Requirement (d), part 2: the offer's own timeout path clears the retained samples and
    /// salvaged text together too, not just the new-dictation path above. Calls
    /// `dismissTargetSpeakerAppendOffer()` directly (it's `internal`, not `private`, for exactly
    /// this reason) instead of waiting out a real 8-second sleep.
    func testOfferTimeoutClearsRetainedRejectionSamplesAndTextTogether() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)
        let injector = RecordingTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 8)),
            transcriptionService: RecordingWhisperService(),
            textInjector: injector
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 404, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)
        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)

        // Simulates the real 8s offer-timeout task firing: it calls exactly these two steps
        // (see `showTargetSpeakerAppendOffer`'s `Task`), which is why `dismissTargetSpeakerAppendOffer`
        // deliberately leaves `flowBarMessage` untouched -- callers decide separately.
        appState.dismissTargetSpeakerAppendOffer()
        appState.flowBarMessage = nil

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertTrue(
            injector.pasteCalls.isEmpty,
            "nothing should be pasted -- the timeout must have cleared both the retained samples and text"
        )
        XCTAssertNil(appState.flowBarMessage)
    }

    private func validEnrollmentSamples() -> [Float] {
        Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)
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

/// A `TextInjecting` fake so tests can exercise `confirmRetainedRecordingWasTargetSpeaker`'s
/// paste-on-click behavior without posting real CGEvent keystrokes or activating whatever app
/// happens to be frontmost in the test runner. Deliberately does NOT invoke `onPasted`
/// automatically (the real `TextInjector` only calls it ~0.8s later, off a `DispatchQueue`
/// timer) -- this keeps the fake from dragging `DictationSnapshot`/`CorrectionStore` globals
/// into tests that never asked for them, and lets tests assert the paste happened
/// synchronously, independent of anything that would run in that callback.
private final class RecordingTextInjector: TextInjecting {
    struct PasteCall {
        let text: String
        let targetApp: NSRunningApplication?
    }

    private(set) var pasteCalls: [PasteCall] = []
    private(set) var clipboardCalls: [String] = []
    private(set) var replaceCalls: [(old: String, new: String)] = []

    func copyToClipboard(_ text: String) {
        clipboardCalls.append(text)
    }

    func pasteText(_ text: String, targetApp: NSRunningApplication?, onPasted: (() -> Void)?) {
        pasteCalls.append(PasteCall(text: text, targetApp: targetApp))
    }

    func replaceInjectedText(
        oldText: String,
        newText: String,
        targetApp: NSRunningApplication?,
        context: PasteContext?,
        onReplaced: (() -> Void)?
    ) {
        replaceCalls.append((old: oldText, new: newText))
    }

    /// Clears recorded calls so a test can isolate assertions to what happens *after* some
    /// earlier, unrelated setup step (e.g. a prior dictation's paste).
    func resetRecordedCalls() {
        pasteCalls.removeAll()
        clipboardCalls.removeAll()
        replaceCalls.removeAll()
    }
}

/// A `TargetSpeakerModelProvider` that returns a scripted sequence of embeddings, indexed by call
/// order *within* a single `vadFrames`-to-`embedding` cycle -- the index resets every time
/// `vadFrames` is invoked, since that marks the start of a fresh `enroll()`/`filter()` call (gate
/// scoring, then later re-validation for the "Bu benim sesimdi" append use the same retained
/// samples but are two separate calls). This lets one retained recording be scripted to look like
/// a single coherent cluster or two distinct clusters, deterministically, across both calls.
private final class ScriptedWindowSpeakerModel: TargetSpeakerModelProvider, @unchecked Sendable {
    let modelIdentifier = FluidAudioTargetSpeakerModel.identifier
    private let voiceFrames: [Bool]
    private let embeddings: [[Float]]
    private let lock = NSLock()
    private var windowIndex = 0

    init(voiceFrames: [Bool], embeddings: [[Float]]) {
        self.voiceFrames = voiceFrames
        self.embeddings = embeddings
    }

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {}

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        resetWindowIndex()
        return voiceFrames.map { TargetSpeakerVADFrame(isVoiceActive: $0, probability: $0 ? 1 : 0) }
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        embeddings[nextWindowIndex()]
    }

    // NSLock's `lock()`/`unlock()` are unavailable directly inside an `async` function body (see
    // MockTargetSpeakerModel in TargetSpeakerFilterTests.swift for the same convention) -- wrapping
    // them in ordinary synchronous helpers keeps the locking while avoiding that warning.
    private func resetWindowIndex() {
        lock.lock()
        windowIndex = 0
        lock.unlock()
    }

    private func nextWindowIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = min(windowIndex, embeddings.count - 1)
        windowIndex += 1
        return index
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

/// A `TargetSpeakerModelProvider` whose embedding depends on the input samples, so a single
/// session can exercise both an "accepted" segment and a "rejected" segment against the same
/// profile -- something the other fakes here (fixed embedding) can't do.
private final class VariableEmbeddingSpeakerModel: TargetSpeakerModelProvider, @unchecked Sendable {
    let modelIdentifier = FluidAudioTargetSpeakerModel.identifier

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {}

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        Array(repeating: TargetSpeakerVADFrame(isVoiceActive: true, probability: 1), count: 8)
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        // Segments filled with a value above 0.3 are the "rejected" (orthogonal) speaker;
        // everything else matches the profile used in the partial-match test.
        if let first = samples.first, first > 0.3 {
            return [0, 1] + [Float](repeating: 0, count: 254)
        }
        return [1] + [Float](repeating: 0, count: 255)
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
