import Foundation
import os

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
    /// Also says whether a playing item could not be paused.
    func pausePlayingItemsReportingLeftovers() -> (receipts: [MediaPlaybackSnapshot], leftPlaying: Bool)
    /// `sparingYouTube` leaves YouTube videos playing (see `ScriptedMediaPlayers.safariSparingYouTube`).
    func pausePlayingItemsReportingLeftovers(sparingYouTube: Bool) -> (receipts: [MediaPlaybackSnapshot], leftPlaying: Bool)
    func resume(_ receipt: MediaPlaybackSnapshot)
}

extension RecordingMediaTransport {
    func pausePlayingItemsReportingLeftovers() -> (receipts: [MediaPlaybackSnapshot], leftPlaying: Bool) {
        (pausePlayingItems(), false)
    }

    func pausePlayingItemsReportingLeftovers(sparingYouTube: Bool) -> (receipts: [MediaPlaybackSnapshot], leftPlaying: Bool) {
        pausePlayingItemsReportingLeftovers()
    }
}

/// The worker queue keeps slow OS calls away from the microphone/main thread. A release
/// while pause is in flight queues resume behind it; a new recording queues after resume.
final class RecordingMediaController {
    static let shared = RecordingMediaController()
    private let queue = DispatchQueue(label: "com.openwhisper.recording-media", qos: .userInitiated)
    private let transport: RecordingMediaTransport
    private let pauseDelay: TimeInterval
    private var active = false
    private var pendingPause: DispatchWorkItem?
    private var duckedForYouTube = false
    private var receipts: [MediaPlaybackSnapshot] = []
    private let leftRunning = OSAllocatedUnfairLock(initialState: false)

    /// Something kept playing through the last pause (or the pause hasn't run yet). Buds
    /// sessions read it: their mic hears what plays in the ear only if the pause failed.
    var playbackLeftRunning: Bool { leftRunning.withLock { $0 } }

    init(transport: RecordingMediaTransport = NowPlayingTransport(), pauseDelay: TimeInterval = 2) {
        self.transport = transport
        self.pauseDelay = pauseDelay
    }

    /// `immediately` skips the delay that lets a short Fn tap leave the music alone: for
    /// Bluetooth buds, whose mic hears the music played into the ear.
    /// `sparingYouTube` (wake-word sessions) never pauses a YouTube video: the volume dips 10%
    /// instead, so a false "Jarvis" barely disturbs it.
    func begin(immediately: Bool = false, sparingYouTube: Bool = false) {
        queue.async { [self] in
            guard !active else { return }
            active = true
            leftRunning.withLock { $0 = true }
            if sparingYouTube {
                AudioDucker.shared.duck(by: 0.1)
                duckedForYouTube = true
            }

            let pause = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                self.pendingPause = nil
                let result = self.transport.pausePlayingItemsReportingLeftovers(sparingYouTube: sparingYouTube)
                self.receipts = result.receipts
                self.leftRunning.withLock { $0 = result.leftPlaying }
                owLog("[RecordingMedia] Tracking \(self.receipts.count) paused player(s)" + (result.leftPlaying ? "; something is still playing" : ""))
            }
            pendingPause = pause
            if pauseDelay > 0 && !immediately {
                queue.asyncAfter(deadline: .now() + pauseDelay, execute: pause)
            } else {
                pause.perform()
            }
        }
    }

    /// `resuming: false` releases the paused players without playing them again: a voice
    /// command such as "durdur" or "X çal" has decided what should be playing now.
    func end(resuming: Bool = true) {
        queue.async { [self] in
            guard active else { return }
            active = false
            pendingPause?.cancel()
            pendingPause = nil
            if duckedForYouTube {
                AudioDucker.shared.restore()
                duckedForYouTube = false
            }
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
    let youTubeSparingPlayers: [ScriptedMediaPlayer]
    let wait: () -> Void

    init(
        remote: MediaRemoteAccess = SystemNowPlayingBridge(),
        players: [ScriptedMediaPlayer] = ScriptedMediaPlayers.all,
        youTubeSparingPlayers: [ScriptedMediaPlayer] = ScriptedMediaPlayers.allSparingYouTube,
        wait: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
    ) {
        self.remote = remote
        self.players = players
        self.youTubeSparingPlayers = youTubeSparingPlayers
        self.wait = wait
    }

    func pausePlayingItems() -> [MediaPlaybackSnapshot] {
        pausePlayingItemsReportingLeftovers().receipts
    }

    func pausePlayingItemsReportingLeftovers() -> (receipts: [MediaPlaybackSnapshot], leftPlaying: Bool) {
        pausePlayingItemsReportingLeftovers(sparingYouTube: false)
    }

    func pausePlayingItemsReportingLeftovers(sparingYouTube: Bool) -> (receipts: [MediaPlaybackSnapshot], leftPlaying: Bool) {
        var scripted: [MediaPlaybackSnapshot] = []
        // Without its script, Safari's YouTube can't be told from its other tabs: MediaRemote
        // leaves Safari alone then.
        var covered: Set<String> = sparingYouTube ? ScriptedMediaPlayers.safari.coveredBundleIDs : []
        for player in sparingYouTube ? youTubeSparingPlayers : players {
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
        let paused = playing.compactMap { pause($0) }
        // A spared video may still be playing.
        return (paused + scripted, sparingYouTube || paused.count < playing.count)
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
