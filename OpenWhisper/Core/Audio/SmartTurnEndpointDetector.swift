import CoreML
import FluidAudio
import Foundation
import os
import QuartzCore

/// Silero VAD + Smart Turn v3.2 endpointing for hands-free (wake-word) recordings.
///
/// Silero finds a pause; Smart Turn then reads the last eight seconds of the current turn and
/// decides whether it sounds complete. Model work stays off the audio and main threads. Any load
/// or inference failure is fail-open: AppState falls back to the existing level-based detector.
final class SmartTurnEndpointDetector: @unchecked Sendable {
    static let sampleRate = 16_000
    static let windowSamples = 8 * sampleRate

    enum Decision: Equatable {
        case continueRecording
        case stop(probability: Float)
        case stopAfterIncompleteTimeout
        case stopMaxDuration
        case cancelNoSpeech
        case useLevelFallback(reason: String)
    }

    struct Config: Sendable {
        var vadThreshold: Float = 0.3
        var pauseBeforeAnalysis: TimeInterval = 0.2
        /// Confidence-aware debounce after the actual speech end. A borderline endpoint gets
        /// more time for a thinking pause to resume. Smart Turn rates even a short command
        /// ("devmodu aç") ~0.97 complete, so 1.2 s cut users off mid-thought; 2 s leaves room.
        /// At ≥0.97, use one second; keep the longer thinking allowances for lower scores.
        /// The minimum listening window still protects a wake word followed by a pause.
        var certainSilence: TimeInterval = 1
        var veryHighConfidenceSilence: TimeInterval = 2
        var highConfidenceSilence: TimeInterval = 2.5
        var lowConfidenceSilence: TimeInterval = 3
        var incompleteSilenceTimeout: TimeInterval = 4
        /// No endpoint stop before this much audio since the session began: a wake word
        /// followed by a short pause must not end the session before the command is spoken.
        var minimumListenDuration: TimeInterval = 4
        var noSpeechTimeout: TimeInterval = 6
        var maxDuration: TimeInterval = 120
        var loadGrace: TimeInterval = 3
    }

    static func requiredSilence(for probability: Float, config: Config) -> TimeInterval {
        guard probability > 0.5 else { return config.incompleteSilenceTimeout }
        switch probability {
        case 0.97...: return config.certainSilence
        case 0.9...: return config.veryHighConfidenceSilence
        case 0.75...: return config.highConfidenceSilence
        default: return config.lowConfidenceSilence
        }
    }

    static func endpointDecision(
        probability: Float,
        silenceDuration: TimeInterval,
        sessionElapsed: TimeInterval = .infinity,
        config: Config
    ) -> Decision? {
        guard silenceDuration >= requiredSilence(for: probability, config: config),
              sessionElapsed >= config.minimumListenDuration else { return nil }
        return probability > 0.5
            ? .stop(probability: probability)
            : .stopAfterIncompleteTimeout
    }

    private enum Item: Sendable {
        case samples([Float])
        case finalSamples([Float])
        case finish
    }

    private struct Status {
        var ready = false
        var failure: String?
        var speechDetected = false
        var terminalDecision: Decision?
        var lastProbability: Float?
        var lastEndpoint: Endpoint?
        var previewCoverage = SpeechPreviewCoverage()
        var previewInputFinished = false
    }

    /// The newest pause Silero found and Smart Turn's verdict on it. Kept when speech starts
    /// again: `OwnVoiceStopGate` decides over playback whether that speech was the user's.
    struct Endpoint: Equatable {
        let probability: Float
        /// `CACurrentMediaTime` when the pause was reported.
        let time: TimeInterval
    }

    /// Main thread only (set at init and by `restartClock`, read by `decision`).
    private var startTime: TimeInterval
    private let config: Config
    private let status = OSAllocatedUnfairLock(initialState: Status())
    // Fixed-size batches keep the entire bounded wake preroll while the VAD is loading,
    // independently of the microphone callback size (20 s = 625 batches at 16 kHz).
    private let inputBatch = OSAllocatedUnfairLock(initialState: [Float]())
    private let continuation: AsyncStream<Item>.Continuation
    private var consumer: Task<Void, Never>?

    init(startTime: TimeInterval, config: Config = Config(), ignoredLeadingSeconds: TimeInterval = 0) {
        self.startTime = startTime
        self.config = config
        let (stream, continuation) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(768))
        self.continuation = continuation

