import Foundation

/// WhisperKit is shared by wake checks, previews and final decoding. Actor isolation alone
/// is insufficient: a decode suspends. Hold the slot across the whole operation.
actor TranscriptionWorkGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    /// Optional previews never queue behind real work or consume a waiting final decode's slot.
    func preview<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T? {
        guard !busy else { return nil }
        busy = true
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}
