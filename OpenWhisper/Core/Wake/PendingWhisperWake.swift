import Foundation

/// A bounded, revocable wake request. Loading can outlive cancellation, but it can never
/// authorize a later recording after this request was cancelled or expired.
@MainActor
final class PendingWhisperWake {
    static let timeout: TimeInterval = 15
    let inputUID: String
    let clipID: UUID?
    let deadline: TimeInterval
    private(set) var accepted = false
    private(set) var cancelled = false

    init(inputUID: String, clipID: UUID?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.inputUID = inputUID
        self.clipID = clipID
        deadline = now + Self.timeout
    }

    func isValid(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        !cancelled && now < deadline
    }

    func cancel() { cancelled = true; accepted = false }

    /// Match the warm-model direct-wake policy: a detected call plus an enrolled speaker match,
    /// or a score at `WakeWordListener.confirmedScore`, is sufficient (the warm path starts those
    /// without a word check too; the cold model wrote a clear 0.65 "Jarvis" as "Hairs", 27 Oct
    /// 2026). Weak direct wakes and grey-zone candidates still need word verification.
    static func verifyWake(isDirect: Bool, speakerMatched: Bool, score: Float,
                           verifyWords: () async -> Bool) async -> Bool {
        if isDirect && speakerMatched {
            owLog("[WhisperWake] Direct wake accepted by speaker match")
            return true
        }
        if isDirect && score >= WakeWordListener.confirmedScore {
            owLog(String(format: "[WhisperWake] Direct wake accepted by score %.2f", score))
            return true
        }
        return await verifyWords()
    }

    func evaluate(
        load: () async -> Bool,
        verify: () async -> Bool,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async -> Bool {
        guard isValid(at: now()), !Task.isCancelled else { return false }
        let loaded = await load()
        guard loaded, isValid(at: now()), !Task.isCancelled else { return false }
        let verified = await verify()
        guard verified, isValid(at: now()), !Task.isCancelled else { return false }
        accepted = true
        return true
    }
}
