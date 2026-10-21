import Foundation

/// The Settings choice for DeepFilterNet. `.automatic` runs it unless the mic's room is clearly
/// quiet; the choice is made once per recording, never mid-recording (like the input mic).
enum DeepFilterSetting: String, CaseIterable, Sendable {
    case automatic
    case on
    case off

    /// The processing chain speaker profiles are enrolled and matched under. Automatic counts as
    /// DeepFilterNet: it is on in every room that is not clean, and switching it off in a quiet
    /// one changes the embedding input far less than re-enrolling every profile would.
    var profileMode: AudioProcessingMode { self == .off ? .off : .deepFilterNet }
}

/// A room's noise floor measured on the raw mic (before gain, echo cancellation and DeepFilterNet,
/// which would hide the very noise being measured).
struct NoiseFloorMeasurement: Equatable, Sendable {
    var dbfs: Double
    var seconds: Double
    var measuredAt: Date
}

/// The raw input's noise floor over a recording: the 10th percentile of per-buffer RMS levels,
/// so speech above it does not count. A fixed histogram keeps the audio thread allocation-free.
struct RawNoiseFloorMeter: Sendable {
    static let warmupSeconds = 0.3
    /// Below this a buffer is digital zeros (a link not up yet, a muted mic), not a room.
    static let digitalSilenceDBFS = -100.0
    static let binWidthDB = 0.5
    static let lowestDBFS = -120.0
    static let percentile = 0.1

    private var bins = [Int](repeating: 0, count: Int(-lowestDBFS / binWidthDB))
    private var warmupLeft = warmupSeconds
    private(set) var measuredSeconds = 0.0
    private var bufferCount = 0

    mutating func add(rms: Float, frames: Int, sampleRate: Double) {
        guard frames > 0, sampleRate > 0 else { return }
        let seconds = Double(frames) / sampleRate
        if warmupLeft > 0 {
            warmupLeft -= seconds
            return
        }
        let db = 20 * log10(Double(max(rms, 1e-9)))
        guard db > Self.digitalSilenceDBFS else { return }
        let index = min(bins.count - 1, max(0, Int((db - Self.lowestDBFS) / Self.binWidthDB)))
        bins[index] += 1
        bufferCount += 1
        measuredSeconds += seconds
    }

    var floorDBFS: Double? {
        guard bufferCount > 0 else { return nil }
        let target = max(1, Int((Double(bufferCount) * Self.percentile).rounded(.up)))
        var seen = 0
        for (index, count) in bins.enumerated() {
            seen += count
            if seen >= target { return Self.lowestDBFS + (Double(index) + 0.5) * Self.binWidthDB }
        }
        return nil
    }
}

struct DeepFilterDecision: Equatable, Sendable {
    let enabled: Bool
    let reason: String
}

/// Decides at each recording's start whether DeepFilterNet runs, from the last raw noise floor
/// measured on the same input. It leans towards on: off only when the room is clearly quiet,
/// back on well before it gets noisy (hysteresis), and on whenever it doesn't know.
/// Measurements taken while a recording runs only affect the next decision.
struct DeepFilterAutoDecider {
    /// The built-in mic's raw floor in a quiet room reads about -74…-78 dBFS (this user's wake
    /// clips; the voice auto-stop's floor, 21 Oct 2026), and -45…-25 dBFS with sound around. The
    /// band between the two thresholds keeps the last state.
    static let cleanBelowDBFS = -62.0
    static let noisyFromDBFS = -55.0
    static let maxMeasurementAge: TimeInterval = 10 * 60
    static let minMeasuredSeconds = 1.5

    private var floors: [String: NoiseFloorMeasurement] = [:]
    private var lastAutoEnabled: [String: Bool] = [:]
    /// The input of the recording now running; its measurement is filed under it at stop.
    private(set) var activeDevice: String?

    func floor(for device: String) -> NoiseFloorMeasurement? { floors[device] }

    mutating func decide(
        setting: DeepFilterSetting,
        device: String,
        mediaPlaying: Bool,
        echoCancellation: Bool,
        measuresRoom: Bool = true,
        now: Date = Date()
    ) -> DeepFilterDecision {
        // A voice test replaces the mic with a clip over a synthetic floor: not this room.
        activeDevice = measuresRoom ? device : nil
        switch setting {
        case .on: return DeepFilterDecision(enabled: true, reason: "setting on")
        case .off: return DeepFilterDecision(enabled: false, reason: "setting off")
        case .automatic: break
        }
        // Mac playback must never reach the transcript; the denoiser helps hold back what echo
        // cancellation leaves.
        if mediaPlaying || echoCancellation {
            return DeepFilterDecision(enabled: true, reason: echoCancellation ? "echo cancellation" : "media playing")
        }
        guard let measurement = floors[device], now.timeIntervalSince(measurement.measuredAt) <= Self.maxMeasurementAge else {
            lastAutoEnabled[device] = true
            return DeepFilterDecision(enabled: true, reason: floors[device] == nil ? "no floor yet" : "floor stale")
        }
        let previous = lastAutoEnabled[device] ?? true
        let enabled: Bool
        let reason: String
        if measurement.dbfs < Self.cleanBelowDBFS {
            enabled = false
            reason = "clean"
        } else if measurement.dbfs >= Self.noisyFromDBFS {
            enabled = true
            reason = "noisy"
        } else {
            enabled = previous
            reason = "in band, kept"
        }
        lastAutoEnabled[device] = enabled
        return DeepFilterDecision(enabled: enabled, reason: reason)
    }

    /// Files the stopped recording's floor under its input. Too short a recording says nothing.
    @discardableResult
    mutating func recordingStopped(floorDBFS: Double?, measuredSeconds: Double, at now: Date = Date()) -> Bool {
        defer { activeDevice = nil }
        guard let device = activeDevice, let floorDBFS, measuredSeconds >= Self.minMeasuredSeconds else { return false }
        floors[device] = NoiseFloorMeasurement(dbfs: floorDBFS, seconds: measuredSeconds, measuredAt: now)
        return true
    }
}
