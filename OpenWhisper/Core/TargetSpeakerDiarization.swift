import CoreML
import Foundation
import FluidAudio

/// Progress emitted while the optional Sortformer/embedding stack is downloaded and prepared.
/// Integration code should surface this alongside the existing target-speaker enrollment
/// progress, but should not mark the feature ready until `prepare` returns successfully.
struct TargetSpeakerDiarizationPreparationProgress: Sendable, Equatable {
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

typealias TargetSpeakerDiarizationProgressHandler =
    @Sendable (TargetSpeakerDiarizationPreparationProgress) -> Void

/// Conservative tuning for best-effort word filtering. The gates intentionally err toward
/// dropping a word when identity is uncertain; this is a diarization filter, not source
/// separation and cannot recover speech hidden under another speaker.
struct TargetSpeakerDiarizationConfiguration: Sendable, Equatable {
    static let sampleRate = 16_000
    static let frameDuration: Double = 0.08
    static let embeddingWindowSeconds: Double = 1.5
    static let minimumSoloIntervalSeconds: Double = 1.5
    static let wordEmbeddingMinimumSeconds: Double = 0.5
    static let wordEmbeddingPaddingSeconds: Double = 0.20
    static let wordEmbeddingMaximumSeconds: Double = 2.0

    let activityThreshold: Float
    let targetSimilarityThreshold: Float
    let targetSlotMargin: Float
    let wordSimilarityThreshold: Float
    let wordUncertainFloor: Float

    static let `default` = TargetSpeakerDiarizationConfiguration(
        activityThreshold: 0.50,
        targetSimilarityThreshold: TargetSpeakerFilterConfiguration.cosineThreshold,
        targetSlotMargin: 0.05,
        wordSimilarityThreshold: 0.68,
        wordUncertainFloor: 0.50
    )

    init(
        activityThreshold: Float = 0.50,
        targetSimilarityThreshold: Float = TargetSpeakerFilterConfiguration.cosineThreshold,
        targetSlotMargin: Float = 0.05,
        wordSimilarityThreshold: Float = 0.68,
        wordUncertainFloor: Float = 0.50
    ) {
        self.activityThreshold = activityThreshold
        self.targetSimilarityThreshold = targetSimilarityThreshold
        self.targetSlotMargin = targetSlotMargin
        self.wordSimilarityThreshold = wordSimilarityThreshold
        self.wordUncertainFloor = wordUncertainFloor
    }
}

/// Typed outcomes that an AppState integration can map to a fail-closed/pass-through path.
/// In particular, a preparation/download error is never converted into an apparently successful
/// diarization result.
enum TargetSpeakerDiarizationError: Error, LocalizedError, Sendable {
    case notPrepared
    case modelPreparationFailed(String)
    case incompatibleProfile(expected: String, actual: String)
    case invalidAudio
    case targetSpeakerNotIdentified(bestScore: Float?)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "Ses ayrıştırma modeli henüz hazır değil"
        case .modelPreparationFailed(let message):
            return "Ses ayrıştırma modeli hazırlanamadı: \(message)"
        case .incompatibleProfile(let expected, let actual):
            return "Ses profili ayrıştırma modeliyle uyumsuz (beklenen \(expected), bulunan \(actual))"
        case .invalidAudio:
            return "Ses ayrıştırma için geçersiz kayıt"
        case .targetSpeakerNotIdentified(let bestScore):
            if let bestScore {
                return String(format: "Hedef konuşmacı güvenilir biçimde belirlenemedi (skor %.3f)", bestScore)
            }
            return "Hedef konuşmacı güvenilir biçimde belirlenemedi"
        case .processingFailed(let message):
            return "Ses ayrıştırma başarısız oldu: \(message)"
        }
    }
}

/// One Sortformer frame, retained so an integration can inspect the exact frame-level decision
/// that was used for each word.
struct TargetSpeakerActivityFrame: Sendable, Equatable {
    let frameIndex: Int
    let startTime: Double
    let endTime: Double
    let probabilities: [Float]
    let activeSpeakerSlots: [Int]

