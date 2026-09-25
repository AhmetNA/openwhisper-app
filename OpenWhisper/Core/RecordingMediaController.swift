import Foundation

struct MediaPlaybackSnapshot: Equatable {
    let playerID: String
    var isPlaying: Bool
    var itemID: String? = nil
    var position: Double? = nil
    var route: String? = nil

    func matches(_ other: Self) -> Bool {
        playerID == other.playerID && itemID == other.itemID
    }

    func canResume(after paused: Self) -> Bool {
        guard !isPlaying, matches(paused) else { return false }
        if let position, let previous = paused.position, abs(position - previous) > 2 { return false }
        return true
    }
}

protocol RecordingMediaTransport {
    func pausePlayingItems() -> [MediaPlaybackSnapshot]
    func resume(_ receipt: MediaPlaybackSnapshot)
}

/// The worker queue keeps slow OS calls away from the microphone/main thread. A release
/// while pause is in flight queues resume behind it; a new recording queues after resume.
final class RecordingMediaController {
    static let shared = RecordingMediaController()
    private let queue = DispatchQueue(label: "com.openwhisper.recording-media", qos: .userInitiated)
    private let transport: RecordingMediaTransport
    private var active = false
    private var receipts: [MediaPlaybackSnapshot] = []

    init(transport: RecordingMediaTransport = NowPlayingTransport()) {
        self.transport = transport
    }

    func begin() {
        queue.async { [self] in
            guard !active else { return }
            active = true
            receipts = transport.pausePlayingItems()
            owLog("[RecordingMedia] Tracking \(receipts.count) paused player(s)")
        }
    }

    /// `resuming: false` releases the paused players without playing them again: a voice
    /// command such as "durdur" or "X çal" has decided what should be playing now.
    func end(resuming: Bool = true) {
        queue.async { [self] in
            guard active else { return }
            active = false
            if resuming {
                // Receipt order matters: MediaRemote players come first, while the one paused
                // over the global route still holds it; scripted players can't steal it then.
                for receipt in receipts { transport.resume(receipt) }
            } else if !receipts.isEmpty {
                owLog("[RecordingMedia] Command changed playback; not resuming \(receipts.count) player(s)")
            }
            receipts = []
        }
    }

    /// Shutdown/tests only. Never used on the microphone's realtime thread.
    func waitUntilIdle() { queue.sync {} }
}

protocol MediaRemoteAccess {
    func snapshots() -> [MediaPlaybackSnapshot]
    func snapshot(for player: MediaPlaybackSnapshot) -> MediaPlaybackSnapshot?
    func send(_ command: MediaTransportCommand, to expected: MediaPlaybackSnapshot) -> Bool
}

enum MediaTransportCommand: UInt32 { case play = 0, pause = 1 }

enum ScriptedPauseResult: Equatable {
    /// Not running, or its script failed (e.g. permission): leave it to MediaRemote.
    case unavailable
    case notPlaying
    /// Paused; the token identifies what to resume (a track ID, a file path…).
    case paused(token: String)
}

/// A player driven through its own scripting interface. MediaRemote only delivers commands
/// to the global Now Playing app, so with two players on it can pause just one of them;
/// scripting reaches each app separately and reports real playback state.
protocol ScriptedMediaPlayer {
    var name: String { get }
    /// Now Playing entries (by bundle ID) this player covers once its script has run.
    var coveredBundleIDs: Set<String> { get }
    func pause() -> ScriptedPauseResult
    /// Plays only what `pause` paused, and only if it is still paused.
    func resume(token: String) -> Bool
}

struct NowPlayingTransport: RecordingMediaTransport {
    static let scriptedPrefix = "script:"

    let remote: MediaRemoteAccess
    let players: [ScriptedMediaPlayer]
    let wait: () -> Void

    init(
        remote: MediaRemoteAccess = SystemNowPlayingBridge(),
        players: [ScriptedMediaPlayer] = ScriptedMediaPlayers.all,
        wait: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
    ) {
        self.remote = remote
        self.players = players
        self.wait = wait
    }

    func pausePlayingItems() -> [MediaPlaybackSnapshot] {
        var scripted: [MediaPlaybackSnapshot] = []
        var covered = Set<String>()
        for player in players {
            switch player.pause() {
            case .unavailable:
                continue
            case .notPlaying:
                covered.formUnion(player.coveredBundleIDs)
            case .paused(let token):
                covered.formUnion(player.coveredBundleIDs)
                owLog("[RecordingMedia] Paused \(player.name)")
                scripted.append(.init(playerID: Self.scriptedPrefix + player.name, isPlaying: false, itemID: token))
            }
        }
        // The rest (Stremio, or Safari without script access) only through MediaRemote.
        var seen = Set<String>()
        let playing = remote.snapshots().filter {
            $0.isPlaying && !covered.contains(Self.bundleID(of: $0)) && seen.insert($0.playerID).inserted
        }
        return playing.compactMap { pause($0) } + scripted
    }

    /// Player IDs are "pid:bundle:player".
    private static func bundleID(of snapshot: MediaPlaybackSnapshot) -> String {
        let parts = snapshot.playerID.split(separator: ":", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    private func pause(_ before: MediaPlaybackSnapshot) -> MediaPlaybackSnapshot? {
        guard remote.send(.pause, to: before) else {
            owLog("[RecordingMedia] Pause not delivered (not the Now Playing app?): \(before.playerID)")
            return nil
        }
        var lastState: MediaPlaybackSnapshot?
        for _ in 0..<10 {
            wait()
            guard let after = remote.snapshot(for: before) else { continue }
            guard after.matches(before) else { return nil }
            lastState = after
            if !after.isPlaying {
                owLog("[RecordingMedia] Paused \(before.playerID)")
                return after
            }
        }
        // A successful pause can temporarily remove its metadata. Keep ownership so that
        // end() can retry that exact route, but it must still verify paused state before play.
        if lastState == nil {
            var pending = before
            pending.isPlaying = false
            pending.position = nil
            owLog("[RecordingMedia] Pause submitted; retaining route pending verification: \(before.playerID)")
            return pending
        }
        return nil
    }

    func resume(_ receipt: MediaPlaybackSnapshot) {
        if receipt.playerID.hasPrefix(Self.scriptedPrefix) {
            let name = receipt.playerID.dropFirst(Self.scriptedPrefix.count)
            let player = players.first { $0.name == name }
            let resumed = receipt.itemID.flatMap { token in player?.resume(token: token) } ?? false
            owLog(resumed ? "[RecordingMedia] Resumed \(receipt.playerID)"
                          : "[RecordingMedia] Resume skipped: state/item changed or unavailable: \(receipt.playerID)")
            return
        }
        guard let before = remote.snapshot(for: receipt), before.canResume(after: receipt), remote.send(.play, to: before) else {
            owLog("[RecordingMedia] Resume skipped: state/item changed or unavailable: \(receipt.playerID)")
            return
        }
        for _ in 0..<10 {
            wait()
            guard let after = remote.snapshot(for: receipt), after.matches(receipt) else { break }
            if after.isPlaying {
                owLog("[RecordingMedia] Resumed \(receipt.playerID)")
                return
            }
        }
        owLog("[RecordingMedia] Resume was not confirmed")
    }
}