        let status = status
        consumer = Task.detached(priority: .userInitiated) {
            do {
                let vad = try await VadManager(config: VadConfig(
                    defaultThreshold: config.vadThreshold,
                    computeUnits: .cpuAndNeuralEngine
                ))
                let turnModel = try SmartTurnModel()
                status.withLock { $0.ready = true }
                owLog("[SmartTurn] Silero VAD + Smart Turn v3.2 ready")

                var streamState = await vad.makeStreamState()
                let segmentation = VadSegmentationConfig(
                    minSpeechDuration: 0.15,
                    minSilenceDuration: config.pauseBeforeAnalysis,
                    maxSpeechDuration: config.maxDuration,
                    speechPadding: 0.1
                )
                var pending: [Float] = []
                var recent: [Float] = []
                var samplesToIgnore = max(0, Int(ignoredLeadingSeconds * Double(Self.sampleRate)))
                var pendingEndpoint: (speechEndSample: Int, probability: Float)?
                var processedSamples = 0
                let ignoredSamples = samplesToIgnore
                var finalSampleCount: Int?

                itemLoop: for await item in stream {
                    switch item {
                    case .finish:
                        break itemLoop
                    case .finalSamples(let samples):
                        // All live feed items precede this one. Add only the unqueued
                        // sub-batch and converter/echo tail from the stopped recording.
                        let received = processedSamples + ignoredSamples + pending.count
                        guard samplesToIgnore == 0, samples.count >= received else { break itemLoop }
                        pending.append(contentsOf: samples.dropFirst(received))
                        finalSampleCount = samples.count
                        let padding = (VadManager.chunkSize - pending.count % VadManager.chunkSize) % VadManager.chunkSize
                        pending.append(contentsOf: repeatElement(Float(0), count: padding))
                    case .samples(var samples):
                        if samplesToIgnore > 0 {
                            let dropped = min(samplesToIgnore, samples.count)
                            samples.removeFirst(dropped)
                            samplesToIgnore -= dropped
                        }
                        guard !samples.isEmpty else { continue }
                        pending.append(contentsOf: samples)
                    }

                    while pending.count >= VadManager.chunkSize {
                        let chunk = Array(pending.prefix(VadManager.chunkSize))
                        pending.removeFirst(VadManager.chunkSize)
                        processedSamples += chunk.count
                        recent.append(contentsOf: chunk)
                        if recent.count > Self.windowSamples {
                            recent.removeFirst(recent.count - Self.windowSamples)
                        }

                        let result = try await vad.processStreamingChunk(
                            chunk,
                            state: streamState,
                            config: segmentation
                        )
                        streamState = result.state
                        status.withLock {
                            let classified = min(processedSamples + ignoredSamples, finalSampleCount ?? Int.max)
                            $0.previewCoverage.processedSamples = classified
                            // Lower than the endpoint threshold: a quiet continuation must
                            // invalidate a preview even before it becomes a speechStart event.
                            if result.probability >= 0.15 {
                                $0.previewCoverage.lastSpeechSample = classified
                            }
                        }

                        if result.event?.kind == .speechStart {
                            // The user resumed during the thinking allowance. Any previous endpoint
                            // verdict belonged to the partial sentence and must be discarded.
                            pendingEndpoint = nil
                            status.withLock { $0.speechDetected = true; $0.terminalDecision = nil }
                        } else if let event = result.event, event.kind == .speechEnd {
                            let probability = try turnModel.probability(for: recent)
                            let endpoint = Endpoint(probability: probability, time: CACurrentMediaTime())
                            status.withLock {
                                $0.lastProbability = probability
                                $0.lastEndpoint = endpoint
                            }
                            pendingEndpoint = (event.sampleIndex, probability)
                            let requiredSilence = Self.requiredSilence(for: probability, config: config)
                            owLog(String(
                                format: "[SmartTurn] pause detected, completion probability %.3f — waiting %.1f s continuous silence",
                                probability,
                                requiredSilence
                            ))
                        }

                        if let pendingEndpoint, !streamState.triggered {
                            let silence = Double(processedSamples - pendingEndpoint.speechEndSample)
                                / Double(Self.sampleRate)
                            if let endpointDecision = Self.endpointDecision(
                                probability: pendingEndpoint.probability,
                                silenceDuration: silence,
                                sessionElapsed: Double(processedSamples + ignoredSamples)
                                    / Double(Self.sampleRate),
                                config: config
                            ) {
                                status.withLock { $0.terminalDecision = endpointDecision }
                                // Continue classifying buffered audio for preview validation
                                // until capture releases this detector.
                            }
                        }
                    }
                    if finalSampleCount != nil { break itemLoop }
                }
            } catch {
                let message = String(describing: error)
                status.withLock { $0.failure = message }
                owLog("[SmartTurn] unavailable, using level fallback: \(message)")
            }
        }
    }

    deinit {
        continuation.yield(.finish)
        continuation.finish()
        consumer?.cancel()
    }

    /// Audio-thread safe. Work is queued to the detached consumer; the caller never runs ML.
    func feed(_ samples: [Float]) {
        inputBatch.withLock { pending in
            pending.append(contentsOf: samples)
            while pending.count >= 512 {
                continuation.yield(.samples(Array(pending.prefix(512))))
                pending.removeFirst(512)
            }
        }
    }

    /// Starts the timeouts over at `time`: used once a Bluetooth mic actually delivers audio,
    /// so its link setup doesn't eat the no-speech window.
    func restartClock(at time: TimeInterval) {
        startTime = time
    }

    func decision(at time: TimeInterval, levelSpeechDetected: Bool) -> Decision {
        let snapshot = status.withLock { $0 }
        if let terminal = snapshot.terminalDecision { return terminal }
        if let failure = snapshot.failure { return .useLevelFallback(reason: failure) }

        let elapsed = time - startTime
        if elapsed >= config.maxDuration {
            return snapshot.speechDetected || levelSpeechDetected ? .stopMaxDuration : .cancelNoSpeech
        }
        if elapsed >= config.noSpeechTimeout, !snapshot.speechDetected {
            // Very quiet real speech can be missed by Silero on this microphone. Preserve the
            // proven level detector in that case instead of throwing the user's command away.
            return levelSpeechDetected
                ? .useLevelFallback(reason: "Silero did not detect the level-confirmed speech")
                : .cancelNoSpeech
        }
        if !snapshot.ready, elapsed >= config.loadGrace {
            return .useLevelFallback(reason: "models were not ready within the grace period")
        }
        return .continueRecording
    }

    var lastEndpoint: Endpoint? {
        status.withLock { $0.lastEndpoint }
    }

    var previewCoverage: SpeechPreviewCoverage {
        status.withLock { $0.previewCoverage }
    }

    /// Called after capture and its converter have stopped, only for a whole first batch.
    func finishForPreview(with samples: [Float]) {
        status.withLock { $0.previewInputFinished = true }
        continuation.yield(.finalSamples(samples))
        continuation.finish()
    }

    func completedPreviewCoverage() async -> SpeechPreviewCoverage {
        if status.withLock({ $0.previewInputFinished }) { await consumer?.value }
        return previewCoverage
    }

    func requiredSilence(after endpoint: Endpoint) -> TimeInterval {
        Self.requiredSilence(for: endpoint.probability, config: config)
    }

    var summary: String {
        status.withLock { state in
            if let failure = state.failure { return "fallback=\(failure)" }
            let probability = state.lastProbability.map { String(format: "%.3f", $0) } ?? "nil"
            return "ready=\(state.ready) speech=\(state.speechDetected) probability=\(probability)"
        }
    }
}

