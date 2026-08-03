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
        unsupportedSchema["schemaVersion"] = 2
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
            embedding: vector(withCosine: 0.61), frameCount: 8
        )).filter(samples: samples, profile: profile, enabled: true)
        XCTAssertEqual(rejected.acceptedSampleCount, 0)
        XCTAssertTrue(rejected.samples.allSatisfy { $0 == 0 })

        let accepted = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: vector(withCosine: 0.62), frameCount: 8
        )).filter(samples: samples, profile: profile, enabled: true)
        XCTAssertGreaterThan(accepted.acceptedSampleCount, 0)
    }

    func testUtteranceDecisionUsesMedianNotMaximum() async throws {
        let samples = Array(repeating: Float(0.25), count: 12 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let model = MockTargetSpeakerModel(
            embeddings: [vector(withCosine: 0.95), vector(withCosine: 0.61), vector(withCosine: 0.61)],
            frameCount: 12
        )
        let result = await TargetSpeakerFilter(model: model).filter(
            samples: samples,
            profile: try makeProfile(),
            enabled: true
        )
        XCTAssertEqual(result.acceptedSampleCount, 0, "max-score acceptance would incorrectly accept this utterance")
        XCTAssertEqual(model.windowLengths, [24_000, 24_000, 24_000])
    }

    func testIndependentShortUtteranceIsRejected() async throws {
        let samples = Array(repeating: Float(0.25), count: 3 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let result = await TargetSpeakerFilter(model: MockTargetSpeakerModel(
            embedding: unitVector(), frameCount: 3
        )).filter(samples: samples, profile: try makeProfile(), enabled: true)
        XCTAssertEqual(result.acceptedSampleCount, 0)
        XCTAssertTrue(result.samples.allSatisfy { $0 == 0 })
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

    func testEnrollmentRequiresExactlyOneSampleWithThirtySecondMaximum() async throws {
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 24)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 24 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let store = InMemoryTargetSpeakerProfileStore()

        do {
            _ = try await filter.createProfile(from: [], store: store)
            XCTFail("zero recordings must be rejected")
        } catch {
            XCTAssertEqual(error as? TargetSpeakerEnrollmentError, .requiresExactlyOneSample)
        }
        let profile = try await filter.createProfile(
            from: [recording], store: store
        )
        XCTAssertEqual(profile.embeddings.count, 7)
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
        let model = MockTargetSpeakerModel(embedding: unitVector(), frameCount: 24)
        let filter = TargetSpeakerFilter(model: model)
        let recording = Array(repeating: Float(0.2), count: 24 * TargetSpeakerFilterConfiguration.vadFrameSamples)
        let collector = ProgressCollector()
        let handler: TargetSpeakerProgressHandler = { progress in collector.append(progress.phase) }
        _ = try await filter.createProfile(
            from: [recording],
            store: InMemoryTargetSpeakerProfileStore(),
            progressHandler: handler
        )
        XCTAssertTrue(collector.values.contains(.preparing))
        XCTAssertTrue(collector.values.contains(.ready))
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