    var isOverlap: Bool { activeSpeakerSlots.count > 1 }
}

/// A contiguous activity interval for one Sortformer speaker slot.
struct TargetSpeakerActivityInterval: Sendable, Equatable {
    let speakerSlot: Int
    let startTime: Double
    let endTime: Double
    let meanProbability: Float
    let isOverlap: Bool
}

/// Result of filtering Whisper's timed words through Sortformer activity and target-speaker
/// identity. `words` contains accepted words only, in original Whisper order.
struct TargetSpeakerDiarizationResult: Sendable, Equatable {
    let text: String
    let words: [WhisperTimedWord]
    let activityFrames: [TargetSpeakerActivityFrame]
    let activityIntervals: [TargetSpeakerActivityInterval]
    let targetSpeakerSlot: Int
    let hadOverlap: Bool
    let rejectedWordCount: Int
    let uncertainWordCount: Int

    var acceptedWordCount: Int { words.count }
}

/// Optional target-speaker diarization contract. It is deliberately separate from
/// `TargetSpeakerFilter`: the existing filter masks samples for ordinary transcription, while
/// this service keeps Whisper's word timings and makes an overlap-aware text decision.
protocol TargetSpeakerDiarizationService: Sendable {
    func prepare(progressHandler: TargetSpeakerDiarizationProgressHandler?) async throws

    func diarizeAndFilter(
        audioData: [Float],
        transcription: TimedTranscriptionResult,
        profile: TargetSpeakerProfile,
        audioProcessingMode: AudioProcessingMode
    ) async throws -> TargetSpeakerDiarizationResult
}

extension TargetSpeakerDiarizationService {
    /// Alias kept as the natural call-site spelling for the integration worker.
    func filter(
        audioData: [Float],
        transcription: TimedTranscriptionResult,
        profile: TargetSpeakerProfile,
        audioProcessingMode: AudioProcessingMode = .off
    ) async throws -> TargetSpeakerDiarizationResult {
        try await diarizeAndFilter(
            audioData: audioData,
            transcription: transcription,
            profile: profile,
            audioProcessingMode: audioProcessingMode
        )
    }
}

/// FluidAudio 0.12.4 implementation. Sortformer supplies four slot activity probabilities;
/// FluidAudio's 256-dimensional diarizer embedding model supplies identity comparisons against
/// the enrolled `TargetSpeakerProfile`.
///
/// Integration call flow:
/// 1. Construct this service once and call `prepare(progressHandler:)` during model preparation.
/// 2. For a recording, call `WhisperTranscriptionService.transcribeTimed(...)` on the original
///    samples, then pass that result and the compatible profile to `diarizeAndFilter(...)`.
/// 3. Use `TargetSpeakerDiarizationResult.text`/`words` for the normal target-speaker path and
///    inspect `hadOverlap`, `rejectedWordCount`, and `uncertainWordCount` for UI/session state.
/// 4. Catch `TargetSpeakerDiarizationError.modelPreparationFailed`, `.notPrepared`, or
///    `.targetSpeakerNotIdentified` as a typed fallback condition; do not treat the recording as
///    successfully diarized when one of those errors is raised.
final class FluidAudioTargetSpeakerDiarizationService: TargetSpeakerDiarizationService, @unchecked Sendable {
    static let modelIdentifier = FluidAudioTargetSpeakerModel.identifier

    private let runtime: FluidAudioTargetSpeakerDiarizationRuntime

    init(configuration: TargetSpeakerDiarizationConfiguration = .default) {
        runtime = FluidAudioTargetSpeakerDiarizationRuntime(configuration: configuration)
    }

    func prepare(progressHandler: TargetSpeakerDiarizationProgressHandler?) async throws {
        try await runtime.prepare(progressHandler: progressHandler)
    }