/// Kept internal so the packaged model and its I/O contract can be smoke-tested without starting
/// a microphone session.
final class SmartTurnModel {
    private let model: MLModel

    init() throws {
        guard let url = Bundle.module.url(forResource: "smart_turn", withExtension: "mlmodelc") else {
            throw SmartTurnError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func probability(for samples: [Float]) throws -> Float {
        let input = try MLMultiArray(shape: [1, NSNumber(value: SmartTurnEndpointDetector.windowSamples)], dataType: .float32)
        let pointer = input.dataPointer.bindMemory(
            to: Float.self,
            capacity: SmartTurnEndpointDetector.windowSamples
        )
        pointer.update(repeating: 0, count: SmartTurnEndpointDetector.windowSamples)
        let tail = samples.suffix(SmartTurnEndpointDetector.windowSamples)
        let offset = SmartTurnEndpointDetector.windowSamples - tail.count
        for (index, sample) in tail.enumerated() {
            pointer[offset + index] = sample
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
        let output = try model.prediction(from: provider)
        guard let probability = output.featureValue(for: "probability")?.multiArrayValue?[0].floatValue else {
            throw SmartTurnError.invalidOutput
        }
        return probability
    }
}

private enum SmartTurnError: LocalizedError {
    case modelMissing
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: "Bundled smart_turn.mlmodelc is missing"
        case .invalidOutput: "Smart Turn did not return its probability output"
        }
    }
}
