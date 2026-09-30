import Foundation

/// Per-recording latency accounting for the voice pipeline. Some work (notably streaming
/// transcription) overlaps audio capture, so stage totals are deliberately reported alongside
/// the user-visible stop-to-output wall time instead of pretending they form one serial sum.
final class VoiceLatencyTracker: @unchecked Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case capture = "audio capture"
        case queueWait = "queue wait"
        case transcription = "transcription pipeline"
        case decision = "decision / routing"
        case preprocessing = "text preprocessing"
        case action = "app action"
        case paste = "paste / delivery"
        case cleanup = "LLM cleanup"

        var title: String {
            switch self {
            case .capture: "Ses kaydı"
            case .queueWait: "Kuyruk bekleme"
            case .transcription: "Transkripsiyon hattı"
            case .decision: "Karar / yönlendirme"
            case .preprocessing: "Metin ön işleme"
            case .action: "Uygulama eylemi"
            case .paste: "Yapıştırma / teslim"
            case .cleanup: "LLM temizleme"
            }
        }
    }

    private struct Measurement {
        var seconds: TimeInterval = 0
        var count = 0
        var detail: String?
    }

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let logger: @Sendable (String) -> Void
    private let startedAt: TimeInterval
    private var stoppedAt: TimeInterval?
    private var decisionStartedAt: TimeInterval?
    private var measurements: [Stage: Measurement] = [:]
    private var asyncOutputPending = false
    private var completed = false

    init(
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        logger: @escaping @Sendable (String) -> Void = { owLog($0) }
    ) {
        self.now = now
        self.logger = logger
        self.startedAt = now()
    }

    func timestamp() -> TimeInterval { now() }

    func record(_ stage: Stage, since start: TimeInterval, detail: String? = nil) {
        let duration = max(0, now() - start)
        let completedAlready = lock.withLock {
            var measurement = measurements[stage] ?? Measurement()
            measurement.seconds += duration
            measurement.count += 1
            if let detail { measurement.detail = detail }
            measurements[stage] = measurement
            return completed
        }
        // Cleanup intentionally continues after the first verified paste. Preserve the fast
        // first-result summary, then make this later work visible as its own latency event.
        if completedAlready {
            let suffix = detail.map { " — \($0)" } ?? ""
            logger("[Latency] Sonradan tamamlanan: \(stage.title) \(Self.format(duration))\(suffix)")
        }
    }

    func markRecordingStopped() {
        let end = now()
        lock.withLock {
            guard stoppedAt == nil else { return }
            stoppedAt = end
            measurements[.capture] = Measurement(seconds: max(0, end - startedAt), count: 1)
        }
    }

    func beginDecision() {
        lock.withLock {
            if decisionStartedAt == nil { decisionStartedAt = now() }
        }
    }

    func finishDecision(route: String) {
        let end = now()
        lock.withLock {
            guard let start = decisionStartedAt else { return }
            decisionStartedAt = nil
            var measurement = measurements[.decision] ?? Measurement()
            measurement.seconds += max(0, end - start)
            measurement.count += 1
            measurement.detail = route
            measurements[.decision] = measurement
        }
    }

    /// The synchronous routing function is returning, but paste verification will finish later.
    func expectAsyncOutput() {
        lock.withLock { asyncOutputPending = true }
    }

    func markOutput(_ outcome: String) {
        finish(outcome: outcome, force: true)
    }

    /// Covers rejection/empty/error exits. It intentionally does nothing while a paste callback
    /// owns completion, preventing an early summary before delivery is actually verified.
    func finishIfNeeded(_ outcome: String = "işlem tamamlandı") {
        finish(outcome: outcome, force: false)
    }

    private func finish(outcome: String, force: Bool) {
        let endedAt = now()
        let lines: [String]? = lock.withLock {
            guard !completed else { return nil }
            if asyncOutputPending && !force { return nil }
            if let start = decisionStartedAt {
                decisionStartedAt = nil
                var measurement = measurements[.decision] ?? Measurement()
                measurement.seconds += max(0, endedAt - start)
                measurement.count += 1
                measurement.detail = outcome
                measurements[.decision] = measurement
            }
            completed = true
            asyncOutputPending = false
            return Self.makeSummaryLines(
                measurements: measurements,
                startedAt: startedAt,
                stoppedAt: stoppedAt,
                endedAt: endedAt,
                outcome: outcome
            )
        }
        lines?.forEach(logger)
    }

    private static func makeSummaryLines(
        measurements: [Stage: Measurement],
        startedAt: TimeInterval,
        stoppedAt: TimeInterval?,
        endedAt: TimeInterval,
        outcome: String
    ) -> [String] {
        let ordered = Stage.allCases.compactMap { stage -> String? in
            guard let value = measurements[stage], value.count > 0 else { return nil }
            let count = value.count > 1 ? " ×\(value.count)" : ""
            let detail = value.detail.map { " — \($0)" } ?? ""
            return "\(stage.title): \(format(value.seconds))\(count)\(detail)"
        }
        let processing = measurements
            .filter { $0.key != .capture }
            .max { $0.value.seconds < $1.value.seconds }
        let bottleneck = processing.map {
            "[Latency] Darboğaz: \($0.key.title) \(format($0.value.seconds))"
        } ?? "[Latency] Darboğaz: ölçülebilen işlem aşaması yok"
        let stopToOutput = stoppedAt.map { max(0, endedAt - $0) }
        let wall = "Kayıt başlangıcı → sonuç: \(format(max(0, endedAt - startedAt)))"
        let afterStop = stopToOutput.map { "Mikrofon durdu → sonuç: \(format($0))" } ?? "Mikrofon duruşu ölçülmedi"
        return [
            "[Latency] Aşamalar: " + (ordered.isEmpty ? "ölçüm yok" : ordered.joined(separator: " | ")),
            "[Latency] Kritik süre: \(afterStop) | \(wall) | Sonuç: \(outcome)",
            bottleneck,
        ]
    }

    private static func format(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.2f sn", seconds)
    }
}
