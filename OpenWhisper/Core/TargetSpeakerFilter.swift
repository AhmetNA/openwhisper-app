import Accelerate
import Foundation
import FluidAudio

struct TargetSpeakerFilterConfiguration: Sendable {
    static let sampleRate = 16_000
    static let vadFrameSamples = 4_096 // 256 ms at 16 kHz
    static let speakerWindowSamples = 24_000 // 1.5 s minimum
    static let speakerWindowHopSamples = 12_000 // 50% overlap
    static let shortAdjacencySamples = 8_000 // 500 ms
    static let acceptedPaddingSamples = 4_000 // 250 ms
    static let edgeFadeSamples = 160 // 10 ms
    /// FluidAudio embeddings are speaker-oriented but not pitch-invariant enough to use a
    /// strict 0.70 cutoff for the same person speaking in a low or high register. The profile
    /// still compares against every enrolled embedding and runtime decisions are now made per
    /// speaker window, so this moderate relaxation preserves protection against one-window outliers.
    /// This is now the *default* value only -- it can be overridden at runtime via the
    /// `targetSpeakerCosineThreshold` UserDefaults key without a rebuild (see `TargetSpeakerTuning`).
    static let cosineThreshold: Float = 0.62
    /// Scores in this band are not safe enough for an automatic identity decision, but can be
    /// rescued when they are acoustically continuous with a strong target-speaker window. If a
    /// recording contains only uncertain windows, it remains a user-confirmed fallback instead of
    /// being silently accepted as the target speaker.
    static let uncertainSimilarityFloor: Float = 0.50
    /// Minimum embedding similarity between an uncertain window and a nearby strong target window
    /// before it can be included. This protects the pitch-variation bridge from absorbing a second
    /// speaker merely because that speaker happened to be adjacent in time.
    static let uncertainContinuityThreshold: Float = 0.55
    /// At a 0.75 s hop, two windows span at most one 1.5 s speaker window on either side. Keeping
    /// the bridge bounded prevents a long run of ambiguous audio from being promoted wholesale.
    static let maximumUncertainBridgeWindows = 2
    /// Default VAD activity-detection threshold passed to `VadConfig`. Overridable at runtime
    /// via the `targetSpeakerVadThreshold` UserDefaults key (see `TargetSpeakerTuning`).
    static let vadThreshold: Float = 0.70
    /// Push-to-talk means the user is physically holding the hotkey down for the entire
    /// recording, so a short standalone utterance (a voice command like "durdur" or "sonraki")
    /// is overwhelmingly likely to be theirs even though it is too short to reach
    /// `speakerWindowSamples` and therefore cannot be identity-scored at all. When *nothing* in
    /// the recording is long enough to score, and the total voiced duration is at or below this
    /// ceiling, `filter(...)` accepts every voice run without scoring instead of structurally
    /// rejecting it. Overridable at runtime via the `targetSpeakerShortUtteranceMaxSeconds`
    /// UserDefaults key (see `TargetSpeakerTuning`). Setting it to 0 disables the bypass.
    static let shortUtteranceMaxSeconds: Double = 2.0
    /// A single microphone position is not enough: posture changes the acoustic path to
    /// the microphone. Keep two recordings from different conditions in the profile.
    static let requiredEnrollmentSampleCount = 2
    static let maximumEnrollmentDuration: TimeInterval = 30
    static let minimumPerRecordingSpeechSeconds: TimeInterval = 10
    /// A confirmation can contribute only a small, evenly spread set of embeddings. The normal
    /// two-recording enrollment remains the primary profile-building path.
    static let maximumConfirmedCandidateEmbeddings = 10
    static let maximumProfileEmbeddings = 300
    /// Relative classification is deliberately stricter than merely finding the best profile
    /// score: the anchor must be plausible, and the target/outside clusters must be visibly
    /// separated before any audio is accepted automatically.
    static let relativeAnchorMinimum: Float = 0.50
    static let relativeTargetSimilarity: Float = 0.55
    static let relativeUncertainSimilarity: Float = 0.40
    static let relativeClusterSeparation: Float = 0.25
    /// Within-recording coherence floor: the median of all pairwise cosine similarities among a
    /// single recording's speaker-window embeddings (see `TargetSpeakerFilter.recordingCoherence`).
    /// A recording contaminated by a second speaker, a TV, or heavy noise produces windows that
    /// disagree with each other even though each individual window might still look plausible on
    /// its own, and quantity/clipping checks alone (`TargetSpeakerEnrollmentResult.isValid`) never
    /// catch that. Default only -- overridable at runtime via the
    /// `targetSpeakerMinRecordingCoherence` UserDefaults key (see `TargetSpeakerTuning`). This
    /// value has never been validated against this user's real voice/hardware; watch the
    /// `[TargetSpeaker] enroll coherence:` log lines and retune with
    /// `defaults write` if it misfires. Setting it to 0 disables the check.
    static let minRecordingCoherence: Double = 0.55
    /// Cross-recording consistency floor comparing the two enrollment recordings' embedding sets
    /// against each other (see `TargetSpeakerFilter.crossRecordingSimilarity`). Deliberately
    /// conservative -- default 0.40, well below the 0.62 cosine gate threshold -- because the two
    /// enrollment recordings are captured in different postures/conditions on purpose, which
    /// legitimately depresses their similarity. This floor is calibrated to catch only "these look
    /// like different people", never "these aren't similar enough"; a floor set too high makes
    /// enrollment impossible, which is a worse bug than the one this check fixes. Default only --
    /// overridable at runtime via the `targetSpeakerMinCrossRecordingSimilarity` UserDefaults key
    /// (see `TargetSpeakerTuning`). Setting it to 0 disables the check.
    static let minCrossRecordingSimilarity: Double = 0.40
}

/// Resolved runtime tuning for the target-speaker gate. Values default to
/// `TargetSpeakerFilterConfiguration`'s constants and can be overridden without a rebuild via
/// `defaults write com.openwhisper.app <key> <value>`. `filter(...)` resolves this once at the
/// top of the call instead of scattering `UserDefaults.standard` reads through the algorithm --
/// which also makes the thresholds trivially injectable in tests.
struct TargetSpeakerTuning: Sendable, Equatable {
    static let cosineThresholdKey = "targetSpeakerCosineThreshold"
    static let uncertainSimilarityFloorKey = "targetSpeakerUncertainSimilarityFloor"
    static let uncertainContinuityThresholdKey = "targetSpeakerUncertainContinuityThreshold"
    static let vadThresholdKey = "targetSpeakerVadThreshold"
    static let shortUtteranceMaxSecondsKey = "targetSpeakerShortUtteranceMaxSeconds"
    static let minRecordingCoherenceKey = "targetSpeakerMinRecordingCoherence"
    static let minCrossRecordingSimilarityKey = "targetSpeakerMinCrossRecordingSimilarity"

    let cosineThreshold: Float
    let uncertainSimilarityFloor: Float
    let uncertainContinuityThreshold: Float
    let vadThreshold: Float
    let shortUtteranceMaxSeconds: Double
    let minRecordingCoherence: Double
    let minCrossRecordingSimilarity: Double

    /// Explicit memberwise init (rather than the compiler-synthesized one) so existing call
    /// sites/tests that only pass `cosineThreshold`/`vadThreshold` keep compiling unchanged
    /// while still being able to inject a short-utterance ceiling, a coherence floor, or a
    /// cross-recording floor when a test needs to.
    init(
        cosineThreshold: Float,
        vadThreshold: Float,
        uncertainSimilarityFloor: Float = TargetSpeakerFilterConfiguration.uncertainSimilarityFloor,
        uncertainContinuityThreshold: Float = TargetSpeakerFilterConfiguration.uncertainContinuityThreshold,
        shortUtteranceMaxSeconds: Double = TargetSpeakerFilterConfiguration.shortUtteranceMaxSeconds,
        minRecordingCoherence: Double = TargetSpeakerFilterConfiguration.minRecordingCoherence,
        minCrossRecordingSimilarity: Double = TargetSpeakerFilterConfiguration.minCrossRecordingSimilarity
    ) {
        self.cosineThreshold = cosineThreshold
        self.vadThreshold = vadThreshold
        self.uncertainSimilarityFloor = uncertainSimilarityFloor
        self.uncertainContinuityThreshold = uncertainContinuityThreshold
        self.shortUtteranceMaxSeconds = shortUtteranceMaxSeconds
        self.minRecordingCoherence = minRecordingCoherence
        self.minCrossRecordingSimilarity = minCrossRecordingSimilarity
    }

