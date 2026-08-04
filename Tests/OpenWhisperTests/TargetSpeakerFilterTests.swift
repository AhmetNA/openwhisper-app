import XCTest
@testable import OpenWhisper

final class TargetSpeakerFilterTests: XCTestCase {
    func testProfileVersionAndDelete() throws {
        let store = InMemoryTargetSpeakerProfileStore()
        let profile = try makeProfile()
        try store.save(profile)
        XCTAssertEqual(try store.load(), profile)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testProfileDecodeRejectsSchemaModelAndEmbeddingMismatch() throws {
        let profile = try makeProfile()
        let encoder = JSONEncoder()
        let base = try JSONSerialization.jsonObject(with: encoder.encode(profile)) as! [String: Any]

        var unsupportedSchema = base
        unsupportedSchema["schemaVersion"] = 999
        XCTAssertThrowsError(try JSONDecoder().decode(
            TargetSpeakerProfile.self,
            from: JSONSerialization.data(withJSONObject: unsupportedSchema)
        ))

        var emptyModel = base
        emptyModel["modelIdentifier"] = ""
        XCTAssertThrowsError(try JSONDecoder().decode(
            TargetSpeakerProfile.self,
            from: JSONSerialization.data(withJSONObject: emptyModel)
        ))

        var wrongDimension = base
        wrongDimension["embeddings"] = [[0.0]]
        XCTAssertThrowsError(try JSONDecoder().decode(
            TargetSpeakerProfile.self,
            from: JSONSerialization.data(withJSONObject: wrongDimension)
        ))
    }

    func testCosineThresholdAllowsModeratePitchVariation() async throws {
        let samples = Array(repeating: Float(0.25), count: 32_000)
        let profile = try makeProfile(embedding: unitVector())

        let rejected = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: vector(withCosine: 0.46), frameCount: 8
        )).filter(samples: samples, profile: profile, enabled: true)
        XCTAssertEqual(rejected.acceptedSampleCount, 0)
        XCTAssertTrue(rejected.samples.allSatisfy { $0 == 0 })

