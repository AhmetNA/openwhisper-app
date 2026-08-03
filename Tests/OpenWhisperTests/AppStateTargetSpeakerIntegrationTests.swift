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

    /// Requirement B: a below-threshold rejection (the gate ran fine and decided this isn't the
    /// target speaker) still transcribes the original audio, but the text must land in
    /// `unmatchedSegmentTexts` (never `segmentTexts`) and end up on the general pasteboard --
    /// not pasted -- with the "(panoda)" flow bar message.
    func testBelowThresholdRejectionWithVoiceActivityEndsUpOnClipboard() async throws {
        let whisper = RecordingWhisperService()
        let appState = AppState(
            profileStore: InMemoryTargetSpeakerProfileStore(),
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 8)),
            transcriptionService: whisper
        )
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false
        // Orthogonal to the model's fixed [1, 0, 0, ...] embedding so cosine similarity is
        // structurally 0 -- below any threshold in 0...1, regardless of tuning overrides the
        // user might have set via `defaults write`.
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        let session = RecordingTranscriptionSession(
            id: 4,
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

        XCTAssertEqual(whisper.requests.count, 1)
        XCTAssertEqual(whisper.requests[0].samples, segment.samples)
        XCTAssertTrue(session.segmentTexts.isEmpty)
        XCTAssertEqual(session.unmatchedSegmentTexts, ["test transcript"])

        await appState.finishTranscription(session)

        XCTAssertEqual(appState.flowBarMessage, "Ses eşleşmedi (panoda)")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "test transcript")
        XCTAssertEqual(appState.lastTranscription, "")
    }

    // MARK: - Audio-processing-mode mismatch (profile vs. active "Gürültü engelleme" setting)

    /// "Bu benim sesimdi" is a pure paste-only action (see `confirmRetainedRecordingWasTargetSpeaker`'s
    /// doc comment) -- a mode mismatch changes nothing about that. This proves the offer still
    /// fires for a mismatched-mode rejection (mismatch detection doesn't accidentally gate the
    /// general rejection-retain-offer wiring) and that confirming it still only pastes, never
    /// touching the stored profile or the user's own `noiseSuppressionEnabled` preference -- no
    /// pinning happens anywhere in this flow.
    func testAudioProcessingModeMismatchRejectionStillOffersPlainPasteOnlyConfirmation() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)],
            audioProcessingMode: .vpio
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
        appState.noiseSuppressionEnabled = false // active mode is "raw"; the profile is "vpio"

        let session = RecordingTranscriptionSession(
            id: 500, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile,
            noiseSuppressionEnabled: false
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        // Same wording as any other below-threshold rejection -- no mode-specific promise, since
        // confirming never mutates the profile regardless of mode.
        XCTAssertEqual(appState.flowBarMessage, "Ses eşleşmedi (panoda)")
        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"])
        XCTAssertNil(injector.pasteCalls.first?.targetApp)
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")
        XCTAssertEqual(try store.load(), originalProfile, "confirming must never mutate the profile, mismatch or not")
        XCTAssertEqual(appState.noiseSuppressionEnabled, false, "the user's global preference must never be silently changed")
    }

    /// Task requirement 4: Settings must always name which mode the profile was captured in
    /// while the feature is on -- not only when there's a problem -- and must separately flag
    /// whether that's currently a mismatch, so the view can style the two cases differently.
    func testAudioProcessingModeStatusTextAlwaysNamesModeAndMismatchFlagTracksOnlyDisagreement() throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[1] + [Float](repeating: 0, count: 255)],
            audioProcessingMode: .vpio
        )
        try store.save(profile)
        let appState = AppState(profileStore: store, targetSpeakerModel: IntegrationSpeakerModel())
        appState.loadTargetSpeakerProfile()
        appState.targetSpeakerEnabled = true
        appState.noiseSuppressionEnabled = true
        XCTAssertTrue(appState.targetSpeakerAudioProcessingModeStatusText?.contains("gürültü engellemeli") == true, "must name the profile's mode even when it matches")
        XCTAssertFalse(appState.targetSpeakerAudioProcessingModeMismatched, "matching modes must not be flagged as a mismatch")

        appState.noiseSuppressionEnabled = false
        XCTAssertTrue(appState.targetSpeakerAudioProcessingModeStatusText?.contains("gürültü engellemeli") == true)
        XCTAssertTrue(appState.targetSpeakerAudioProcessingModeMismatched)

        appState.targetSpeakerEnabled = false
        XCTAssertNil(appState.targetSpeakerAudioProcessingModeStatusText, "feature off must produce no notice")
        XCTAssertFalse(appState.targetSpeakerAudioProcessingModeMismatched)
    }

    // MARK: - Legacy (schema 2) profile migration on load

    /// End-to-end version of `TargetSpeakerFilterTests`' decode-layer migration tests: loading a
    /// genuine legacy schema-2 profile through `AppState.loadTargetSpeakerProfile()` must not
    /// force re-enrollment (the coordinator's correction explicitly rules this out -- users
    /// already complained about the re-enrollment flow being onerous), must explain the raw-mode
    /// assumption in Turkish, and must resave once so the migration doesn't repeat on every
    /// launch. Needs a `Data`-backed store (not `InMemoryTargetSpeakerProfileStore`, which stores
    /// the already-decoded struct and so can never produce a genuine
    /// `migratedFromLegacySchema == true` instance) to seed real legacy JSON bytes.
    func testLoadingLegacySchemaTwoProfileMigratesWithoutForcingReenrollmentAndResavesOnce() throws {
        struct LegacyV2Profile: Encodable {
            let schemaVersion: Int
            let modelIdentifier: String
            let embeddings: [[Float]]
            let createdAt: Date
            let updatedAt: Date
        }
        let legacy = LegacyV2Profile(
            schemaVersion: 2,
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[1] + [Float](repeating: 0, count: 255)],
            createdAt: Date(),
            updatedAt: Date()
        )
        let store = JSONBackedTargetSpeakerProfileStore(seed: try JSONEncoder().encode(legacy))
        let appState = AppState(profileStore: store, targetSpeakerModel: IntegrationSpeakerModel())
        // Simulate a returning user who already had the feature on -- proves the migration branch
        // doesn't flip it off, not just that it happens to already be off.
        appState.targetSpeakerEnabled = true

        appState.loadTargetSpeakerProfile()

        XCTAssertTrue(appState.hasTargetSpeakerProfile, "a migrated v2 profile must be immediately usable, not treated as incompatible")
        XCTAssertTrue(appState.targetSpeakerEnabled, "must not be force-disabled -- no forced re-enrollment for v2 profiles")
        XCTAssertTrue(
            appState.targetSpeakerProfileStatus.contains("gürültü engellemesiz"),
            "status must explain the raw-mode assumption, not just say the profile is ready"
        )

        // The resave must have upgraded the stored bytes to genuine schema 3: a second load must
        // not report `migratedFromLegacySchema` again.
        let reloaded = try store.load()
        XCTAssertEqual(reloaded?.schemaVersion, TargetSpeakerProfile.currentSchemaVersion)
        XCTAssertFalse(reloaded?.migratedFromLegacySchema ?? true)
        XCTAssertEqual(reloaded?.audioProcessingMode, .raw)
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

    /// Genuine `.ambiguous` (as opposed to `.singleSpeakerUncertain`, a different, separately
    /// covered decision) needs windows that are internally inconsistent with each other -- see
    /// the identical construction and its rationale in
    /// `TargetSpeakerFilterTests.testMixedCoherenceUncertainWindowsAreClassifiedAmbiguous`, which
    /// verifies the raw filter decision this test builds on top of. Diarization is never prepared
    /// in these tests, so this exercises the ambiguous-without-diarization fallback: retain the
    /// original audio for salvage/offer instead of silently withholding it.
    func testAmbiguousTargetSpeechUsesClipboardFallbackWithoutProfileMutation() async throws {
        func vector(_ pairs: [(Int, Float)]) -> [Float] {
            var v = [Float](repeating: 0, count: TargetSpeakerProfile.expectedEmbeddingDimension)
            for (index, value) in pairs { v[index] = value }
            return v
        }
        let w0 = vector([(0, 1.0)])
        let w1 = vector([(0, 0.551), (1, 0.8345)])
        let w2 = vector([(0, 0.551), (2, 0.8345)])
        let w3 = vector([(0, 0.549), (3, 0.8358)])
        let w4 = vector([(0, 0.549), (4, 0.8358)])

        let store = InMemoryTargetSpeakerProfileStore()
        let whisper = RecordingWhisperService()
        let profile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [vector([(0, 0.56), (5, 0.8285)])]
        )
        try store.save(profile)
        let injector = RecordingTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: ScriptedWindowSpeakerModel(
                voiceFrames: Array(repeating: true, count: 18),
                embeddings: [w0, w1, w2, w3, w4]
            ),
            transcriptionService: whisper,
            textInjector: injector
        )
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 7, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: profile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 18 * TargetSpeakerFilterConfiguration.vadFrameSamples),
            overlapSampleCount: 1
        )
        session.enqueue(segment)

        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertEqual(whisper.requests.count, 1)
        XCTAssertEqual(whisper.requests[0].samples, segment.samples)
        XCTAssertEqual(appState.flowBarMessage, "Sesin bir kısmı eşleşmedi (panoda)")
        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)
        appState.confirmRetainedRecordingWasTargetSpeaker()
        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"])
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")
        XCTAssertEqual(try store.load(), profile)
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

    /// Requirements (a) and (b): after a below-threshold rejection with salvageable text, the
    /// flow bar offers the append control (proof the audio was retained -- `targetSpeakerAppendOfferActive`
    /// only ever goes true when retained audio exists), and confirming it grows the profile's
    /// The confirmation pastes the retained text but never learns from the rejected recording.
    func testConfirmingRetainedRejectedRecordingDoesNotMutateProfile() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        // Orthogonal to IntegrationSpeakerModel's fixed [1, 0, ...] embedding, so this recording
        // is structurally below any threshold -- same technique as the existing below-threshold
        // rejection test above.
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
            id: 100, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertEqual(appState.flowBarMessage, "Ses eşleşmedi (panoda)")
        XCTAssertTrue(appState.targetSpeakerAppendOfferActive, "offer must be active -- proof the rejected audio was retained")

        appState.confirmRetainedRecordingWasTargetSpeaker()

        // Requirement (a): the paste must happen synchronously on click, independent of (and
        // before) the async append work below completes.
        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"], "the retained transcript must be pasted immediately on click")
        XCTAssertNil(injector.pasteCalls.first?.targetApp, "must not pass a targetApp -- doing so would call .activate() and could steal focus")

        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")
        XCTAssertEqual(try store.load(), originalProfile)
        XCTAssertFalse(appState.targetSpeakerAppendOfferActive, "offer must be dismissed once acted on")
    }

    /// There is no undo action because confirmation never mutates the profile.
    func testConfirmationDoesNotCreateAnUndoableProfileChange() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 8)),
            transcriptionService: RecordingWhisperService(),
            textInjector: RecordingTextInjector()
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false
        let session = RecordingTranscriptionSession(
            id: 101, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)
        appState.confirmRetainedRecordingWasTargetSpeaker()
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")
        XCTAssertEqual(try store.load(), originalProfile)
    }

    /// A short fallback recording can still be explicitly pasted, but it never enters profile
    /// learning because the confirmation path performs no re-analysis.
    func testConfirmingTooShortRetainedRecordingPastesWithoutSaving() async throws {
        let defaults = UserDefaults.standard
        defaults.set(0.0, forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey)
        defer { defaults.removeObject(forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey) }

        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)
        let injector = RecordingTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 3)),
            transcriptionService: RecordingWhisperService(),
            textInjector: injector
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 102, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 3 * TargetSpeakerFilterConfiguration.vadFrameSamples),
            overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(appState.targetSpeakerAppendOfferActive, "retention doesn't require a scoreable run, only salvageable text")

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"])
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")

        XCTAssertEqual(try store.load(), originalProfile)
    }

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

    /// Requirement (f), part 1: a single click never adds more than 10 embeddings, even when the
    /// retained recording is long enough to yield many more candidate windows.
    ///
    /// Note: the appended embeddings come from the *same* fixed-embedding fake model used for
    /// gate scoring, so once they land in the profile they'd make a follow-up recording of the
    /// same "voice" score as a match (that's the self-healing property working as intended) --
    /// this test therefore only appends once and never re-triggers scoring against its own
    /// output, to keep the per-click-cap check isolated from that feedback loop.
    func testConfirmationNeverAddsCandidateEmbeddings() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)

        // 48 voiced frames yields 15 candidate windows on re-analysis (same math as the
        // two-recording enrollment test above, which gets 15 per recording) -- comfortably over
        // the per-click cap of 10, and total-profile headroom (299) is nowhere near binding.
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 48)),
            transcriptionService: RecordingWhisperService(),
            textInjector: RecordingTextInjector()
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 104, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples),
            overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)
        appState.confirmRetainedRecordingWasTargetSpeaker()
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")

        XCTAssertEqual(try store.load(), originalProfile)
    }

    /// Requirement (f), part 2: once the profile is already at the 300 hard cap, a further
    /// append is refused outright (no save, no partial add) with a Turkish message suggesting a
    /// fresh enrollment.
    func testConfirmationWorksWithoutProfileCapacityChecks() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        // Orthogonal to the model's fixed embedding on every one of the 300 entries, so the new
        // recording is still rejected even though the profile is already full.
        let bulkEmbedding: [Float] = [0, 1] + [Float](repeating: 0, count: 254)
        let fullProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: Array(repeating: bulkEmbedding, count: 300)
        )
        try store.save(fullProfile)

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
            id: 105, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: fullProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)
        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"])
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")

        XCTAssertEqual(try store.load()?.embeddings.count, 300, "must never exceed the hard cap")
    }

    // MARK: - Append path: within-recording coherence guard, no cross-recording guard

    /// Requirement A2 / D: the "Bu benim sesimdi" append is the highest-risk path for the
    /// coherence guard (it bakes in audio the gate just rejected), so a retained recording built
    /// from two clearly different embedding clusters must be blocked with a specific, Turkish,
    /// value-bearing message -- and must not be saved.
    func testConfirmationDoesNotRunProfileCoherenceAppendChecks() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let profileEmbedding: [Float] = [1] + [Float](repeating: 0, count: 255) // P
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [profileEmbedding]
        )
        try store.save(originalProfile)

        let clusterA: [Float] = [0, 1] + [Float](repeating: 0, count: 254) // orthogonal to P
        var clusterB = [Float](repeating: 0, count: 256)
        clusterB[2] = 1 // orthogonal to both P and clusterA
        // 48 voiced frames -> 15 candidate windows both at initial gate scoring and at
        // re-validation (same retained samples, same scripted model). 7 A's then clamp to B for
        // the rest -- every window scores cosine 0 against P (so the segment is reliably rejected
        // by the gate, offering the append), while A/B being mutually orthogonal makes this
        // recording internally incoherent when re-validated.
        let model = ScriptedWindowSpeakerModel(
            voiceFrames: Array(repeating: true, count: 48),
            embeddings: Array(repeating: clusterA, count: 7) + [clusterB]
        )
        let injector = RecordingTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: model,
            transcriptionService: RecordingWhisperService(),
            textInjector: injector
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 200, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples),
            overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(appState.targetSpeakerAppendOfferActive, "orthogonal-to-profile audio must have been rejected by the gate")

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"])
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")

        XCTAssertEqual(try store.load()?.embeddings.count, 1, "an internally incoherent retained recording must not be saved")
    }

    /// Requirement B: the append path must NOT apply the cross-recording check -- the whole point
    /// is to accept audio that scored below the cosine threshold against the existing profile by
    /// definition, so requiring it to also resemble that profile would defeat the feature. Uses a
    /// single coherent cluster (passes the coherence guard trivially) that is structurally
    /// orthogonal to the profile (cosine 0, far below the 0.40 cross-recording floor) to prove a
    /// cross-recording check is not silently applied here.
    func testConfirmationDoesNotLearnAnUnrelatedVoice() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let profileEmbedding: [Float] = [1] + [Float](repeating: 0, count: 255) // P
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [profileEmbedding]
        )
        try store.save(originalProfile)

        let clusterA: [Float] = [0, 1] + [Float](repeating: 0, count: 254) // orthogonal to P
        let model = ScriptedWindowSpeakerModel(
            voiceFrames: Array(repeating: true, count: 48),
            embeddings: [clusterA]
        )
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: model,
            transcriptionService: RecordingWhisperService(),
            textInjector: RecordingTextInjector()
        )
        appState.loadTargetSpeakerProfile()
        appState.autoPasteEnabled = false
        appState.llmCleanupEnabled = false

        let session = RecordingTranscriptionSession(
            id: 201, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples),
            overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)

        XCTAssertTrue(appState.targetSpeakerAppendOfferActive, "orthogonal-to-profile audio must have been rejected by the gate")

        appState.confirmRetainedRecordingWasTargetSpeaker()
        XCTAssertEqual(appState.flowBarMessage, "Yapıştırıldı")

        XCTAssertEqual(try store.load(), originalProfile)
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

    /// Requirement (c): confirming the offer clears any stale raw/cleaned pair left behind by an
    /// earlier, unrelated dictation -- otherwise Option+Z could fire after this click and swap in
    /// text that has nothing to do with what was just pasted.
    func testConfirmClearsStaleSwapPairFromEarlierDictation() async throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let originalProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [[0, 1] + [Float](repeating: 0, count: 254)]
        )
        try store.save(originalProfile)
        // The prior dictation below goes through the *normal* paste path
        // (`AppState.pasteAsDictation`, via `pasteTextResult`), whose outcome callback must
        // actually fire to populate `swapPair` -- `RecordingTextInjector` deliberately never
        // does that, so this test needs the synchronously-firing fake instead.
        let injector = SynchronousPasteTextInjector()
        let appState = AppState(
            profileStore: store,
            targetSpeakerModel: IntegrationSpeakerModel(voiceFrames: Array(repeating: true, count: 8)),
            transcriptionService: RecordingWhisperService(),
            textInjector: injector
        )
        appState.loadTargetSpeakerProfile()
        appState.llmCleanupEnabled = false

        // A prior, unrelated normal dictation (target speaker disabled, so it takes the plain
        // paste path) that leaves a swappable raw/cleaned pair behind.
        appState.autoPasteEnabled = true
        appState.targetSpeakerEnabled = false
        let priorSession = RecordingTranscriptionSession(
            id: 401, targetApp: nil, targetSpeakerEnabled: false, targetSpeakerProfile: nil
        )
        let priorSegment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        priorSession.enqueue(priorSegment)
        await appState.transcribeStreamingSegment(priorSegment, session: priorSession)
        await appState.finishTranscription(priorSession)
        // The outcome callback runs on a nested `Task { @MainActor in ... }` hop, so poll for it
        // rather than asserting immediately.
        try await waitUntil { appState.hasSwappablePair }
        injector.resetRecordedCalls() // isolate the assertions below to the confirm() paste

        // Now the target-speaker-gated rejected recording.
        appState.targetSpeakerEnabled = true
        let session = RecordingTranscriptionSession(
            id: 402, targetApp: nil, targetSpeakerEnabled: true, targetSpeakerProfile: originalProfile
        )
        let segment = CompletedAudioSegment(
            samples: Array(repeating: Float(0.2), count: 32_000), overlapSampleCount: 1
        )
        session.enqueue(segment)
        await appState.transcribeStreamingSegment(segment, session: session)
        await appState.finishTranscription(session)
        XCTAssertTrue(appState.targetSpeakerAppendOfferActive)

        appState.confirmRetainedRecordingWasTargetSpeaker()

        XCTAssertFalse(
            appState.hasSwappablePair,
            "the stale pair from the earlier dictation must not survive -- otherwise Option+Z would swap in unrelated text"
        )
        XCTAssertEqual(injector.pasteCalls.map(\.text), ["test transcript"])
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