    static let defaultValue = TargetSpeakerTuning(
        cosineThreshold: TargetSpeakerFilterConfiguration.cosineThreshold,
        vadThreshold: TargetSpeakerFilterConfiguration.vadThreshold
    )

    /// Reads all tuning values from `defaults`. An absent key, a non-finite value, or a value
    /// outside the valid range silently falls back to the documented default -- a bad
    /// `defaults write` must never crash the app or destabilize the gate.
    static func resolved(from defaults: UserDefaults = .standard) -> TargetSpeakerTuning {
        TargetSpeakerTuning(
            cosineThreshold: resolvedValue(
                defaults: defaults,
                key: cosineThresholdKey,
                fallback: TargetSpeakerFilterConfiguration.cosineThreshold
            ),
            vadThreshold: resolvedValue(
                defaults: defaults,
                key: vadThresholdKey,
                fallback: TargetSpeakerFilterConfiguration.vadThreshold
            ),
            uncertainSimilarityFloor: resolvedValue(
                defaults: defaults,
                key: uncertainSimilarityFloorKey,
                fallback: TargetSpeakerFilterConfiguration.uncertainSimilarityFloor
            ),
            uncertainContinuityThreshold: resolvedValue(
                defaults: defaults,
                key: uncertainContinuityThresholdKey,
                fallback: TargetSpeakerFilterConfiguration.uncertainContinuityThreshold
            ),
            shortUtteranceMaxSeconds: resolvedShortUtteranceMaxSeconds(defaults: defaults),
            minRecordingCoherence: resolvedSimilarityFloor(
                defaults: defaults,
                key: minRecordingCoherenceKey,
                fallback: TargetSpeakerFilterConfiguration.minRecordingCoherence
            ),
            minCrossRecordingSimilarity: resolvedSimilarityFloor(
                defaults: defaults,
                key: minCrossRecordingSimilarityKey,
                fallback: TargetSpeakerFilterConfiguration.minCrossRecordingSimilarity
            )
        )
    }

    private static func resolvedValue(defaults: UserDefaults, key: String, fallback: Float) -> Float {
        // object(forKey:) distinguishes "key absent" from "explicitly set to 0" -- double(forKey:)
        // alone returns 0 for both, which would silently defeat the fallback.
        guard defaults.object(forKey: key) != nil else { return fallback }
        let raw = defaults.double(forKey: key)
        guard raw.isFinite, (0.0...1.0).contains(raw) else { return fallback }
        return Float(raw)
    }

    /// Same absent-vs-zero distinction as `resolvedValue`, but this is a duration in seconds, not
    /// a 0...1 similarity/probability, so it is validated separately: reject non-finite and
    /// negative values only. Zero is a valid, meaningful value here -- it disables the bypass.
    private static func resolvedShortUtteranceMaxSeconds(defaults: UserDefaults) -> Double {
        let fallback = TargetSpeakerFilterConfiguration.shortUtteranceMaxSeconds
        guard defaults.object(forKey: shortUtteranceMaxSecondsKey) != nil else { return fallback }
        let raw = defaults.double(forKey: shortUtteranceMaxSecondsKey)
        guard raw.isFinite, raw >= 0 else { return fallback }
        return raw
    }

    /// Coherence/cross-recording floors are 0...1 similarity scores where 0 is both a valid value
    /// (it disables the corresponding check, per the same absent-vs-zero distinction as
    /// `resolvedValue`) and already the bottom of the valid range, so no special-casing is needed
    /// beyond the existing range check -- an explicit 0 simply passes it.
    private static func resolvedSimilarityFloor(defaults: UserDefaults, key: String, fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let raw = defaults.double(forKey: key)
        guard raw.isFinite, (0.0...1.0).contains(raw) else { return fallback }
        return raw
    }
}

struct TargetSpeakerVADFrame: Sendable {
    let isVoiceActive: Bool
    let probability: Float
}

struct TargetSpeakerPreparationProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case listing
        case downloading
        case compiling
        case preparing
        case ready
    }

    let phase: Phase
    let fractionCompleted: Double?
    let message: String
}

typealias TargetSpeakerProgressHandler = @Sendable (TargetSpeakerPreparationProgress) -> Void

protocol TargetSpeakerModelProvider: AnyObject, Sendable {
    var modelIdentifier: String { get }
    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws
    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame]
    func embedding(for samples: [Float]) async throws -> [Float]
}

enum TargetSpeakerModelError: Error, LocalizedError {
    case notPrepared
    case invalidEmbedding

    var errorDescription: String? {
        switch self {
        case .notPrepared: "Ses eşleştirme modeli hazır değil"
        case .invalidEmbedding: "Ses eşleştirme modeli geçersiz embedding döndürdü"
        }
    }
}

final class FluidAudioTargetSpeakerModel: TargetSpeakerModelProvider, @unchecked Sendable {
    static let identifier = "FluidAudio-Diarizer-v0.12.4"

    let modelIdentifier = FluidAudioTargetSpeakerModel.identifier
    private let runtime = FluidAudioTargetSpeakerRuntime()

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {
        try await runtime.prepare(progressHandler: progressHandler)
    }

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        try await runtime.vadFrames(for: samples)
    }

    func embedding(for samples: [Float]) async throws -> [Float] {
        try await runtime.embedding(for: samples)
    }
}

