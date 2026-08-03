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
    /// still compares against every enrolled embedding and the utterance decision uses the
    /// median, so this moderate relaxation preserves protection against one-window outliers.
    static let cosineThreshold: Float = 0.62
    /// A single microphone position is not enough: posture changes the acoustic path to
    /// the microphone. Keep two recordings from different conditions in the profile.
    static let requiredEnrollmentSampleCount = 2
    static let maximumEnrollmentDuration: TimeInterval = 30
    static let minimumPerRecordingSpeechSeconds: TimeInterval = 10
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
        let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.70)) { progress in
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

enum TargetSpeakerEnrollmentError: Error, LocalizedError, Equatable {
    case requiresMultipleSamples
    case invalidSample(index: Int)
    case sampleExceedsMaximumDuration
    case profileSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresMultipleSamples: "İki farklı pozisyondan ses kaydı gerekli"
        case .invalidSample(let index): "Ses kaydı \(index + 1) yeterli konuşma veya kalite koşulunu karşılamıyor"
        case .sampleExceedsMaximumDuration: "Ses kaydı en fazla 30 saniye olabilir"
        case .profileSaveFailed(let message): "Ses profili kaydedilemedi: \(message)"
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
        progressHandler: TargetSpeakerProgressHandler? = nil
    ) async throws -> TargetSpeakerProfile {
        guard recordings.count == TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount else {
            throw TargetSpeakerEnrollmentError.requiresMultipleSamples
        }

        try Task.checkCancellation()
        var embeddings: [[Float]] = []
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
            embeddings.append(contentsOf: result.embeddings)
        }

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

        return TargetSpeakerEnrollmentResult(
            voicedDuration: Double(voicedSamples) / Double(TargetSpeakerFilterConfiguration.sampleRate),
            clippedSampleRatio: samples.isEmpty ? 0 : Double(clipped) / Double(samples.count),
            embeddings: embeddings
        )
    }
}

struct TargetSpeakerFilterResult: Sendable {
    let samples: [Float]
    let acceptedSampleCount: Int
    let hadVoiceActivity: Bool
    /// True when the target-speaker gate could not make a reliable decision and therefore
    /// rejected the segment. Never pass unclassified audio through while the feature is on.
    let wasFailClosed: Bool
    let errorDescription: String?

    var hasAcceptedTargetSpeech: Bool { acceptedSampleCount > 0 }
}

final class TargetSpeakerFilter: @unchecked Sendable {
    private let model: TargetSpeakerModelProvider

    init(model: TargetSpeakerModelProvider) {
        self.model = model
    }

    func filter(samples: [Float], profile: TargetSpeakerProfile?, enabled: Bool) async -> TargetSpeakerFilterResult {
        guard enabled else {
            return TargetSpeakerFilterResult(
                samples: samples,
                acceptedSampleCount: samples.count,
                hadVoiceActivity: true,
                wasFailClosed: false,
                errorDescription: nil
            )
        }

        guard let profile else {
            return Self.failClosed(samples: samples, error: "Ses profili bulunamadı; yeniden kayıt gerekli")
        }

        guard profile.isCompatible(with: model.modelIdentifier) else {
            return Self.failClosed(samples: samples, error: "Ses profili modeli uyumsuz; yeniden kayıt gerekli")
        }

        do {
            try await model.prepare(progressHandler: nil)
            let frames = try await model.vadFrames(for: samples)
            let voiceRuns = Self.voiceRuns(frames: frames, sampleCount: samples.count)
            guard !voiceRuns.isEmpty else {
                return TargetSpeakerFilterResult(
                    samples: Array(repeating: 0, count: samples.count),
                    acceptedSampleCount: 0,
                    hadVoiceActivity: false,
                    wasFailClosed: false,
                    errorDescription: nil
                )
            }

            var acceptedUtterances: [SampleRange] = []
            for run in voiceRuns where run.end - run.start >= TargetSpeakerFilterConfiguration.speakerWindowSamples {
                let scores = try await Self.windowScores(samples: samples, run: run, profile: profile, model: model)
                if Self.median(scores) >= TargetSpeakerFilterConfiguration.cosineThreshold {
                    // Median is an utterance-level decision. Preserve the entire utterance;
                    // individual windows are never independently emitted as speech regions.
                    acceptedUtterances.append(run)
                }
            }

            // Do not merge short runs before identity decisions. A short run can be retained
            // only after a neighboring long target utterance has already been accepted.
            for run in voiceRuns where run.end - run.start < TargetSpeakerFilterConfiguration.speakerWindowSamples {
                let adjacent = acceptedUtterances.contains { accepted in
                    let gapBefore = accepted.start - run.end
                    let gapAfter = run.start - accepted.end
                    return (gapBefore >= 0 && gapBefore <= TargetSpeakerFilterConfiguration.shortAdjacencySamples)
                        || (gapAfter >= 0 && gapAfter <= TargetSpeakerFilterConfiguration.shortAdjacencySamples)
                }
                if adjacent { acceptedUtterances.append(run) }
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
            return TargetSpeakerFilterResult(
                samples: masked,
                acceptedSampleCount: paddedAccepted.reduce(0) { $0 + ($1.end - $1.start) },
                hadVoiceActivity: true,
                wasFailClosed: false,
                errorDescription: nil
            )
        } catch {
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
            wasFailClosed: true,
            errorDescription: error
        )
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

    private static func windowScores(
        samples: [Float],
        run: SampleRange,
        profile: TargetSpeakerProfile,
        model: TargetSpeakerModelProvider
    ) async throws -> [Float] {
        var scores: [Float] = []
        var start = run.start
        while start + TargetSpeakerFilterConfiguration.speakerWindowSamples <= run.end {
            let windowEnd = start + TargetSpeakerFilterConfiguration.speakerWindowSamples
            let embedding = try await model.embedding(for: Array(samples[start..<windowEnd]))
            scores.append(profile.embeddings.map { cosineSimilarity(embedding, $0) }.max() ?? -1)
            start += TargetSpeakerFilterConfiguration.speakerWindowHopSamples
        }
        return scores
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