        let accepted = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: vector(withCosine: 0.47), frameCount: 8
        )).filter(samples: samples, profile: profile, enabled: true)
        XCTAssertGreaterThan(accepted.acceptedSampleCount, 0)
    }

    func testWindowedDecisionKeepsStrongTargetWhenLaterWindowsAreAnotherSpeaker() async throws {
        let samples = Array(repeating: Float(0.25), count: 12 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let model = MockTargetSpeakerModel(
            embeddings: [unitVector(), [0, 1] + [Float](repeating: 0, count: 254)],
            frameCount: 12
        )
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples,
            profile: try makeProfile(),
            enabled: true
        )
        XCTAssertGreaterThan(result.acceptedSampleCount, 0)
        XCTAssertEqual(result.decision, .partial)
        XCTAssertEqual(result.samples[31_000], 0, "a strong-reject window must remain masked")
        XCTAssertEqual(model.windowLengths, [24_000, 24_000, 24_000])
    }

    func testUncertainWindowAdjacentToStrongTargetIsRescuedForToneVariation() async throws {
        let samples = Array(repeating: Float(0.2), count: 12 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let moderate = vector(withCosine: 0.56)
        let model = MockTargetSpeakerModel(
            embeddings: [unitVector(), moderate, moderate],
            frameCount: 12
        )
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples,
            profile: try makeProfile(),
            enabled: true
        )

        XCTAssertGreaterThan(result.acceptedSampleCount, 0)
        XCTAssertEqual(result.decision, .accepted)
        XCTAssertGreaterThan(result.samples[31_000], 0, "a continuous moderate-score window must not be cut")
    }

    func testOnlyUncertainWindowsRemainAmbiguousInsteadOfBeingAutoAccepted() async throws {
        let samples = Array(repeating: Float(0.2), count: 12 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let model = MockTargetSpeakerModel(
            embeddings: Array(repeating: vector(withCosine: 0.43), count: 3),
            frameCount: 12
        )
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples,
            profile: try makeProfile(),
            enabled: true
        )

        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertEqual(result.decision, .singleSpeakerUncertain)
        XCTAssertTrue(result.samples.allSatisfy { $0 == 0 })
    }

    func testIndependentShortUtteranceIsRejectedWhenBypassDisabled() async throws {
        // With the default 2.0s short-utterance bypass this 0.77s recording would now be
        // accepted (see testShortUtteranceUnderCeilingIsAcceptedWithoutScoring below). Injecting
        // a 0 ceiling explicitly disables the bypass and restores the original reject behavior --
        // this is case (d) from the short-utterance-bypass spec.
        let samples = Array(repeating: Float(0.25), count: 3 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let result = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: unitVector(), frameCount: 3
        )).filter(
            samples: samples, profile: try makeProfile(), enabled: true,
            tuning: TargetSpeakerTuning(cosineThreshold: 0.62, vadThreshold: 0.70, shortUtteranceMaxSeconds: 0)
        )
        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertTrue(result.samples.allSatisfy { $0 == 0 })
    }

    func testShortUtteranceUnderCeilingIsAcceptedWithoutScoring() async throws {
        // Case (a): nothing in this recording reaches the 1.5s scoring window (3 frames =
        // 0.77s), and it's under the default 2.0s ceiling, so push-to-talk short-utterance
        // bypass should accept it outright -- with zero identity scoring performed.
        let samples = Array(repeating: Float(0.25), count: 3 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 3)
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples, profile: try makeProfile(), enabled: true
        )
        XCTAssertGreaterThan(result.acceptedSampleCount, 0)
        XCTAssertTrue(model.windowLengths.isEmpty, "bypass must not perform any identity scoring")
        // Interior sample (well past the fade edge) should be recovered unchanged, proving the
        // bypass flowed through the same pad/merge/mask path as a normally-scored acceptance.
        let interiorIndex = samples.count / 2
        XCTAssertEqual(result.samples[interiorIndex], samples[interiorIndex], accuracy: 0.0001)
        // Since all samples are an identical constant, the interior check alone can't
        // distinguish "went through mask()" from "returned verbatim". The edge fade is the
        // discriminating signal: mask() always applies a ramped gain at range boundaries, so
        // sample 0 (start of the accepted+padded range) must be attenuated below the input.
        XCTAssertLessThan(result.samples[0], samples[0])
    }

    func testShortUtteranceOverCeilingIsStillRejected() async throws {
        // Case (b): two runs (5 frames each, one silent frame between) are each individually too
        // short to score, but their combined voiced duration (2 * 5 * 0.256s = 2.56s) exceeds the
        // default 2.0s ceiling, so the bypass must not fire and the recording is rejected.
        let frame = TargetSpeakerFilterConfiguration.vadFrameSamples
        let states = [Bool](repeating: true, count: 5) + [false] + [Bool](repeating: true, count: 5)
        let samples = Array(repeating: Float(0.25), count: states.count * frame)
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameStates: states)
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples, profile: try makeProfile(), enabled: true
        )
        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertTrue(result.samples.allSatisfy { $0 == 0 })
        XCTAssertTrue(model.windowLengths.isEmpty, "still no scoreable run, so no scoring should happen either")
    }

    func testScoreableRunPresentDisablesBypassEvenWithShortRunsPresent() async throws {
        // Case (c): reuse the shape from testShortUtterancePreservedOnlyAfterAcceptedNeighbor
        // (a 9-frame scoreable run plus a 1-frame short run), but with a below-threshold
        // embedding and a very generous injected ceiling (10s, far above the ~2.56s total voiced
        // duration here). If the bypass ignored "was anything scoreable" and only looked at the
        // ceiling, this would be wrongly accepted. Because a run *was* scored, normal scoring
        // must apply to everything and the below-threshold long run must still be rejected.
        let frame = TargetSpeakerFilterConfiguration.vadFrameSamples
        let samples = Array(repeating: Float(0.25), count: 11 * frame)
        let states = [Bool](repeating: true, count: 9) + [false, true]
        let model = MockTargetSpeakerModel(embedding: vector(withCosine: 0.61), frameStates: states)
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples, profile: try makeProfile(), enabled: true,
            tuning: TargetSpeakerTuning(cosineThreshold: 0.62, vadThreshold: 0.70, shortUtteranceMaxSeconds: 10)
        )
        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertFalse(model.windowLengths.isEmpty, "the long run must still have been scored")
    }

    func testShortUtteranceBypassNeverFiresOnFailClosedPaths() async throws {
        // Case (e), nil profile: a short recording (3 frames, well under the 2.0s ceiling) with
        // no enrolled profile must still fail closed -- the bypass only applies on the normal
        // path where VAD ran and scoring found nothing long enough, not when the gate can't even
        // get that far.
        let samples = Array(repeating: Float(0.25), count: 3 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let nilProfileResult = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: unitVector(), frameCount: 3
        )).filter(samples: samples, profile: nil, enabled: true)
        XCTAssertTrue(nilProfileResult.wasFailClosed)
        XCTAssertEqual(nilProfileResult.acceptedSampleCount, 0)
        XCTAssertTrue(nilProfileResult.samples.allSatisfy { $0 == 0 })

        // Case (e), throwing model: same short recording, but the model throws during
        // vadFrames/embedding -- must also fail closed, not bypass.
        let throwingResult = await TargetSpeakerFilter(model: MockTargetSpeakerModel(shouldThrow: true)).filter(
            samples: samples, profile: try makeProfile(), enabled: true
        )
        XCTAssertTrue(throwingResult.wasFailClosed)
        XCTAssertEqual(throwingResult.acceptedSampleCount, 0)
        XCTAssertTrue(throwingResult.samples.allSatisfy { $0 == 0 })
    }

    func testShortUtterancePreservedOnlyAfterAcceptedNeighbor() async throws {
        let frame = TargetSpeakerFilterConfiguration.vadFrameSamples
        let samples = Array(repeating: Float(0.25), count: 11 * frame)
        // 9-frame long utterance, one silent frame, then a 1-frame short utterance.
        let states = [Bool](repeating: true, count: 9) + [false, true]
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameStates: states)
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples,
            profile: try makeProfile(),
            enabled: true
        )
        XCTAssertGreaterThan(result.acceptedSampleCount, 9 * frame)
        XCTAssertGreaterThan(result.samples[10 * frame], 0)
        XCTAssertEqual(model.windowLengths, [24_000, 24_000])
    }

    func testShortRunDoesNotContaminateLongUtteranceEmbeddingWindows() async throws {
        let frame = TargetSpeakerFilterConfiguration.vadFrameSamples
        let samples = Array(repeating: Float(0.25), count: 11 * frame)
        let states = [Bool](repeating: true, count: 9) + [false, true]
        let model = MockTargetSpeakerModel(
            embeddings: [vector(withCosine: 0.69), vector(withCosine: 0.69)],
            frameStates: states
        )
        _ = await TargetSpeakerFilter(model: model).filter(
            samples: samples,
            profile: try makeProfile(),
            enabled: true
        )
        XCTAssertEqual(model.windowLengths, [24_000, 24_000])
    }

    func testPublicFilterAppliesTwoHundredFiftyMillisecondPadding() async throws {
        let frame = TargetSpeakerFilterConfiguration.vadFrameSamples
        let samples = Array(repeating: Float(1), count: 12 * frame)
        let states = [false, false] + [Bool](repeating: true, count: 8) + [false, false]
        let result = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: unitVector(), frameStates: states
        )).filter(samples: samples, profile: try makeProfile(), enabled: true)

        let paddedStart = 2 * frame - TargetSpeakerFilterConfiguration.acceptedPaddingSamples
        XCTAssertEqual(result.samples[paddedStart - 1], 0)
        XCTAssertGreaterThan(result.samples[paddedStart], 0)
        XCTAssertEqual(result.samples[paddedStart + TargetSpeakerFilterConfiguration.edgeFadeSamples], 1, accuracy: 0.001)
    }

    func testTenMillisecondEdgeFadeIsAppliedSeparately() {
        let samples = Array(repeating: Float(1), count: 12_000)
        let masked = TargetSpeakerFilter.mask(samples: samples, accepted: [(start: 2_000, end: 10_000)])
        XCTAssertLessThan(masked[2_000], 1)
        XCTAssertEqual(masked[2_000 + TargetSpeakerFilterConfiguration.edgeFadeSamples], 1, accuracy: 0.001)
        XCTAssertEqual(masked[9_999], 1.0 / Float(TargetSpeakerFilterConfiguration.edgeFadeSamples), accuracy: 0.001)
    }

    func testExactLengthAndOverlapArePreserved() {
        let segment = CompletedAudioSegment(samples: [1, 2, 3, 4, 5], overlapSampleCount: 2)
        let result = TargetSpeakerFilterResult(
            samples: [1, 0, 0, 4, 5], acceptedSampleCount: 3, hadVoiceActivity: true,
            wasFailClosed: false, errorDescription: nil
        )
        let filtered = TargetSpeakerSegmentFiltering.apply(segment, result: result)
        XCTAssertEqual(filtered.samples.count, segment.samples.count)
        XCTAssertEqual(filtered.overlapSampleCount, segment.overlapSampleCount)
    }

    func testFeatureOffReturnsExactInputArray() async throws {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let result = await TargetSpeakerFilter(model: MockTargetSpeakerModel(shouldThrow: true)).filter(
            samples: samples, profile: try makeProfile(), enabled: false
        )
        XCTAssertEqual(result.samples, samples)
        XCTAssertFalse(result.wasFailClosed)
        XCTAssertNil(result.errorDescription)
    }

    func testEnabledWithoutProfileFailsClosedAndSurfacesError() async {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let result = await TargetSpeakerFilter(model: MockTargetSpeakerModel()).filter(
            samples: samples, profile: nil, enabled: true
        )
        XCTAssertEqual(result.samples, Array(repeating: 0, count: samples.count))
        XCTAssertTrue(result.wasFailClosed)
        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertNotNil(result.errorDescription)
    }

    func testModelFailureFailsClosed() async throws {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let result = await TargetSpeakerFilter(model: MockTargetSpeakerModel(shouldThrow: true)).filter(
            samples: samples, profile: try makeProfile(), enabled: true
        )
        XCTAssertEqual(result.samples, Array(repeating: 0, count: samples.count))
        XCTAssertTrue(result.wasFailClosed)
        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertNotNil(result.errorDescription)
    }

    func testEnrollmentRequiresTwoSamplesWithThirtySecondMaximum() async throws {
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 48)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let store = InMemoryTargetSpeakerProfileStore()

        do {
            _ = try await filter.createProfile(from: [], store: store)
            XCTFail("fewer than two recordings must be rejected")
        } catch {
            XCTAssertEqual(error as? TargetSpeakerEnrollmentError, .requiresMultipleSamples)
        }
        let profile = try await filter.createProfile(
            from: [recording, recording], store: store
        )
        XCTAssertEqual(profile.embeddings.count, 30)
        XCTAssertEqual(TargetSpeakerFilterConfiguration.maximumEnrollmentDuration, 30)
    }

    func testEnrollmentRejectsAudioLongerThanThirtySeconds() async throws {
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 200)
        let filter = TargetSpeakerFilter(model: model)
        let tooLong = Array(repeating: Float(0.2), count: 30 * TargetSpeakerFilterConfiguration.sampleRate + 1)

        do {
            _ = try await filter.validateEnrollmentSample(tooLong)
            XCTFail("recordings over thirty seconds must be rejected")
        } catch {
            XCTAssertEqual(error as? TargetSpeakerEnrollmentError, .sampleExceedsMaximumDuration)
        }
    }

    func testPreparationProgressTransitionsAreObservable() async throws {
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 48)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let collector = ProgressCollector()
        let handler: TargetSpeakerProgressHandler = { progress in collector.append(progress.phase) }
        _ = try await filter.createProfile(
            from: [recording, recording],
            store: InMemoryTargetSpeakerProfileStore(),
            progressHandler: handler
        )
        XCTAssertTrue(collector.values.contains(.preparing))
        XCTAssertTrue(collector.values.contains(.ready))
    }

    func testTuningResolvesDocumentedDefaultsWhenUserDefaultsKeysAreAbsent() {
        let suiteName = "TargetSpeakerFilterTests.absent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(tuning.cosineThreshold, 0.47, accuracy: 0.0001)
        XCTAssertEqual(tuning.vadThreshold, 0.70, accuracy: 0.0001)
        XCTAssertEqual(tuning.shortUtteranceMaxSeconds, 2.0, accuracy: 0.0001)
    }

    func testTuningResolvesInjectedUserDefaultsValues() {
        let suiteName = "TargetSpeakerFilterTests.injected.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.80, forKey: TargetSpeakerTuning.cosineThresholdKey)
        defaults.set(0.55, forKey: TargetSpeakerTuning.vadThresholdKey)
        defaults.set(3.5, forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey)

        let tuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(tuning.cosineThreshold, 0.80, accuracy: 0.0001)
        XCTAssertEqual(tuning.vadThreshold, 0.55, accuracy: 0.0001)
        XCTAssertEqual(tuning.shortUtteranceMaxSeconds, 3.5, accuracy: 0.0001)
    }

    func testTuningResolvesExplicitZeroShortUtteranceMaxSecondsAsDisabled() {
        // 0 is a meaningful, valid value (disables the bypass) -- must not be confused with
        // "key absent" the way object(forKey:) would if double(forKey:) were used directly.
        let suiteName = "TargetSpeakerFilterTests.zeroCeiling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.0, forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey)

        let tuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(tuning.shortUtteranceMaxSeconds, 0.0, accuracy: 0.0001)
    }

    func testTuningFallsBackToDefaultForOutOfRangeOrNonFiniteValues() {
        let suiteName = "TargetSpeakerFilterTests.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(1.5, forKey: TargetSpeakerTuning.cosineThresholdKey)
        defaults.set(-0.1, forKey: TargetSpeakerTuning.vadThresholdKey)
        defaults.set(-1.0, forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey)
        var tuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(tuning.cosineThreshold, 0.47, accuracy: 0.0001, "out-of-range cosine value must fall back")
        XCTAssertEqual(tuning.vadThreshold, 0.70, accuracy: 0.0001, "out-of-range vad value must fall back")
        XCTAssertEqual(tuning.shortUtteranceMaxSeconds, 2.0, accuracy: 0.0001, "negative ceiling value must fall back")

        defaults.set(Double.nan, forKey: TargetSpeakerTuning.cosineThresholdKey)
        defaults.set(Double.infinity, forKey: TargetSpeakerTuning.vadThresholdKey)
        defaults.set(Double.nan, forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey)
        tuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(tuning.cosineThreshold, 0.47, accuracy: 0.0001, "non-finite cosine value must fall back")
        XCTAssertEqual(tuning.vadThreshold, 0.70, accuracy: 0.0001, "non-finite vad value must fall back")
        XCTAssertEqual(tuning.shortUtteranceMaxSeconds, 2.0, accuracy: 0.0001, "non-finite ceiling value must fall back")

        defaults.set(Double.infinity, forKey: TargetSpeakerTuning.shortUtteranceMaxSecondsKey)
        tuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(tuning.shortUtteranceMaxSeconds, 2.0, accuracy: 0.0001, "infinite ceiling value must fall back")
    }

    func testInjectedTuningIsTheThresholdActuallyCompared() async throws {
        // 0.65 sits strictly between the default 0.62 threshold and this window's score, so the
        // outcome flips depending on which threshold is actually used by filter(...).
        let samples = Array(repeating: Float(0.25), count: 32_000)
        let profile = try makeProfile(embedding: unitVector())
        let model = MockTargetSpeakerModel(embedding: vector(withCosine: 0.63), frameCount: 8)

        let acceptedWithDefault = await TargetSpeakerFilter(model: model).filter(
            samples: samples, profile: profile, enabled: true
        )
        XCTAssertGreaterThan(acceptedWithDefault.acceptedSampleCount, 0, "0.63 clears the default 0.62 threshold")

        let rejectedWithInjectedTuning = await TargetSpeakerFilter(model: model).filter(
            samples: samples, profile: profile, enabled: true,
            tuning: TargetSpeakerTuning(cosineThreshold: 0.65, vadThreshold: 0.70)
        )
        XCTAssertEqual(rejectedWithInjectedTuning.acceptedSampleCount, 0, "0.63 must not clear an injected 0.65 threshold")
    }

    // MARK: - Recording coherence & cross-recording consistency (enrollment guard)

    func testRecordingCoherenceIsHighForOneVoiceAndLowForTwoClusters() {
        let consistent = Array(repeating: unitVector(), count: 10)
        XCTAssertEqual(TargetSpeakerFilter.recordingCoherence(consistent), 1.0, accuracy: 0.0001)

        // 5 windows of one speaker, 5 of an orthogonal "other speaker" -- half the pairwise
        // comparisons are same-cluster (~1.0) and half are cross-cluster (~0.0), so the median
        // falls well below the 0.55 default floor.
        let twoClusters = Array(repeating: unitVector(), count: 5) + Array(repeating: vector(withCosine: 0), count: 5)
        XCTAssertLessThan(TargetSpeakerFilter.recordingCoherence(twoClusters), 0.55)
    }

    func testRecordingCoherenceTreatsFewerThanTwoEmbeddingsAsTriviallyCoherent() {
        // A recording that yields at most one speaker window can't disagree with itself -- this
        // must return a passing score (1), not an undefined or synthetically-low one, so it isn't
        // penalized twice alongside the separate duration/quantity checks that already gate it.
        XCTAssertEqual(TargetSpeakerFilter.recordingCoherence([]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(TargetSpeakerFilter.recordingCoherence([unitVector()]), 1.0, accuracy: 0.0001)
    }

    func testCrossRecordingSimilarityIsMedianOfAllCrossPairs() {
        let lhs = Array(repeating: unitVector(), count: 5)
        let rhs = Array(repeating: vector(withCosine: 0.5), count: 5)
        XCTAssertEqual(TargetSpeakerFilter.crossRecordingSimilarity(lhs, rhs), 0.5, accuracy: 0.0001)
    }

    func testTuningResolvesNewFloorsWithDefaultsOverridesAndZeroDisables() {
        let suiteName = "TargetSpeakerFilterTests.floors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultTuning = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(defaultTuning.uncertainSimilarityFloor, 0.40, accuracy: 0.0001)
        XCTAssertEqual(defaultTuning.uncertainContinuityThreshold, 0.47, accuracy: 0.0001)
        XCTAssertEqual(defaultTuning.minRecordingCoherence, 0.47, accuracy: 0.0001)
        XCTAssertEqual(defaultTuning.minCrossRecordingSimilarity, 0.40, accuracy: 0.0001)

        defaults.set(0.51, forKey: TargetSpeakerTuning.uncertainSimilarityFloorKey)
        defaults.set(0.58, forKey: TargetSpeakerTuning.uncertainContinuityThresholdKey)
        defaults.set(0.8, forKey: TargetSpeakerTuning.minRecordingCoherenceKey)
        defaults.set(0.9, forKey: TargetSpeakerTuning.minCrossRecordingSimilarityKey)
        let overridden = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(overridden.uncertainSimilarityFloor, 0.51, accuracy: 0.0001)
        XCTAssertEqual(overridden.uncertainContinuityThreshold, 0.58, accuracy: 0.0001)
        XCTAssertEqual(overridden.minRecordingCoherence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(overridden.minCrossRecordingSimilarity, 0.9, accuracy: 0.0001)

        // 0 is a meaningful, valid value (disables the check) -- must not be confused with "key
        // absent" the way `double(forKey:)` would if used directly.
        defaults.set(0.0, forKey: TargetSpeakerTuning.minRecordingCoherenceKey)
        defaults.set(0.0, forKey: TargetSpeakerTuning.minCrossRecordingSimilarityKey)
        let disabled = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(disabled.minRecordingCoherence, 0.0, accuracy: 0.0001)
        XCTAssertEqual(disabled.minCrossRecordingSimilarity, 0.0, accuracy: 0.0001)

        defaults.set(1.5, forKey: TargetSpeakerTuning.minRecordingCoherenceKey)
        defaults.set(Double.nan, forKey: TargetSpeakerTuning.minCrossRecordingSimilarityKey)
        let invalid = TargetSpeakerTuning.resolved(from: defaults)
        XCTAssertEqual(invalid.minRecordingCoherence, 0.47, accuracy: 0.0001, "out-of-range must fall back")
        XCTAssertEqual(invalid.minCrossRecordingSimilarity, 0.40, accuracy: 0.0001, "non-finite must fall back")
    }

    /// Case (a) part 1: a recording whose windows all agree with each other (one speaker) sails
    /// through `createProfile`'s coherence check.
    func testCreateProfileAcceptsCoherentRecordings() async throws {
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 48)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let profile = try await filter.createProfile(from: [recording, recording], store: InMemoryTargetSpeakerProfileStore())
        XCTAssertEqual(profile.embeddings.count, 30)
    }

    /// Case (a) part 2: a recording built from two clearly different embedding clusters (e.g. a
    /// second voice, or heavy noise, contaminating half the windows) must be rejected with the new
    /// `lowRecordingCoherence` error rather than silently entering the profile.
    func testCreateProfileRejectsInternallyIncoherentRecording() async throws {
        // 48 voiced frames yield 15 candidate windows (matches the existing two-hundred-window
        // math elsewhere in this file); the mock clamps to its last element once the scripted
        // list is exhausted, giving a 7-A/8-B split -- a clean two-cluster recording.
        let model = MockTargetSpeakerModel(
            embeddings: Array(repeating: unitVector(), count: 7) + [vector(withCosine: 0)],
            frameCount: 48
        )
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)

        do {
            _ = try await filter.createProfile(from: [recording, recording], store: InMemoryTargetSpeakerProfileStore())
            XCTFail("an internally incoherent recording must be rejected")
        } catch let error as TargetSpeakerEnrollmentError {
            guard case .lowRecordingCoherence(let index, let measured, let floor) = error else {
                XCTFail("expected lowRecordingCoherence, got \(error)")
                return
            }
            XCTAssertEqual(index, 0, "the first recording processed by createProfile's loop is the one that failed")
            XCTAssertLessThan(measured, floor)
            XCTAssertEqual(floor, 0.47, accuracy: 0.001)
        }
    }

    /// Case (b): the two enrollment recordings are deliberately captured in different postures, so
    /// their embeddings legitimately differ -- 0.5 similarity here is far below the 0.62 cosine
    /// gate threshold but must still clear the conservative 0.40 cross-recording default. This is
    /// exactly the "lying down vs. sitting" scenario the calibration constraint protects.
    func testModeratelyDissimilarPostureRecordingsPassCrossRecordingCheckAtDefaultFloor() async throws {
        // First 15 embedding calls (recording 0's windows) get the all-unitVector prefix; the next
        // 15 (recording 1's windows) get the all-0.5-cosine suffix -- no clamping needed since the
        // scripted list length (30) exactly matches the total window count across both recordings.
        let embeddings = Array(repeating: unitVector(), count: 15) + Array(repeating: vector(withCosine: 0.5), count: 15)
        let model = MockTargetSpeakerModel(embeddings: embeddings, frameCount: 48)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)

        let profile = try await filter.createProfile(from: [recording, recording], store: InMemoryTargetSpeakerProfileStore())
        XCTAssertEqual(profile.embeddings.count, 30, "0.5 cross-recording similarity must clear the 0.40 default floor")
    }

    /// Case (c) part 1: setting the coherence floor to 0 disables that check entirely, even for a
    /// recording that would otherwise fail it.
    func testZeroDisablesRecordingCoherenceCheck() async throws {
        let model = MockTargetSpeakerModel(
            embeddings: Array(repeating: unitVector(), count: 7) + [vector(withCosine: 0)],
            frameCount: 48
        )
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let tuning = TargetSpeakerTuning(cosineThreshold: 0.62, vadThreshold: 0.70, minRecordingCoherence: 0)

        let profile = try await filter.createProfile(
            from: [recording, recording], store: InMemoryTargetSpeakerProfileStore(), tuning: tuning
        )
        XCTAssertEqual(profile.embeddings.count, 30)
    }

    /// Case (c) part 2: setting the cross-recording floor to 0 disables that check entirely, even
    /// for two recordings that are structurally orthogonal (cosine 0, far below any positive
    /// floor).
    func testZeroDisablesCrossRecordingCheck() async throws {
        let embeddings = Array(repeating: unitVector(), count: 15) + Array(repeating: vector(withCosine: 0), count: 15)
        let model = MockTargetSpeakerModel(embeddings: embeddings, frameCount: 48)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 48 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let tuning = TargetSpeakerTuning(cosineThreshold: 0.62, vadThreshold: 0.70, minCrossRecordingSimilarity: 0)

        let profile = try await filter.createProfile(
            from: [recording, recording], store: InMemoryTargetSpeakerProfileStore(), tuning: tuning
        )
        XCTAssertEqual(profile.embeddings.count, 30)
    }

    /// Case (e): a profile already in the store predates these checks and must keep working
    /// unconditionally -- only *new* recordings are validated, never existing stored profiles.
    func testExistingStoredProfileStaysCompatibleRegardlessOfCoherence() throws {
        var clusterB = [Float](repeating: 0, count: TargetSpeakerProfile.expectedEmbeddingDimension)
        clusterB[1] = 1
        let legacyProfile = try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [unitVector(), unitVector(), clusterB, clusterB]
        )
        // Sanity check: this profile would fail the new coherence floor if it were ever checked.
        XCTAssertLessThan(TargetSpeakerFilter.recordingCoherence(legacyProfile.embeddings), 0.55)

        let store = InMemoryTargetSpeakerProfileStore()
        try store.save(legacyProfile)

        let loaded = try store.load()
        XCTAssertEqual(loaded, legacyProfile)
        XCTAssertTrue(loaded?.isCompatible(with: FluidAudioTargetSpeakerModel.identifier, audioProcessingMode: .off) == true)
    }

    func testNoMatchSkipsAllPostProcessing() {
        XCTAssertTrue(TargetSpeakerOutputGate.shouldSkipPostProcessing(featureEnabled: true, acceptedSampleCount: 0))
        XCTAssertFalse(TargetSpeakerOutputGate.shouldSkipPostProcessing(featureEnabled: true, acceptedSampleCount: 1))
        XCTAssertFalse(TargetSpeakerOutputGate.shouldSkipPostProcessing(featureEnabled: false, acceptedSampleCount: 0))
    }

    private func unitVector() -> [Float] { [1] + [Float](repeating: 0, count: 255) }

    private func vector(withCosine cosine: Float) -> [Float] {
        [cosine, sqrt(1 - (cosine * cosine))] + [Float](repeating: 0, count: 254)
    }

    private func makeProfile(embedding: [Float]? = nil) throws -> TargetSpeakerProfile {
        try TargetSpeakerProfile(
            modelIdentifier: FluidAudioTargetSpeakerModel.identifier,
            embeddings: [embedding ?? unitVector()]
        )
    }
}