    func diarizeAndFilter(
        audioData: [Float],
        transcription: TimedTranscriptionResult,
        profile: TargetSpeakerProfile,
        audioProcessingMode: AudioProcessingMode
    ) async throws -> TargetSpeakerDiarizationResult {
        try await runtime.diarizeAndFilter(
            audioData: audioData,
            transcription: transcription,
            profile: profile,
            audioProcessingMode: audioProcessingMode
        )
    }
}

/// Alternate descriptive spelling for integration code and documentation.
typealias FluidAudioSortformerTargetSpeakerDiarizationService =
    FluidAudioTargetSpeakerDiarizationService

private actor FluidAudioTargetSpeakerDiarizationRuntime {
    private let configuration: TargetSpeakerDiarizationConfiguration
    private let sortformerConfig = SortformerConfig.default
    private var sortformer: SortformerDiarizer?
    private var embeddingDiarizer: DiarizerManager?
    private var preparationTask: Task<Void, Error>?

    init(configuration: TargetSpeakerDiarizationConfiguration) {
        self.configuration = configuration
    }

    func prepare(progressHandler: TargetSpeakerDiarizationProgressHandler?) async throws {
        if sortformer != nil, embeddingDiarizer != nil {
            owLog("[TargetSpeakerDiarization] Already prepared")
            return
        }
        if let preparationTask {
            owLog("[TargetSpeakerDiarization] Preparation already in flight, awaiting task...")
            do {
                try await preparationTask.value
            } catch let typedError as TargetSpeakerDiarizationError {
                throw typedError
            } catch {
                throw TargetSpeakerDiarizationError.modelPreparationFailed(String(describing: error))
            }
            return
        }

        owLog("[TargetSpeakerDiarization] Starting model preparation...")
        let task = Task { [weak self] () throws -> Void in
            guard let self else { return }
            try await self.loadModels(progressHandler: progressHandler)
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
            owLog("[TargetSpeakerDiarization] Model preparation completed successfully")
        } catch {
            preparationTask = nil
            owLog("[TargetSpeakerDiarization] Model preparation failed: \(error)")
            if let typedError = error as? TargetSpeakerDiarizationError {
                throw typedError
            }
            throw TargetSpeakerDiarizationError.modelPreparationFailed(String(describing: error))
        }
    }

    private func loadModels(progressHandler: TargetSpeakerDiarizationProgressHandler?) async throws {
        owLog("[TargetSpeakerDiarization] Loading Diarizer models...")
        progressHandler?(TargetSpeakerDiarizationPreparationProgress(
            phase: .preparing,
            fractionCompleted: nil,
            message: "Ses ayrıştırma modelleri hazırlanıyor…"
        ))

        let diarizerModels: DiarizerModels
        do {
            diarizerModels = try await DiarizerModels.downloadIfNeeded { progress in
                let phase: TargetSpeakerDiarizationPreparationProgress.Phase
                let message: String
                switch progress.phase {
                case .listing:
                    phase = .listing
                    message = "Konuşmacı embedding modeli listeleniyor…"
                case .downloading:
                    phase = .downloading
                    message = "Konuşmacı embedding modeli indiriliyor…"
                case .compiling:
                    phase = .compiling
                    message = "Konuşmacı embedding modeli derleniyor…"
                }
                progressHandler?(TargetSpeakerDiarizationPreparationProgress(
                    phase: phase,
                    fractionCompleted: progress.fractionCompleted,
                    message: message
                ))
            }
        } catch {
            owLog("[TargetSpeakerDiarization] DiarizerModels load failed: \(error)")
            throw TargetSpeakerDiarizationError.modelPreparationFailed(String(describing: error))
        }

        owLog("[TargetSpeakerDiarization] Loading Sortformer models...")
        let sortformerModels: SortformerModels
        do {
            sortformerModels = try await SortformerModels.loadFromHuggingFace(
                config: sortformerConfig,
                computeUnits: .all
            ) { progress in
                let phase: TargetSpeakerDiarizationPreparationProgress.Phase
                let message: String
                switch progress.phase {
                case .listing:
                    phase = .listing
                    message = "Sortformer modeli listeleniyor…"
                case .downloading:
                    phase = .downloading
                    message = "Sortformer modeli indiriliyor…"
                case .compiling:
                    phase = .compiling
                    message = "Sortformer modeli derleniyor…"
                }
                progressHandler?(TargetSpeakerDiarizationPreparationProgress(
                    phase: phase,
                    fractionCompleted: progress.fractionCompleted,
                    message: message
                ))
            }
        } catch {
            owLog("[TargetSpeakerDiarization] SortformerModels load failed: \(error)")
            throw TargetSpeakerDiarizationError.modelPreparationFailed(String(describing: error))
        }

        let embeddingDiarizer = DiarizerManager(config: DiarizerConfig(
            clusteringThreshold: 0.70,
            minSpeechDuration: Float(TargetSpeakerDiarizationConfiguration.minimumSoloIntervalSeconds),
            minEmbeddingUpdateDuration: Float(TargetSpeakerDiarizationConfiguration.embeddingWindowSeconds),
            minSilenceGap: 0.5,
            chunkDuration: 10,
            chunkOverlap: 1
        ))
        embeddingDiarizer.initialize(models: diarizerModels)

        let sortformer = SortformerDiarizer(
            config: sortformerConfig,
            postProcessingConfig: SortformerPostProcessingConfig.default
        )
        sortformer.initialize(models: sortformerModels)

        self.embeddingDiarizer = embeddingDiarizer
        self.sortformer = sortformer
        owLog("[TargetSpeakerDiarization] All diarization models initialized successfully")
        progressHandler?(TargetSpeakerDiarizationPreparationProgress(
            phase: .ready,
            fractionCompleted: 1,
            message: "Ses ayrıştırma hazır"
        ))
    }

    func diarizeAndFilter(
        audioData: [Float],
        transcription: TimedTranscriptionResult,
        profile: TargetSpeakerProfile,
        audioProcessingMode: AudioProcessingMode
    ) async throws -> TargetSpeakerDiarizationResult {
        owLog("[TargetSpeakerDiarization] diarizeAndFilter called: samples=\(audioData.count), words=\(transcription.words.count), profileEmbeddings=\(profile.embeddings.count)")
        guard !audioData.isEmpty, audioData.allSatisfy({ $0.isFinite }) else {
            owLog("[TargetSpeakerDiarization] Error: invalidAudio (empty or non-finite samples)")
            throw TargetSpeakerDiarizationError.invalidAudio
        }
        guard profile.isCompatible(with: FluidAudioTargetSpeakerDiarizationService.modelIdentifier, audioProcessingMode: audioProcessingMode) else {
            owLog("[TargetSpeakerDiarization] Error: incompatibleProfile (expected \(FluidAudioTargetSpeakerDiarizationService.modelIdentifier), found \(profile.modelIdentifier))")
            throw TargetSpeakerDiarizationError.incompatibleProfile(
                expected: FluidAudioTargetSpeakerDiarizationService.modelIdentifier,
                actual: profile.modelIdentifier
            )
        }
        guard let sortformer, let embeddingDiarizer else {
            owLog("[TargetSpeakerDiarization] Error: notPrepared (Sortformer or DiarizerManager nil)")
            throw TargetSpeakerDiarizationError.notPrepared
        }

        do {
            let timeline = try sortformer.processComplete(audioData)
            let frames = makeFrames(from: timeline, audioSampleCount: audioData.count)
            let intervals = makeIntervals(from: frames)
            let targetSlot = try identifyTargetSlot(
                frames: frames,
                audioData: audioData,
                profile: profile,
                embeddingDiarizer: embeddingDiarizer
            )
            let result = try filterWords(
                transcription.words,
                audioData: audioData,
                frames: frames,
                targetSlot: targetSlot,
                profile: profile,
                embeddingDiarizer: embeddingDiarizer,
                intervals: intervals
            )
            owLog("[TargetSpeakerDiarization] diarizeAndFilter succeeded: targetSlot=\(targetSlot), acceptedWords=\(result.acceptedWordCount)/\(transcription.words.count), rejectedWords=\(result.rejectedWordCount), uncertainWords=\(result.uncertainWordCount), hadOverlap=\(result.hadOverlap), text=\"\(result.text)\"")
            return result
        } catch let error as TargetSpeakerDiarizationError {
            owLog("[TargetSpeakerDiarization] Error: \(error.localizedDescription)")
            throw error
        } catch {
            owLog("[TargetSpeakerDiarization] Processing failed error: \(error)")
            throw TargetSpeakerDiarizationError.processingFailed(String(describing: error))
        }
    }

    private func makeFrames(
        from timeline: SortformerTimeline,
        audioSampleCount: Int
    ) -> [TargetSpeakerActivityFrame] {
        let audioDuration = Double(audioSampleCount) / Double(TargetSpeakerDiarizationConfiguration.sampleRate)
        return (0..<timeline.numFrames).compactMap { frameIndex in
            let start = Double(frameIndex) * TargetSpeakerDiarizationConfiguration.frameDuration
            let end = min(
                audioDuration,
                Double(frameIndex + 1) * TargetSpeakerDiarizationConfiguration.frameDuration
            )
            guard end > start else { return nil }
            let probabilities = (0..<sortformerConfig.numSpeakers).map {
                timeline.probability(speaker: $0, frame: frameIndex)
            }
            let active = probabilities.indices.filter {
                probabilities[$0] >= configuration.activityThreshold
            }
            return TargetSpeakerActivityFrame(
                frameIndex: frameIndex,
                startTime: start,
                endTime: end,
                probabilities: probabilities,
                activeSpeakerSlots: active
            )
        }
    }

    private func makeIntervals(
        from frames: [TargetSpeakerActivityFrame]
    ) -> [TargetSpeakerActivityInterval] {
        var intervals: [TargetSpeakerActivityInterval] = []
        for speakerSlot in 0..<sortformerConfig.numSpeakers {
            var run: [TargetSpeakerActivityFrame] = []
            for frame in frames {
                if frame.activeSpeakerSlots.contains(speakerSlot) {
                    run.append(frame)
                } else if !run.isEmpty {
                    intervals.append(interval(for: speakerSlot, frames: run))
                    run.removeAll(keepingCapacity: true)
                }
            }
            if !run.isEmpty {
                intervals.append(interval(for: speakerSlot, frames: run))
            }
        }
        return intervals.sorted { $0.startTime < $1.startTime }
    }

    private func interval(
        for speakerSlot: Int,
        frames: [TargetSpeakerActivityFrame]
    ) -> TargetSpeakerActivityInterval {
        let probabilityCount = frames.reduce(0) { $0 + $1.probabilities[speakerSlot] }
        return TargetSpeakerActivityInterval(
            speakerSlot: speakerSlot,
            startTime: frames[0].startTime,
            endTime: frames[frames.count - 1].endTime,
            meanProbability: probabilityCount / Float(frames.count),
            isOverlap: frames.contains(where: { $0.isOverlap })
        )
    }

    private struct SoloRun: Sendable {
        let speakerSlot: Int
        let startFrame: Int
        let endFrame: Int
    }

    private func soloRuns(from frames: [TargetSpeakerActivityFrame]) -> [SoloRun] {
        var runs: [SoloRun] = []
        for speakerSlot in 0..<sortformerConfig.numSpeakers {
            var startFrame: Int?
            var previousFrame: Int?
            for frame in frames {
                let isSolo = frame.activeSpeakerSlots == [speakerSlot]
                if isSolo {
                    if startFrame == nil { startFrame = frame.frameIndex }
                    previousFrame = frame.frameIndex
                } else if let completedStart = startFrame, let completedEnd = previousFrame {
                    runs.append(SoloRun(
                        speakerSlot: speakerSlot,
                        startFrame: completedStart,
                        endFrame: completedEnd + 1
                    ))
                    startFrame = nil
                    previousFrame = nil
                }
            }
            if let startFrame, let previousFrame {
                runs.append(SoloRun(
                    speakerSlot: speakerSlot,
                    startFrame: startFrame,
                    endFrame: previousFrame + 1
                ))
            }
        }
        let minimumFrames = Int(ceil(
            TargetSpeakerDiarizationConfiguration.minimumSoloIntervalSeconds
                / TargetSpeakerDiarizationConfiguration.frameDuration
        ))
        return runs.filter { $0.endFrame - $0.startFrame >= minimumFrames }
    }

    private func identifyTargetSlot(
        frames: [TargetSpeakerActivityFrame],
        audioData: [Float],
        profile: TargetSpeakerProfile,
        embeddingDiarizer: DiarizerManager
    ) throws -> Int {
        var scoresBySlot: [Int: [Float]] = [:]
        for run in soloRuns(from: frames) {
            let runStart = Int((Double(run.startFrame) * TargetSpeakerDiarizationConfiguration.frameDuration
                * Double(TargetSpeakerDiarizationConfiguration.sampleRate)).rounded())
            let runEnd = min(
                audioData.count,
                Int((Double(run.endFrame) * TargetSpeakerDiarizationConfiguration.frameDuration
                    * Double(TargetSpeakerDiarizationConfiguration.sampleRate)).rounded())
            )
            guard runEnd > runStart else { continue }
            let windowLength = Int(
                TargetSpeakerDiarizationConfiguration.embeddingWindowSeconds
                    * Double(TargetSpeakerDiarizationConfiguration.sampleRate)
            )
            let hop = max(windowLength / 2, 1)
            var windowStart = runStart
            while windowStart + windowLength <= runEnd {
                let samples = Array(audioData[windowStart..<(windowStart + windowLength)])
                if let embedding = try? embeddingDiarizer.extractSpeakerEmbedding(from: samples),
                   let score = bestProfileSimilarity(embedding, profile: profile),
                   score.isFinite
                {
                    scoresBySlot[run.speakerSlot, default: []].append(score)
                }
                windowStart += hop
            }
            if runEnd - runStart < windowLength {
                let samples = Array(audioData[runStart..<runEnd])
                if let embedding = try? embeddingDiarizer.extractSpeakerEmbedding(from: samples),
                   let score = bestProfileSimilarity(embedding, profile: profile),
                   score.isFinite
                {
                    scoresBySlot[run.speakerSlot, default: []].append(score)
                }
            }
        }

        let ranked = scoresBySlot.compactMap { slot, scores -> (slot: Int, score: Float)? in
            guard !scores.isEmpty else { return nil }
            // Favor a slot with several clean, target-like windows while retaining its strongest
            // evidence. This prevents one bad overlap boundary from dominating identity choice.
            let sorted = scores.sorted(by: >)
            let topScores = sorted.prefix(3)
            let meanTop = topScores.reduce(0, +) / Float(topScores.count)
            return (slot, meanTop)
        }.sorted { $0.score > $1.score }

        guard let best = ranked.first, best.score >= configuration.targetSimilarityThreshold else {
            throw TargetSpeakerDiarizationError.targetSpeakerNotIdentified(bestScore: ranked.first?.score)
        }
        if let second = ranked.dropFirst().first,
           best.score - second.score < configuration.targetSlotMargin
        {
            throw TargetSpeakerDiarizationError.targetSpeakerNotIdentified(bestScore: best.score)
        }
        return best.slot
    }

    private func filterWords(
        _ inputWords: [WhisperTimedWord],
        audioData: [Float],
        frames: [TargetSpeakerActivityFrame],
        targetSlot: Int,
        profile: TargetSpeakerProfile,
        embeddingDiarizer: DiarizerManager,
        intervals: [TargetSpeakerActivityInterval]
    ) throws -> TargetSpeakerDiarizationResult {
        var acceptedWords: [WhisperTimedWord] = []
        var rejectedWordCount = 0
        var uncertainWordCount = 0

        // Whisper emits words in chronological order. Keep that order exactly rather than
        // resorting, because equal timestamps are possible and their original order is useful
        // for punctuation and overlap handling.
        for word in inputWords {
            let wordStart = max(0, Double(word.start))
            let wordEnd = max(wordStart, Double(word.end))
            let overlappingFrames = frames.filter {
                $0.endTime > wordStart && $0.startTime < wordEnd
            }
            let hasTargetActivity = overlappingFrames.contains {
                $0.activeSpeakerSlots.contains(targetSlot)
            }
            let hasOtherActivity = overlappingFrames.contains {
                $0.activeSpeakerSlots.contains { $0 != targetSlot }
            }

            guard hasTargetActivity else {
                rejectedWordCount += 1
                continue
            }

            if !hasOtherActivity {
                acceptedWords.append(word)
                continue
            }

            // Overlap is never accepted from Sortformer activity alone. Re-score a short window
            // centered on this word with the independent speaker embedding model.
            let center = (wordStart + wordEnd) / 2
            let duration = min(
                TargetSpeakerDiarizationConfiguration.wordEmbeddingMaximumSeconds,
                max(
                    TargetSpeakerDiarizationConfiguration.wordEmbeddingMinimumSeconds,
                    (wordEnd - wordStart) + 2 * TargetSpeakerDiarizationConfiguration.wordEmbeddingPaddingSeconds
                )
            )
            let halfDuration = duration / 2
            let sampleStart = max(
                0,
                Int(((center - halfDuration) * Double(TargetSpeakerDiarizationConfiguration.sampleRate)).rounded())
            )
            let sampleEnd = min(
                audioData.count,
                Int(((center + halfDuration) * Double(TargetSpeakerDiarizationConfiguration.sampleRate)).rounded())
            )
            guard sampleEnd > sampleStart else {
                uncertainWordCount += 1
                continue
            }

            let samples = Array(audioData[sampleStart..<sampleEnd])
            guard let embedding = try? embeddingDiarizer.extractSpeakerEmbedding(from: samples),
                  let score = bestProfileSimilarity(embedding, profile: profile),
                  score.isFinite
            else {
                uncertainWordCount += 1
                continue
            }

            if score >= configuration.wordSimilarityThreshold {
                acceptedWords.append(word)
            } else if score >= configuration.wordUncertainFloor {
                uncertainWordCount += 1
            } else {
                rejectedWordCount += 1
            }
        }

        let hadOverlap = frames.contains(where: { $0.isOverlap })
        return TargetSpeakerDiarizationResult(
            text: render(words: acceptedWords),
            words: acceptedWords,
            activityFrames: frames,
            activityIntervals: intervals,
            targetSpeakerSlot: targetSlot,
            hadOverlap: hadOverlap,
            rejectedWordCount: rejectedWordCount,
            uncertainWordCount: uncertainWordCount
        )
    }

    private func bestProfileSimilarity(
        _ embedding: [Float],
        profile: TargetSpeakerProfile
    ) -> Float? {
        profile.embeddings.map { cosineSimilarity(embedding, $0) }.max()
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.greatestFiniteMagnitude }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return -.greatestFiniteMagnitude }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private func render(words: [WhisperTimedWord]) -> String {
        let punctuationWithoutLeadingSpace: Set<Character> = [
            ",", ".", "!", "?", ":", ";", "%", ")", "]", "}", "…"
        ]
        let punctuationWithoutTrailingSpace: Set<Character> = ["(", "[", "{", "“"]
        var result = ""
        for word in words {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            guard let first = token.first else { continue }
            if result.isEmpty || punctuationWithoutLeadingSpace.contains(first)
                || (result.last.map { punctuationWithoutTrailingSpace.contains($0) } ?? false)
            {
                result.append(contentsOf: token)
            } else {
                result.append(" ")
                result.append(contentsOf: token)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