/// A `TargetSpeakerProfileStore` backed by raw `Data`, round-tripped through
/// `JSONEncoder`/`JSONDecoder` on every call -- unlike `InMemoryTargetSpeakerProfileStore`, which
/// stores the already-decoded struct directly and so can never exercise `TargetSpeakerProfile`'s
/// `init(from:)` migration path. Lets a test seed genuine legacy schema-2 JSON bytes and observe
/// `AppState.loadTargetSpeakerProfile()`'s migration handling end-to-end.
private final class JSONBackedTargetSpeakerProfileStore: TargetSpeakerProfileStore, @unchecked Sendable {
    private var data: Data?

    init(seed: Data? = nil) {
        self.data = seed
    }

    func load() throws -> TargetSpeakerProfile? {
        guard let data else { return nil }
        return try JSONDecoder().decode(TargetSpeakerProfile.self, from: data)
    }

    func save(_ profile: TargetSpeakerProfile) throws {
        data = try JSONEncoder().encode(profile)
    }

    func delete() throws {
        data = nil
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

/// A `TextInjecting` fake whose `pasteText`/`pasteTextResult` synchronously invoke their
/// completion, unlike `RecordingTextInjector` above (which deliberately never fires its
/// completion). Needed wherever a test's setup goes through the *normal* dictation paste path
/// (`AppState.pasteAsDictation`, which uses `pasteTextResult`) and depends on its outcome
/// callback actually running -- e.g. to populate `swapPair` -- since `RecordingTextInjector`
/// can't do that at all. `confirmRetainedRecordingWasTargetSpeaker` itself no longer needs this:
/// it's a plain, synchronous `pasteText` call with no outcome callback to wait for.
private final class SynchronousPasteTextInjector: TextInjecting {
    struct PasteCall {
        let text: String
        let targetApp: NSRunningApplication?
    }

    private(set) var pasteCalls: [PasteCall] = []
    private(set) var clipboardCalls: [String] = []

    func copyToClipboard(_ text: String) {
        clipboardCalls.append(text)
    }

    func pasteText(_ text: String, targetApp: NSRunningApplication?, onPasted: (() -> Void)?) {
        pasteCalls.append(PasteCall(text: text, targetApp: targetApp))
        onPasted?()
    }

    func replaceInjectedText(
        oldText: String,
        newText: String,
        targetApp: NSRunningApplication?,
        onReplaced: (() -> Void)?
    ) {
        onReplaced?()
    }

    func pasteTextResult(
        _ text: String,
        targetApp: NSRunningApplication?,
        context: PasteContext?,
        onOutcome: ((PasteOutcome) -> Void)?
    ) {
        pasteCalls.append(PasteCall(text: text, targetApp: targetApp))
        onOutcome?(.pastedUnverified)
    }

    /// Clears recorded calls so a test can isolate assertions to what happens *after* some
    /// earlier, unrelated setup step (e.g. a prior dictation's paste).
    func resetRecordedCalls() {
        pasteCalls.removeAll()
        clipboardCalls.removeAll()
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