private final class MockTargetSpeakerModel: TargetSpeakerModelProvider, @unchecked Sendable {
    let modelIdentifier = FluidAudioTargetSpeakerModel.identifier
    private let frameStates: [Bool]
    private let shouldThrow: Bool
    private let embeddings: [[Float]]
    private(set) var windowLengths: [Int] = []
    private var embeddingIndex = 0
    private let lock = NSLock()

    init(embedding: [Float] = [1] + [Float](repeating: 0, count: 255), frameCount: Int = 8, shouldThrow: Bool = false) {
        self.frameStates = Array(repeating: true, count: frameCount)
        self.shouldThrow = shouldThrow
        self.embeddings = [embedding]
    }

    init(embedding: [Float], frameStates: [Bool]) {
        self.frameStates = frameStates
        self.shouldThrow = false
        self.embeddings = [embedding]
    }

    init(embeddings: [[Float]], frameCount: Int) {
        self.frameStates = Array(repeating: true, count: frameCount)
        self.shouldThrow = false
        self.embeddings = embeddings
    }

    init(embeddings: [[Float]], frameStates: [Bool]) {
        self.frameStates = frameStates
        self.shouldThrow = false
        self.embeddings = embeddings
    }

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {
        if shouldThrow { throw TargetSpeakerModelError.notPrepared }
        progressHandler?(TargetSpeakerPreparationProgress(phase: .preparing, fractionCompleted: nil, message: "preparing"))
        progressHandler?(TargetSpeakerPreparationProgress(phase: .ready, fractionCompleted: 1, message: "ready"))
    }

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        if shouldThrow { throw TargetSpeakerModelError.notPrepared }
        return frameStates.map { TargetSpeakerVADFrame(isVoiceActive: $0, probability: $0 ? 1 : 0) }
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        if shouldThrow { throw TargetSpeakerModelError.notPrepared }
        return nextEmbedding(for: samples.count)
    }

    private func nextEmbedding(for length: Int) -> [Float] {
        lock.lock()
        windowLengths.append(length)
        let value = embeddings[min(embeddingIndex, embeddings.count - 1)]
        embeddingIndex += 1
        lock.unlock()
        return value
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [TargetSpeakerPreparationProgress.Phase] = []

    var values: [TargetSpeakerPreparationProgress.Phase] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func append(_ phase: TargetSpeakerPreparationProgress.Phase) {
        lock.lock()
        collected.append(phase)
        lock.unlock()
    }
}
