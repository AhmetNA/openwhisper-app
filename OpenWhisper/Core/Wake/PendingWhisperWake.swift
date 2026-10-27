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

    /// Match the warm-model direct-wake policy: a detected call plus an enrolled
    /// speaker match is sufficient. Grey-zone candidates still need word verification.
    static func verifyWake(isDirect: Bool, speakerMatched: Bool,
                           verifyWords: () async -> Bool) async -> Bool {
        if isDirect && speakerMatched {
            owLog("[WhisperWake] Direct wake accepted by speaker match")
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