private actor FluidAudioTargetSpeakerRuntime {
    private var diarizer: DiarizerManager?
    private var vad: VadManager?
    private var preparationTask: Task<Void, Error>?

    func prepare(progressHandler: TargetSpeakerProgressHandler?) async throws {
        if diarizer != nil && vad != nil { return }
        if let preparationTask {
            try await preparationTask.value
            return
        }

        let task = Task { [weak self] () throws -> Void in
            guard let self else { return }
            try await self.load(progressHandler: progressHandler)
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    private func load(progressHandler: TargetSpeakerProgressHandler?) async throws {
        progressHandler?(TargetSpeakerPreparationProgress(
            phase: .preparing,
            fractionCompleted: nil,
            message: "Ses eşleştirme modeli hazırlanıyor…"
        ))
        let models = try await DiarizerModels.downloadIfNeeded { progress in
            let phase: TargetSpeakerPreparationProgress.Phase
            let message: String
            switch progress.phase {
            case .listing:
                phase = .listing
                message = "Model dosyaları listeleniyor…"
            case .downloading:
                phase = .downloading
                message = "Ses eşleştirme modeli indiriliyor…"
            case .compiling:
                phase = .compiling
                message = "Ses eşleştirme modeli derleniyor…"
            }
            progressHandler?(TargetSpeakerPreparationProgress(
                phase: phase,
                fractionCompleted: progress.fractionCompleted,
                message: message
            ))
        }
        let diarizer = DiarizerManager(config: DiarizerConfig(
            clusteringThreshold: 0.70,
            minSpeechDuration: 1.5,
            minEmbeddingUpdateDuration: 1.5,
            minSilenceGap: 0.5,
            chunkDuration: 10,
            chunkOverlap: 1
        ))
        diarizer.initialize(models: models)
        let tuning = TargetSpeakerTuning.resolved()
        owLog(String(format: "[TargetSpeaker] preparing VAD model vadThreshold=%.3f", tuning.vadThreshold))
        let vad = try await VadManager(config: VadConfig(defaultThreshold: tuning.vadThreshold)) { progress in
            progressHandler?(TargetSpeakerPreparationProgress(
                phase: .compiling,
                fractionCompleted: progress.fractionCompleted,
                message: "Ses etkinliği modeli hazırlanıyor…"
            ))
        }
        self.diarizer = diarizer
        self.vad = vad
        progressHandler?(TargetSpeakerPreparationProgress(
            phase: .ready,
            fractionCompleted: 1,
            message: "Ses eşleştirme hazır"
        ))
    }

    func vadFrames(for samples: [Float]) async throws -> [TargetSpeakerVADFrame] {
        guard let vad else { throw TargetSpeakerModelError.notPrepared }
        return try await vad.process(samples).map {
            TargetSpeakerVADFrame(isVoiceActive: $0.isVoiceActive, probability: $0.probability)
        }
    }

    func embedding(for samples: [Float]) throws -> [Float] {
        guard let diarizer else { throw TargetSpeakerModelError.notPrepared }
        let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        guard embedding.count == TargetSpeakerProfile.expectedEmbeddingDimension,
              embedding.allSatisfy({ $0.isFinite }) else {
            throw TargetSpeakerModelError.invalidEmbedding
        }
        return embedding
    }
}

struct TargetSpeakerEnrollmentResult: Sendable {
    let voicedDuration: TimeInterval
    let clippedSampleRatio: Double
    let embeddings: [[Float]]

    var isValid: Bool {
        voicedDuration >= TargetSpeakerFilterConfiguration.minimumPerRecordingSpeechSeconds
            && clippedSampleRatio <= 0.01
            && !embeddings.isEmpty
    }
}

enum TargetSpeakerRelativeClassification: String, Sendable, Equatable {
    case target
    case uncertain
    case other

    var logName: String { rawValue }
}

/// Window metadata retained when the filter has one coherent, target-like recording that was
/// not strong enough for automatic acceptance. The original sample buffer is carried separately
/// by `TargetSpeakerConfirmationCandidate.samples`; these ranges let the caller explain exactly
/// what will be appended and keep non-candidate audio out of the explicit learning path.
struct TargetSpeakerConfirmationWindow: Sendable, Equatable {
    let startSample: Int
    let endSample: Int
    let profileScore: Float
    let anchorSimilarity: Float
    let classification: TargetSpeakerRelativeClassification
}

struct TargetSpeakerConfirmationCandidate: Sendable, Equatable {
    /// Original-rate samples masked to the coherent candidate windows. It is intentionally not
    /// the whole rejected recording: confirmation can only append the audio that formed the
    /// internally coherent single-speaker cluster.
    let samples: [Float]
    let windows: [TargetSpeakerConfirmationWindow]
    let internalCoherence: Float
    let anchorProfileScore: Float
    let separation: Float?
    let separationReason: String
}

/// A successful append carries the previous profile so the caller can implement the existing
/// "last addition" undo affordance by restoring it through the same profile store. The receipt is
/// intentionally immutable and contains no audio or secret material beyond the profile snapshots.
struct TargetSpeakerProfileAppendReceipt: Sendable {
    let previousProfile: TargetSpeakerProfile
    let appendedProfile: TargetSpeakerProfile
}

enum TargetSpeakerEnrollmentError: Error, LocalizedError, Equatable {
    case requiresMultipleSamples
    case invalidSample(index: Int)
    case sampleExceedsMaximumDuration
    case profileSaveFailed(String)
    case profileCapacityExceeded
    /// A single recording's speaker-window embeddings disagree with each other more than
    /// `TargetSpeakerTuning.minRecordingCoherence` allows -- likely more than one voice, or heavy
    /// noise, in that recording. `measured`/`floor` are carried on the error so the Turkish message
    /// can quote the actual numbers instead of being a generic rejection.
    case lowRecordingCoherence(index: Int, measured: Float, floor: Float)
    /// The two enrollment recordings' embedding sets don't look like the same person, per
    /// `TargetSpeakerTuning.minCrossRecordingSimilarity`.
    case crossRecordingMismatch(measured: Float, floor: Float)
    case profileUndoConflict

    var errorDescription: String? {
        switch self {
        case .requiresMultipleSamples: "İki farklı pozisyondan ses kaydı gerekli"
        case .invalidSample(let index): "Ses kaydı \(index + 1) yeterli konuşma veya kalite koşulunu karşılamıyor"
        case .sampleExceedsMaximumDuration: "Ses kaydı en fazla 30 saniye olabilir"
        case .profileSaveFailed(let message): "Ses profili kaydedilemedi: \(message)"
        case .profileCapacityExceeded: "Ses profili dolu; yeni kayıt eklenemedi. Ayarlar'dan profili yeniden oluşturun."
        case .lowRecordingCoherence(let index, let measured, let floor):
            "Ses kaydı \(index + 1) birden fazla konuşmacı veya çok fazla gürültü içeriyor gibi görünüyor"
                + " (tutarlılık: \(String(format: "%.2f", measured)), gereken en az: \(String(format: "%.2f", floor)));"
                + " sessiz bir ortamda aynı pozisyonda yeniden kaydedin."
        case .crossRecordingMismatch(let measured, let floor):
            "İki kayıt aynı kişiye ait görünmüyor"
                + " (benzerlik: \(String(format: "%.2f", measured)), gereken en az: \(String(format: "%.2f", floor)));"
                + " her iki kaydı da aynı kişiden, sessiz bir ortamda yeniden alın."
        case .profileUndoConflict:
            "Ses profili değişti; son ekleme geri alınamadı"
        }
    }
}

extension TargetSpeakerFilter {
    func validateEnrollmentSample(
        _ samples: [Float],
        progressHandler: TargetSpeakerProgressHandler? = nil
    ) async throws -> TargetSpeakerEnrollmentResult {
        try await enroll(samples: samples, progressHandler: progressHandler)
    }

    func createProfile(
        from recordings: [[Float]],
        store: TargetSpeakerProfileStore,
        progressHandler: TargetSpeakerProgressHandler? = nil,
        tuning: TargetSpeakerTuning = .resolved()
    ) async throws -> TargetSpeakerProfile {
        guard recordings.count == TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount else {
            throw TargetSpeakerEnrollmentError.requiresMultipleSamples
        }

        try Task.checkCancellation()
        // Kept per-recording (rather than flattened immediately) so the cross-recording check
        // below can compare recording 0's embeddings against recording 1's after the loop.
        var perRecordingEmbeddings: [[[Float]]] = []
        for (index, recording) in recordings.enumerated() {
            progressHandler?(TargetSpeakerPreparationProgress(
                phase: .preparing,
                fractionCompleted: Double(index) / Double(recordings.count),
                message: "\(index + 1)/\(recordings.count) ses kaydı analiz ediliyor…"
            ))
            let result = try await enroll(samples: recording, progressHandler: progressHandler)
            try Task.checkCancellation()
            guard result.isValid else {
                throw TargetSpeakerEnrollmentError.invalidSample(index: index)
            }

            // Always measure and log, whether or not the check is enabled/fails -- these floors
            // are unvalidated guesses and the user needs the real numbers in the log to retune
            // them with `defaults write`, not just a pass/fail verdict.
            let coherence = Self.recordingCoherence(result.embeddings)
            let coherenceFloorNote = tuning.minRecordingCoherence > 0
                ? String(format: "%.3f", tuning.minRecordingCoherence)
                : "0.000 (disabled)"
            owLog(
                "[TargetSpeaker] enroll coherence: recording=\(index) coherence=\(String(format: "%.3f", coherence))"
                    + " floor=\(coherenceFloorNote)"
            )
            if tuning.minRecordingCoherence > 0, coherence < Float(tuning.minRecordingCoherence) {
                throw TargetSpeakerEnrollmentError.lowRecordingCoherence(
                    index: index,
                    measured: coherence,
                    floor: Float(tuning.minRecordingCoherence)
                )
            }

            perRecordingEmbeddings.append(result.embeddings)
        }

        if perRecordingEmbeddings.count == 2 {
            let cross = Self.crossRecordingSimilarity(perRecordingEmbeddings[0], perRecordingEmbeddings[1])
            let crossFloorNote = tuning.minCrossRecordingSimilarity > 0
                ? String(format: "%.3f", tuning.minCrossRecordingSimilarity)
                : "0.000 (disabled)"
            owLog(
                "[TargetSpeaker] enroll cross-recording similarity: similarity=\(String(format: "%.3f", cross))"
                    + " floor=\(crossFloorNote)"
            )
            if tuning.minCrossRecordingSimilarity > 0, cross < Float(tuning.minCrossRecordingSimilarity) {
                throw TargetSpeakerEnrollmentError.crossRecordingMismatch(
                    measured: cross,
                    floor: Float(tuning.minCrossRecordingSimilarity)
                )
            }
        }

        let embeddings = perRecordingEmbeddings.flatMap { $0 }
        let profile = try TargetSpeakerProfile(
            modelIdentifier: model.modelIdentifier,
            embeddings: embeddings
        )
        try Task.checkCancellation()
        do {
            try store.save(profile)
        } catch {
            throw TargetSpeakerEnrollmentError.profileSaveFailed(error.localizedDescription)
        }
        progressHandler?(TargetSpeakerPreparationProgress(
            phase: .ready,
            fractionCompleted: 1,
            message: "Ses profili kaydedildi"
        ))
        return profile
    }

    /// Adds a user-confirmed, ambiguous recording only after it passes the same basic enrollment
    /// quality checks plus an internal-coherence safeguard. Cross-recording similarity is logged
    /// for diagnostics but is deliberately not a gate here: explicit confirmation is the user's
    /// authorization to teach a low-similarity speaking condition, while the within-recording
    /// floor still prevents a mixed-speaker recording from being appended wholesale.
    func appendConfirmedCandidate(
        _ samples: [Float],
        to existingProfile: TargetSpeakerProfile,
        store: TargetSpeakerProfileStore,
        progressHandler: TargetSpeakerProgressHandler? = nil,
        tuning: TargetSpeakerTuning = .resolved()
    ) async throws -> TargetSpeakerProfile {
        try await appendConfirmedCandidateWithReceipt(
            samples,
            to: existingProfile,
            store: store,
            progressHandler: progressHandler,
            tuning: tuning
        ).appendedProfile
    }

    /// Convenience overload for the result returned by `filter(...)`. The candidate metadata is
    /// informational; the sample buffer is re-VADed and re-embedded by the production append
    /// path, so callers cannot bypass its hard coherence/capacity checks by editing metadata.
    func appendConfirmedCandidate(
        _ candidate: TargetSpeakerConfirmationCandidate,
        to existingProfile: TargetSpeakerProfile,
        store: TargetSpeakerProfileStore,
        progressHandler: TargetSpeakerProgressHandler? = nil,
        tuning: TargetSpeakerTuning = .resolved()
    ) async throws -> TargetSpeakerProfile {
        try await appendConfirmedCandidate(
            candidate.samples,
            to: existingProfile,
            store: store,
            progressHandler: progressHandler,
            tuning: tuning
        )
    }

    func appendConfirmedCandidateWithReceipt(
        _ candidate: TargetSpeakerConfirmationCandidate,
        to existingProfile: TargetSpeakerProfile,
        store: TargetSpeakerProfileStore,
        progressHandler: TargetSpeakerProgressHandler? = nil,
        tuning: TargetSpeakerTuning = .resolved()
    ) async throws -> TargetSpeakerProfileAppendReceipt {
        try await appendConfirmedCandidateWithReceipt(
            candidate.samples,
            to: existingProfile,
            store: store,
            progressHandler: progressHandler,
            tuning: tuning
        )
    }

    /// Receipt-returning form of `appendConfirmedCandidate`. Store writes are still performed by
    /// this method; the receipt gives the owner of the last-addition action the exact prior profile
    /// to restore for an undo, without adding a second persistence mechanism.
    func appendConfirmedCandidateWithReceipt(
        _ samples: [Float],
        to existingProfile: TargetSpeakerProfile,
        store: TargetSpeakerProfileStore,
        progressHandler: TargetSpeakerProgressHandler? = nil,
        tuning: TargetSpeakerTuning = .resolved()
    ) async throws -> TargetSpeakerProfileAppendReceipt {
        guard existingProfile.isCompatible(with: model.modelIdentifier) else {
            throw TargetSpeakerModelError.invalidEmbedding
        }
        guard existingProfile.embeddings.count < TargetSpeakerFilterConfiguration.maximumProfileEmbeddings else {
            throw TargetSpeakerEnrollmentError.profileCapacityExceeded
        }

        let result = try await enroll(samples: samples, progressHandler: progressHandler)
        guard result.isValid else {
            throw TargetSpeakerEnrollmentError.invalidSample(index: 0)
        }

        let coherence = Self.recordingCoherence(result.embeddings)
        // Unlike the enrollment tuning switch, explicit candidate confirmation must always keep
        // the production safety floor requested for single-speaker appends. A tuning value may
        // raise this floor, but cannot lower or disable it.
        let coherenceFloor = max(
            Float(TargetSpeakerFilterConfiguration.minRecordingCoherence),
            Float(tuning.minRecordingCoherence)
        )
        if coherence < coherenceFloor {
            throw TargetSpeakerEnrollmentError.lowRecordingCoherence(
                index: 0,
                measured: coherence,
                floor: coherenceFloor
            )
        }

        let cross = Self.crossRecordingSimilarity(existingProfile.embeddings, result.embeddings)
        owLog(
            "[TargetSpeaker] confirmed candidate similarity: similarity=\(String(format: "%.3f", cross))"
                + " crossRecordingGate=disabled"
                + " coherence=\(String(format: "%.3f", coherence))"
                + " coherenceFloor=\(String(format: "%.3f", coherenceFloor))"
        )

        let remainingCapacity = TargetSpeakerFilterConfiguration.maximumProfileEmbeddings
            - existingProfile.embeddings.count
        let embeddingsToAppend = Self.evenlySpacedSubset(
            result.embeddings,
            maximumCount: min(
                TargetSpeakerFilterConfiguration.maximumConfirmedCandidateEmbeddings,
                remainingCapacity
            )
        )
        guard !embeddingsToAppend.isEmpty else {
            throw TargetSpeakerEnrollmentError.profileCapacityExceeded
        }

        let profile = try TargetSpeakerProfile(
            modelIdentifier: existingProfile.modelIdentifier,
            embeddings: existingProfile.embeddings + embeddingsToAppend,
            createdAt: existingProfile.createdAt
        )
        try Task.checkCancellation()
        do {
            try store.save(profile)
        } catch {
            throw TargetSpeakerEnrollmentError.profileSaveFailed(error.localizedDescription)
        }
        return TargetSpeakerProfileAppendReceipt(
            previousProfile: existingProfile,
            appendedProfile: profile
        )
    }

    /// Restores the profile that immediately preceded a confirmed append. The identity check
    /// prevents an older receipt from undoing a newer profile change.
    func undoConfirmedAppend(
        _ receipt: TargetSpeakerProfileAppendReceipt,
        store: TargetSpeakerProfileStore
    ) throws {
        guard try store.load() == receipt.appendedProfile else {
            throw TargetSpeakerEnrollmentError.profileUndoConflict
        }
        try store.save(receipt.previousProfile)
    }

    private func enroll(
        samples: [Float],
        progressHandler: TargetSpeakerProgressHandler?
    ) async throws -> TargetSpeakerEnrollmentResult {
        let maximumSamples = Int(
            TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                * Double(TargetSpeakerFilterConfiguration.sampleRate)
        )
        guard samples.count <= maximumSamples else {
            throw TargetSpeakerEnrollmentError.sampleExceedsMaximumDuration
        }
        try await model.prepare(progressHandler: progressHandler)
        let frames = try await model.vadFrames(for: samples)
        let voiceRuns = Self.voiceRuns(frames: frames, sampleCount: samples.count)
        let voicedSamples = voiceRuns.reduce(0) { $0 + ($1.end - $1.start) }
        let clipped = samples.reduce(into: 0) { count, sample in
            if abs(sample) >= 0.999 { count += 1 }
        }

        var embeddings: [[Float]] = []
        for run in voiceRuns where run.end - run.start >= TargetSpeakerFilterConfiguration.speakerWindowSamples {
            var start = run.start
            while start + TargetSpeakerFilterConfiguration.speakerWindowSamples <= run.end {
                let window = Array(samples[start..<(start + TargetSpeakerFilterConfiguration.speakerWindowSamples)])
                embeddings.append(try await model.embedding(for: window))
                start += TargetSpeakerFilterConfiguration.speakerWindowHopSamples
            }
        }

        let result = TargetSpeakerEnrollmentResult(
            voicedDuration: Double(voicedSamples) / Double(TargetSpeakerFilterConfiguration.sampleRate),
            clippedSampleRatio: samples.isEmpty ? 0 : Double(clipped) / Double(samples.count),
            embeddings: embeddings
        )
        owLog(String(
            format: "[TargetSpeaker] enroll: voiced=%.2fs clipped=%.2f%% embeddings=%d",
            result.voicedDuration, result.clippedSampleRatio * 100, result.embeddings.count
        ))
        return result
    }

    private static func evenlySpacedSubset<T>(_ values: [T], maximumCount: Int) -> [T] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        guard maximumCount > 1 else { return [values[values.count / 2]] }
        return (0..<maximumCount).map { index in
            let position = Double(index) / Double(maximumCount - 1)
            let sourceIndex = Int((position * Double(values.count - 1)).rounded())
            return values[sourceIndex]
        }
    }
}

enum TargetSpeakerFilterDecision: Sendable, Equatable {
    case disabled
    case accepted
    case partial
    case ambiguous
    /// A coherent single-speaker cluster looked plausibly target-like, but no window cleared the
    /// absolute threshold. The audio is still fail-closed until the user explicitly confirms it.
    case singleSpeakerUncertain
    case rejected
    case noVoice
    case failClosed
}

struct TargetSpeakerFilterResult: Sendable {
    let samples: [Float]
    let acceptedSampleCount: Int
    let hadVoiceActivity: Bool
    let decision: TargetSpeakerFilterDecision
    /// True when the target-speaker gate could not make a reliable decision and therefore
    /// rejected the segment. Never pass unclassified audio through while the feature is on.
    let wasFailClosed: Bool
    let errorDescription: String?
    /// Present only for `singleSpeakerUncertain`. The samples are already masked to the coherent
    /// candidate windows and can be passed to `appendConfirmedCandidate` after user confirmation.
    let confirmationCandidate: TargetSpeakerConfirmationCandidate?

    var hasAcceptedTargetSpeech: Bool { acceptedSampleCount > 0 }
    var candidateSamples: [Float]? { confirmationCandidate?.samples }

    init(
        samples: [Float],
        acceptedSampleCount: Int,
        hadVoiceActivity: Bool,
        decision: TargetSpeakerFilterDecision = .accepted,
        wasFailClosed: Bool,
        errorDescription: String?,
        confirmationCandidate: TargetSpeakerConfirmationCandidate? = nil
    ) {
        self.samples = samples
        self.acceptedSampleCount = acceptedSampleCount
        self.hadVoiceActivity = hadVoiceActivity
        self.decision = decision
        self.wasFailClosed = wasFailClosed
        self.errorDescription = errorDescription
        self.confirmationCandidate = confirmationCandidate
    }
}

final class TargetSpeakerFilter: @unchecked Sendable {
    private let model: TargetSpeakerModelProvider

    init(model: TargetSpeakerModelProvider) {
        self.model = model
    }

    func filter(
        samples: [Float],
        profile: TargetSpeakerProfile?,
        enabled: Bool,
        tuning: TargetSpeakerTuning = .resolved()
    ) async -> TargetSpeakerFilterResult {
        let startTime = Date()
        guard enabled else {
            return TargetSpeakerFilterResult(
                samples: samples,
                acceptedSampleCount: samples.count,
                hadVoiceActivity: true,
                decision: .disabled,
                wasFailClosed: false,
                errorDescription: nil
            )
        }

        guard let profile else {
            let error = "Ses profili bulunamadı; yeniden kayıt gerekli"
            Self.logSummary(
                samples: samples, voiceRunCount: 0, scoredRunCount: 0, acceptedSampleCount: 0,
                decision: "FAIL_CLOSED", wasFailClosed: true, failClosedReason: error,
                tuning: tuning, startTime: startTime
            )
            return Self.failClosed(samples: samples, error: error)
        }

        guard profile.isCompatible(with: model.modelIdentifier) else {
            let error = "Ses profili modeli uyumsuz; yeniden kayıt gerekli"
            Self.logSummary(
                samples: samples, voiceRunCount: 0, scoredRunCount: 0, acceptedSampleCount: 0,
                decision: "FAIL_CLOSED", wasFailClosed: true, failClosedReason: error,
                tuning: tuning, startTime: startTime
            )
            return Self.failClosed(samples: samples, error: error)
        }

        do {
            try await model.prepare(progressHandler: nil)
            let frames = try await model.vadFrames(for: samples)
            let voiceRuns = Self.voiceRuns(frames: frames, sampleCount: samples.count)
            Self.logVoiceRuns(voiceRuns)
            guard !voiceRuns.isEmpty else {
                Self.logSummary(
                    samples: samples, voiceRunCount: 0, scoredRunCount: 0, acceptedSampleCount: 0,
                    decision: "NO_VOICE", wasFailClosed: false, failClosedReason: nil,
                    tuning: tuning, startTime: startTime
                )
                return TargetSpeakerFilterResult(
                    samples: Array(repeating: 0, count: samples.count),
                    acceptedSampleCount: 0,
                    hadVoiceActivity: false,
                    decision: .noVoice,
                    wasFailClosed: false,
                    errorDescription: nil
                )
            }

            var acceptedUtterances: [SampleRange] = []
            var scoredRunCount = 0
            var hadUncertainWindow = false
            var hadUnresolvedUncertainWindow = false
            var hadStrongRejectWindow = false
            var scoredRuns: [(index: Int, windows: [ScoredWindow])] = []
            for (index, run) in voiceRuns.enumerated()
            where run.end - run.start >= TargetSpeakerFilterConfiguration.speakerWindowSamples {
                scoredRunCount += 1
                let windows = try await Self.scoredWindows(
                    samples: samples,
                    run: run,
                    profile: profile,
                    model: model,
                    tuning: tuning
                )
                scoredRuns.append((index: index, windows: windows))
            }

            let allScoredWindows = scoredRuns.flatMap(\.windows)
            let hasAbsoluteStrongWindow = allScoredWindows.contains { $0.classification == .strong }
            var relativeDecision: TargetSpeakerFilterDecision?
            var confirmationCandidate: TargetSpeakerConfirmationCandidate?

            if hasAbsoluteStrongWindow {
                // Preserve the established absolute path exactly: strong windows pass, nearby
                // uncertain windows can bridge a tone change, and an unresolved/rejected window
                // keeps the overall result partial or ambiguous rather than being promoted by a
                // relative anchor.
                for run in scoredRuns {
                    let strongWindows = run.windows.filter { $0.classification == .strong }
                    for window in run.windows {
                        switch window.classification {
                        case .strong:
                            acceptedUtterances.append(window.range)
                        case .uncertain:
                            hadUncertainWindow = true
                            if Self.canPromoteUncertainWindow(
                                window,
                                strongWindows: strongWindows,
                                tuning: tuning
                            ) {
                                acceptedUtterances.append(window.range)
                            } else {
                                hadUnresolvedUncertainWindow = true
                            }
                        case .reject:
                            hadStrongRejectWindow = true
                        }
                    }
                }
            } else if !allScoredWindows.isEmpty {
                let relative = Self.relativeClassification(
                    samples: samples,
                    windows: allScoredWindows
                )
                acceptedUtterances = relative.acceptedRanges
                relativeDecision = relative.decision
                confirmationCandidate = relative.confirmationCandidate
            }

            if confirmationCandidate == nil && !allScoredWindows.isEmpty {
                let candidateWindows = allScoredWindows.map {
                    TargetSpeakerConfirmationWindow(
                        startSample: $0.range.start,
                        endSample: $0.range.end,
                        profileScore: $0.score,
                        anchorSimilarity: $0.score,
                        classification: $0.classification == .reject ? .other : .target
                    )
                }
                let anchorScore = allScoredWindows.map(\.score).max() ?? 0
                let candidateSamples = Self.mask(
                    samples: samples,
                    accepted: allScoredWindows.map { (start: $0.range.start, end: $0.range.end) }
                )
                let candidateAudio = candidateSamples.isEmpty ? samples : candidateSamples
                confirmationCandidate = TargetSpeakerConfirmationCandidate(
                    samples: candidateAudio,
                    windows: candidateWindows,
                    internalCoherence: Self.recordingCoherence(allScoredWindows.map(\.embedding)),
                    anchorProfileScore: anchorScore,
                    separation: nil,
                    separationReason: "single-utterance candidate fallback"
                )
            }

            for run in scoredRuns {
                Self.logScoredRun(index: run.index, windows: run.windows, threshold: tuning.cosineThreshold)
            }

            // Push-to-talk means the whole recording is bounded by the user physically holding
            // the hotkey down, so if *nothing* in it was even long enough to identity-score, and
            // the total voiced audio is short, treat it as an unscoreable short command (e.g.
            // "durdur") and accept it outright instead of structurally rejecting it forever.
            // This must never fire when any run *was* scored -- a below-threshold long run still
            // means normal scoring applies to everything, short runs included.
            let totalVoicedSamples = voiceRuns.reduce(0) { $0 + ($1.end - $1.start) }
            let totalVoicedSeconds = Double(totalVoicedSamples) / Double(TargetSpeakerFilterConfiguration.sampleRate)
            let shortBypassApplies = scoredRunCount == 0
                && tuning.shortUtteranceMaxSeconds > 0
                && totalVoicedSeconds <= tuning.shortUtteranceMaxSeconds

            if shortBypassApplies {
                acceptedUtterances = voiceRuns
                Self.logShortBypass(
                    totalVoicedSeconds: totalVoicedSeconds,
                    ceiling: tuning.shortUtteranceMaxSeconds,
                    runCount: voiceRuns.count
                )
            } else {
                // Do not merge short runs before identity decisions. A short run can be retained
                // only after a neighboring long target utterance has already been accepted.
                for (index, run) in voiceRuns.enumerated()
                where run.end - run.start < TargetSpeakerFilterConfiguration.speakerWindowSamples {
                    let adjacent = acceptedUtterances.contains { accepted in
                        let gapBefore = accepted.start - run.end
                        let gapAfter = run.start - accepted.end
                        return (gapBefore >= 0 && gapBefore <= TargetSpeakerFilterConfiguration.shortAdjacencySamples)
                            || (gapAfter >= 0 && gapAfter <= TargetSpeakerFilterConfiguration.shortAdjacencySamples)
                    }
                    if adjacent {
                        acceptedUtterances.append(run)
                        Self.logRescuedShortRun(index: index, run: run)
                    } else {
                        Self.logDroppedShortRun(index: index, run: run)
                    }
                }
            }

            let decision: TargetSpeakerFilterDecision
            if shortBypassApplies {
                decision = .accepted
            } else if let relativeDecision {
                decision = relativeDecision
            } else if acceptedUtterances.isEmpty {
                decision = hadUncertainWindow ? .ambiguous : .rejected
            } else if hadUnresolvedUncertainWindow {
                decision = .ambiguous
            } else if hadStrongRejectWindow {
                decision = .partial
            } else {
                decision = .accepted
            }

            let mergedAccepted = Self.merge(acceptedUtterances, adjacency: TargetSpeakerFilterConfiguration.shortAdjacencySamples)
            let paddedAccepted = Self.merge(
                mergedAccepted.map {
                    SampleRange(
                        start: max(0, $0.start - TargetSpeakerFilterConfiguration.acceptedPaddingSamples),
                        end: min(samples.count, $0.end + TargetSpeakerFilterConfiguration.acceptedPaddingSamples)
                    )
                },
                adjacency: 0
            )
            let masked = Self.mask(
                samples: samples,
                accepted: paddedAccepted.map { (start: $0.start, end: $0.end) }
            )
            let acceptedSampleCount = paddedAccepted.reduce(0) { $0 + ($1.end - $1.start) }
            let decisionText: String
            switch decision {
            case .disabled: decisionText = "DISABLED"
            case .accepted: decisionText = shortBypassApplies ? "SHORT_BYPASS" : "ACCEPT"
            case .partial: decisionText = "PARTIAL"
            case .ambiguous: decisionText = "AMBIGUOUS"
            case .singleSpeakerUncertain: decisionText = "SINGLE_SPEAKER_UNCERTAIN"
            case .rejected: decisionText = "REJECT"
            case .noVoice: decisionText = "NO_VOICE"
            case .failClosed: decisionText = "FAIL_CLOSED"
            }
            Self.logSummary(
                samples: samples, voiceRunCount: voiceRuns.count, scoredRunCount: scoredRunCount,
                acceptedSampleCount: acceptedSampleCount,
                decision: decisionText, wasFailClosed: false,
                failClosedReason: nil, tuning: tuning, startTime: startTime
            )
            return TargetSpeakerFilterResult(
                samples: masked,
                acceptedSampleCount: acceptedSampleCount,
                hadVoiceActivity: true,
                decision: decision,
                wasFailClosed: false,
                errorDescription: nil,
                confirmationCandidate: confirmationCandidate
            )
        } catch {
            Self.logSummary(
                samples: samples, voiceRunCount: 0, scoredRunCount: 0, acceptedSampleCount: 0,
                decision: "FAIL_CLOSED", wasFailClosed: true, failClosedReason: error.localizedDescription,
                tuning: tuning, startTime: startTime
            )
            return Self.failClosed(samples: samples, error: error.localizedDescription)
        }
    }

    private struct SampleRange: Sendable, Equatable {
        let start: Int
        let end: Int
    }

    private static func failClosed(samples: [Float], error: String) -> TargetSpeakerFilterResult {
        TargetSpeakerFilterResult(
            samples: Array(repeating: 0, count: samples.count),
            acceptedSampleCount: 0,
            hadVoiceActivity: true,
            decision: .failClosed,
            wasFailClosed: true,
            errorDescription: error
        )
    }

    // `String(format:)` with `%@` mixed into a varargs list that also has `%d`/`%f` specifiers is
    // fragile for Swift `String` arguments, so log lines interpolate strings directly and only use
    // `String(format:)` for individual numeric values.
    private static func fmt2(_ value: Double) -> String { String(format: "%.2f", value) }
    private static func fmt3(_ value: Float) -> String { String(format: "%.3f", value) }

    /// Logs one line per voice run so a run that never reaches the scoring loop (too short for
    /// `speakerWindowSamples`) is still visible -- this is the case that otherwise looks
    /// identical to a genuine below-threshold rejection in the UI.
    private static func logVoiceRuns(_ runs: [SampleRange]) {
        for (index, run) in runs.enumerated() {
            let startSeconds = Double(run.start) / Double(TargetSpeakerFilterConfiguration.sampleRate)
            let endSeconds = Double(run.end) / Double(TargetSpeakerFilterConfiguration.sampleRate)
            let duration = endSeconds - startSeconds
            let longEnough = run.end - run.start >= TargetSpeakerFilterConfiguration.speakerWindowSamples
            let note = longEnough ? "scored=yes" : "scored=no (below 1.50s window)"
            owLog("[TargetSpeaker] run \(index): \(fmt2(startSeconds))-\(fmt2(endSeconds))s dur=\(fmt2(duration))s \(note)")
        }
    }

    private static func logScoredRun(
        index: Int,
        windows: [ScoredWindow],
        threshold: Float
    ) {
        let windowsText = windows.map {
            "profileScore=\(fmt3($0.score)):\($0.classification.logName)"
        }.joined(separator: ", ")
        owLog(
            "[TargetSpeaker] run \(index) windows=[\(windowsText)]"
                + " threshold=\(fmt3(threshold)) -> windowed"
        )
    }

    private static func logRescuedShortRun(index: Int, run: SampleRange) {
        let startSeconds = Double(run.start) / Double(TargetSpeakerFilterConfiguration.sampleRate)
        let endSeconds = Double(run.end) / Double(TargetSpeakerFilterConfiguration.sampleRate)
        owLog("[TargetSpeaker] run \(index): \(fmt2(startSeconds))-\(fmt2(endSeconds))s rescued via adjacency to accepted run")
    }

    /// A short run that is neither scoreable nor adjacent to an accepted long utterance is
    /// silently dropped from the mask -- log it explicitly so that case (e.g. a short command
    /// spoken while a TV plays in the background, with no accepted target-speaker run nearby)
    /// is visible instead of looking identical to "no voice runs at all".
    private static func logDroppedShortRun(index: Int, run: SampleRange) {
        let startSeconds = Double(run.start) / Double(TargetSpeakerFilterConfiguration.sampleRate)
        let endSeconds = Double(run.end) / Double(TargetSpeakerFilterConfiguration.sampleRate)
        owLog("[TargetSpeaker] run \(index): \(fmt2(startSeconds))-\(fmt2(endSeconds))s dropped (too short to score, not adjacent to an accepted run)")
    }

    /// Distinct, unmistakable marker for the push-to-talk short-utterance bypass: this is not a
    /// scored acceptance, so it must never read like one in the logs the user greps.
    private static func logShortBypass(totalVoicedSeconds: Double, ceiling: Double, runCount: Int) {
        owLog(
            "[TargetSpeaker] SHORT_BYPASS: no run reached the \(fmt2(Double(TargetSpeakerFilterConfiguration.speakerWindowSamples) / Double(TargetSpeakerFilterConfiguration.sampleRate)))s scoring window"
                + " -- totalVoiced=\(fmt2(totalVoicedSeconds))s <= ceiling=\(fmt2(ceiling))s"
                + " (runs=\(runCount)) -> accepting all voice runs without identity scoring"
        )
    }

    private static func logSummary(
        samples: [Float],
        voiceRunCount: Int,
        scoredRunCount: Int,
        acceptedSampleCount: Int,
        decision: String,
        wasFailClosed: Bool,
        failClosedReason: String?,
        tuning: TargetSpeakerTuning,
        startTime: Date
    ) {
        let totalSeconds = Double(samples.count) / Double(TargetSpeakerFilterConfiguration.sampleRate)
        let acceptedSeconds = Double(acceptedSampleCount) / Double(TargetSpeakerFilterConfiguration.sampleRate)
        let elapsedMs = Date().timeIntervalSince(startTime) * 1000
        var line = "[TargetSpeaker] summary: input=\(samples.count) samples (\(fmt2(totalSeconds))s)"
            + " voiceRuns=\(voiceRunCount) scored=\(scoredRunCount)"
            + " accepted=\(acceptedSampleCount) samples (\(fmt2(acceptedSeconds))s)"
            + " decision=\(decision) wasFailClosed=\(wasFailClosed)"
            + " cosineThreshold=\(fmt3(tuning.cosineThreshold))"
            + " uncertainFloor=\(fmt3(tuning.uncertainSimilarityFloor))"
            + " continuityThreshold=\(fmt3(tuning.uncertainContinuityThreshold))"
            + " vadThreshold=\(fmt3(tuning.vadThreshold))"
            + " shortUtteranceMaxSeconds=\(fmt2(tuning.shortUtteranceMaxSeconds))"
            + " elapsedMs=\(fmt2(elapsedMs))"
        if let failClosedReason {
            line += " reason=\(failClosedReason)"
        }
        owLog(line)
    }

    private static func voiceRuns(
        frames: [TargetSpeakerVADFrame],
        sampleCount: Int
    ) -> [SampleRange] {
        var runs: [SampleRange] = []
        var activeStart: Int?
        for (index, frame) in frames.enumerated() {
            let start = index * TargetSpeakerFilterConfiguration.vadFrameSamples
            let end = min(sampleCount, start + TargetSpeakerFilterConfiguration.vadFrameSamples)
            guard start < end else { break }
            if frame.isVoiceActive {
                activeStart = activeStart ?? start
            } else if let runStart = activeStart {
                runs.append(SampleRange(start: runStart, end: start))
                activeStart = nil
            }
        }
        if let activeStart {
            runs.append(SampleRange(start: activeStart, end: sampleCount))
        }
        return runs
    }

    private static func merge(_ ranges: [SampleRange], adjacency: Int) -> [SampleRange] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var result: [SampleRange] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end + adjacency {
                current = SampleRange(start: current.start, end: max(current.end, next.end))
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private enum WindowClassification: Sendable {
        case strong
        case uncertain
        case reject

        var logName: String {
            switch self {
            case .strong: "strong"
            case .uncertain: "uncertain"
            case .reject: "reject"
            }
        }
    }

    private struct ScoredWindow: Sendable {
        let range: SampleRange
        let embedding: [Float]
        let score: Float
        let classification: WindowClassification
    }

    private struct RelativeWindow: Sendable {
        let scored: ScoredWindow
        let anchorSimilarity: Float
        let classification: TargetSpeakerRelativeClassification
    }

    private struct RelativeClassificationResult: Sendable {
        let acceptedRanges: [SampleRange]
        let decision: TargetSpeakerFilterDecision
        let confirmationCandidate: TargetSpeakerConfirmationCandidate?
    }

    private static func scoredWindows(
        samples: [Float],
        run: SampleRange,
        profile: TargetSpeakerProfile,
        model: TargetSpeakerModelProvider,
        tuning: TargetSpeakerTuning
    ) async throws -> [ScoredWindow] {
        var windows: [ScoredWindow] = []
        var start = run.start
        while start + TargetSpeakerFilterConfiguration.speakerWindowSamples <= run.end {
            let windowEnd = start + TargetSpeakerFilterConfiguration.speakerWindowSamples
            let range = SampleRange(start: start, end: windowEnd)
            let embedding = try await model.embedding(for: Array(samples[start..<windowEnd]))
            let score = profile.embeddings.map { cosineSimilarity(embedding, $0) }.max() ?? -1
            let classification: WindowClassification
            if score >= tuning.cosineThreshold {
                classification = .strong
            } else if score >= tuning.uncertainSimilarityFloor {
                classification = .uncertain
            } else {
                classification = .reject
            }
            windows.append(ScoredWindow(
                range: range,
                embedding: embedding,
                score: score,
                classification: classification
            ))
            start += TargetSpeakerFilterConfiguration.speakerWindowHopSamples
        }
        return windows
    }

    /// Runs only after every scoreable window failed the absolute strong threshold. The best
    /// profile match becomes an anchor, then windows are classified by similarity to that anchor.
    /// Relative acceptance is intentionally limited to a visibly separated target/outside split;
    /// a single coherent cluster is returned as an explicit confirmation candidate instead of
    /// being silently accepted.
    private static func relativeClassification(
        samples: [Float],
        windows: [ScoredWindow]
    ) -> RelativeClassificationResult {
        guard let anchor = windows.max(by: { $0.score < $1.score }),
              anchor.score >= TargetSpeakerFilterConfiguration.relativeAnchorMinimum else {
            let bestScore = windows.map(\.score).max() ?? -1
            owLog(
                "[TargetSpeaker] relative: no anchor profileScore=\(fmt3(bestScore))"
                    + " required=\(fmt3(TargetSpeakerFilterConfiguration.relativeAnchorMinimum))"
                    + " reason=best profile score below anchor floor"
            )
            return RelativeClassificationResult(
                acceptedRanges: [],
                decision: .rejected,
                confirmationCandidate: nil
            )
        }

        let annotated = windows.map { window in
            let anchorSimilarity = cosineSimilarity(window.embedding, anchor.embedding)
            let classification: TargetSpeakerRelativeClassification
            if anchorSimilarity >= TargetSpeakerFilterConfiguration.relativeTargetSimilarity {
                classification = .target
            } else if anchorSimilarity >= TargetSpeakerFilterConfiguration.relativeUncertainSimilarity {
                classification = .uncertain
            } else {
                classification = .other
            }
            let relativeWindow = RelativeWindow(
                scored: window,
                anchorSimilarity: anchorSimilarity,
                classification: classification
            )
            owLog(
                "[TargetSpeaker] relative window \(window.range.start)-\(window.range.end):"
                    + " profileScore=\(fmt3(window.score))"
                    + " anchorSimilarity=\(fmt3(anchorSimilarity))"
                    + " classification=\(classification.logName)"
            )
            return relativeWindow
        }

        let target = annotated.filter { $0.classification == .target }
        let outside = annotated.filter { $0.classification != .target }
        let targetMean = mean(target.map(\.anchorSimilarity))
        let outsideMean = mean(outside.map(\.anchorSimilarity))
        let separation: Float?
        if outside.isEmpty {
            separation = nil
        } else {
            separation = targetMean - outsideMean
        }

        let allCoherence = recordingCoherence(annotated.map { $0.scored.embedding })
        let candidateCoherenceFloor = Float(TargetSpeakerFilterConfiguration.minRecordingCoherence)
        let hasOtherCluster = annotated.contains { $0.classification == .other }

        if !outside.isEmpty,
           let separation,
           separation >= TargetSpeakerFilterConfiguration.relativeClusterSeparation {
            let accepted = merge(
                target.map { $0.scored.range },
                adjacency: TargetSpeakerFilterConfiguration.shortAdjacencySamples
            )
            owLog(
                "[TargetSpeaker] relative separation: targetMean=\(fmt3(targetMean))"
                    + " outsideMean=\(fmt3(outsideMean)) separation=\(fmt3(separation))"
                    + " required=\(fmt3(TargetSpeakerFilterConfiguration.relativeClusterSeparation))"
                    + " reason=two-cluster separation passed; target cluster accepted"
            )
            return RelativeClassificationResult(
                acceptedRanges: accepted,
                decision: accepted.isEmpty ? .ambiguous : .partial,
                confirmationCandidate: nil
            )
        }

        let isSingleCoherentCluster = !hasOtherCluster
            && allCoherence >= candidateCoherenceFloor
        if isSingleCoherentCluster {
            let candidateWindows = annotated.map {
                TargetSpeakerConfirmationWindow(
                    startSample: $0.scored.range.start,
                    endSample: $0.scored.range.end,
                    profileScore: $0.scored.score,
                    anchorSimilarity: $0.anchorSimilarity,
                    classification: $0.classification
                )
            }
            let candidateSamples = mask(
                samples: samples,
                accepted: annotated.map { (start: $0.scored.range.start, end: $0.scored.range.end) }
            )
            let reason: String
            if outside.isEmpty {
                reason = "one coherent cluster; no outside cluster"
            } else {
                reason = "one coherent cluster; outside separation below automatic floor"
            }
            owLog(
                "[TargetSpeaker] relative separation: targetMean=\(fmt3(targetMean))"
                    + " outsideMean=\(outside.isEmpty ? "none" : fmt3(outsideMean))"
                    + " separation=\(separation.map(fmt3) ?? "none")"
                    + " reason=\(reason), coherence=\(fmt3(allCoherence))"
            )
            return RelativeClassificationResult(
                acceptedRanges: [],
                decision: .singleSpeakerUncertain,
                confirmationCandidate: TargetSpeakerConfirmationCandidate(
                    samples: candidateSamples,
                    windows: candidateWindows,
                    internalCoherence: allCoherence,
                    anchorProfileScore: anchor.score,
                    separation: separation,
                    separationReason: reason
                )
            )
        }

        owLog(
            "[TargetSpeaker] relative separation: targetMean=\(fmt3(targetMean))"
                + " outsideMean=\(outside.isEmpty ? "none" : fmt3(outsideMean))"
                + " separation=\(separation.map(fmt3) ?? "none")"
                + " reason=relative split not sufficiently separated or coherent"
                + " coherence=\(fmt3(allCoherence))"
        )
        return RelativeClassificationResult(
            acceptedRanges: [],
            decision: target.isEmpty ? .rejected : .ambiguous,
            confirmationCandidate: nil
        )
    }

    private static func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    private static func canPromoteUncertainWindow(
        _ window: ScoredWindow,
        strongWindows: [ScoredWindow],
        tuning: TargetSpeakerTuning
    ) -> Bool {
        guard let nearest = strongWindows.min(by: {
            abs($0.range.start - window.range.start) < abs($1.range.start - window.range.start)
        }) else {
            return false
        }
        let hop = TargetSpeakerFilterConfiguration.speakerWindowHopSamples
        let distance = abs(nearest.range.start - window.range.start)
        guard distance <= TargetSpeakerFilterConfiguration.maximumUncertainBridgeWindows * hop else {
            return false
        }
        return cosineSimilarity(window.embedding, nearest.embedding) >= tuning.uncertainContinuityThreshold
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return -1 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return -1 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    /// Within-recording coherence: the median of all pairwise cosine similarities among a single
    /// recording's speaker-window embeddings. Chosen over median-vs-centroid because it needs no
    /// extra aggregate vector and degrades more gracefully under contamination -- a handful of
    /// windows from a second speaker only pull down the pairs that touch them, whereas a centroid
    /// gets dragged toward the contamination and can mask it. Fewer than two embeddings can't
    /// disagree with themselves, so this returns 1 (perfectly coherent) rather than an undefined
    /// or synthetically-low score -- a recording that is short enough to yield a single window is
    /// gated by `minimumPerRecordingSpeechSeconds`/duration checks, not by this one.
    static func recordingCoherence(_ embeddings: [[Float]]) -> Float {
        guard embeddings.count > 1 else { return 1 }
        var pairwise: [Float] = []
        pairwise.reserveCapacity(embeddings.count * (embeddings.count - 1) / 2)
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                pairwise.append(cosineSimilarity(embeddings[i], embeddings[j]))
            }
        }
        return median(pairwise)
    }

    /// Cross-recording consistency: the median cosine similarity across every (embedding from
    /// `lhs`, embedding from `rhs`) pair. Symmetric and simple by construction -- no best-match or
    /// centroid step -- which keeps it easy to reason about and to calibrate against the
    /// deliberately-depressed similarity expected between two different-posture enrollment
    /// recordings of the same person.
    static func crossRecordingSimilarity(_ lhs: [[Float]], _ rhs: [[Float]]) -> Float {
        guard !lhs.isEmpty, !rhs.isEmpty else { return -1 }
        var pairwise: [Float] = []
        pairwise.reserveCapacity(lhs.count * rhs.count)
        for l in lhs {
            for r in rhs {
                pairwise.append(cosineSimilarity(l, r))
            }
        }
        return median(pairwise)
    }

    static func mask(samples: [Float], accepted: [(start: Int, end: Int)]) -> [Float] {
        var output = Array(repeating: Float.zero, count: samples.count)
        for range in accepted {
            let start = max(0, min(samples.count, range.start))
            let end = max(start, min(samples.count, range.end))
            guard end > start else { continue }
            for index in start..<end {
                var gain: Float = 1
                let distanceFromStart = index - start
                let distanceToEnd = end - 1 - index
                if distanceFromStart < TargetSpeakerFilterConfiguration.edgeFadeSamples {
                    gain = min(gain, Float(distanceFromStart + 1) / Float(TargetSpeakerFilterConfiguration.edgeFadeSamples))
                }
                if distanceToEnd < TargetSpeakerFilterConfiguration.edgeFadeSamples {
                    gain = min(gain, Float(distanceToEnd + 1) / Float(TargetSpeakerFilterConfiguration.edgeFadeSamples))
                }
                output[index] = samples[index] * gain
            }
        }
        return output
    }
}

enum TargetSpeakerOutputGate {
    static func shouldSkipPostProcessing(featureEnabled: Bool, acceptedSampleCount: Int) -> Bool {
        featureEnabled && acceptedSampleCount == 0
    }
}
