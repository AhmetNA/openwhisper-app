import XCTest
@testable import OpenWhisper

final class NowPlayingTransportTests: XCTestCase {
    private final class Remote: MediaRemoteAccess {
        var listed: [MediaPlaybackSnapshot]
        var states: [MediaPlaybackSnapshot?]
        var commands: [MediaTransportCommand] = []
        var acceptsCommands = true
        init(listed: [MediaPlaybackSnapshot] = [], _ states: [MediaPlaybackSnapshot?]) {
            self.listed = listed
            self.states = states
        }
        func snapshots() -> [MediaPlaybackSnapshot] { listed }
        func snapshot(for player: MediaPlaybackSnapshot) -> MediaPlaybackSnapshot? {
            states.count > 1 ? states.removeFirst() : states.first ?? nil
        }
        func send(_ command: MediaTransportCommand, to expected: MediaPlaybackSnapshot) -> Bool {
            commands.append(command)
            return acceptsCommands
        }
    }

    private final class Player: ScriptedMediaPlayer {
        let name = "Spotify"
        let coveredBundleIDs: Set<String> = ["com.spotify.client"]
        var available = true
        var playingTrack: String?
        var pausedTrack: String?
        var events: [String] = []
        func pause() -> ScriptedPauseResult {
            guard available else { return .unavailable }
            guard let track = playingTrack else { return .notPlaying }
            events.append("pause")
            playingTrack = nil
            pausedTrack = track
            return .paused(token: track)
        }
        func resume(token: String) -> Bool {
            guard pausedTrack == token else { return false }
            events.append("play:\(token)")
            return true
        }
    }

    private let paused = MediaPlaybackSnapshot(playerID: "1519:com.apple.WebKit.GPU:default", isPlaying: false, itemID: "video-1", position: 20)
    private var playing: MediaPlaybackSnapshot {
        var value = paused
        value.isPlaying = true
        return value
    }

    private func transport(_ remote: Remote, spotify: Player = Player()) -> NowPlayingTransport {
        NowPlayingTransport(remote: remote, players: [spotify], wait: {})
    }

    func testPlayingMediaReceivesExplicitPauseAndReceipt() {
        let remote = Remote(listed: [playing], [paused])
        XCTAssertEqual(transport(remote).pausePlayingItems(), [paused])
        XCTAssertEqual(remote.commands, [.pause])
    }

    func testAlreadyPausedPlayerIsUntouched() {
        let remote = Remote(listed: [paused], [paused])
        XCTAssertTrue(transport(remote).pausePlayingItems().isEmpty)
        XCTAssertTrue(remote.commands.isEmpty)
    }

    func testSpotifyUsesScriptingEvenWhenNowPlayingListsIt() {
        let listedSpotify = MediaPlaybackSnapshot(playerID: "1423:com.spotify.client:MediaRemote-DefaultPlayer", isPlaying: true, itemID: "uuid-1")
        let remote = Remote(listed: [listedSpotify], [nil])
        let spotify = Player()
        spotify.playingTrack = "spotify:track:1"
        let receipts = transport(remote, spotify: spotify).pausePlayingItems()
        XCTAssertEqual(receipts.map(\.playerID), [NowPlayingTransport.scriptedPrefix + "Spotify"])
        XCTAssertTrue(remote.commands.isEmpty)

        transport(remote, spotify: spotify).resume(receipts[0])
        XCTAssertEqual(spotify.events, ["pause", "play:spotify:track:1"])
    }

    func testSpotifyAndBrowserArePausedTogether() {
        let remote = Remote(listed: [playing], [paused])
        let spotify = Player()
        spotify.playingTrack = "spotify:track:1"
        let receipts = transport(remote, spotify: spotify).pausePlayingItems()
        XCTAssertEqual(receipts.map(\.playerID), [paused.playerID, NowPlayingTransport.scriptedPrefix + "Spotify"])
    }

    func testSpotifyIsPausedWhenNowPlayingMissesIt() {
        let spotify = Player()
        spotify.playingTrack = "spotify:track:1"
        XCTAssertEqual(transport(Remote([nil]), spotify: spotify).pausePlayingItems().count, 1)
    }

    func testUnavailableScriptLeavesPlayerToNowPlaying() {
        let listedSpotify = MediaPlaybackSnapshot(playerID: "1423:com.spotify.client:default", isPlaying: true, itemID: "uuid-1")
        var pausedSpotify = listedSpotify; pausedSpotify.isPlaying = false
        let spotify = Player()
        spotify.available = false
        let remote = Remote(listed: [listedSpotify], [pausedSpotify])
        XCTAssertEqual(transport(remote, spotify: spotify).pausePlayingItems(), [pausedSpotify])
        XCTAssertEqual(remote.commands, [.pause])
    }

    func testSpotifyOnAnotherTrackIsNotResumed() {
        let spotify = Player()
        spotify.pausedTrack = "spotify:track:2"
        let receipt = MediaPlaybackSnapshot(playerID: NowPlayingTransport.scriptedPrefix + "Spotify", isPlaying: false, itemID: "spotify:track:1")
        transport(Remote([nil]), spotify: spotify).resume(receipt)
        XCTAssertTrue(spotify.events.isEmpty)
    }

    func testResumeConfirmedPausedPlayer() {
        let remote = Remote([paused, playing])
        transport(remote).resume(paused)
        XCTAssertEqual(remote.commands, [.play])
    }

    func testChangedPlayerTrackSeekAndManualPlayDoNotResume() {
        let player = MediaPlaybackSnapshot(playerID: "52:com.apple.Music:default", isPlaying: false)
        var track = paused; track.itemID = "video-2"
        var seek = paused; seek.position = 100
        for state in [player, track, seek, playing, nil] {
            let remote = Remote([state])
            transport(remote).resume(paused)
            XCTAssertTrue(remote.commands.isEmpty)
        }
    }

    func testRejectedPauseNeverProducesReceipt() {
        let remote = Remote(listed: [playing], [playing])
        remote.acceptsCommands = false
        XCTAssertTrue(transport(remote).pausePlayingItems().isEmpty)
    }

    func testStillPlayingAfterPauseDoesNotProduceReceipt() {
        let remote = Remote(listed: [playing], [playing])
        XCTAssertTrue(transport(remote).pausePlayingItems().isEmpty)
    }

    func testPlayerChangeDuringPauseDoesNotProduceReceipt() {
        let changed = MediaPlaybackSnapshot(playerID: "15:com.apple.Music:default", isPlaying: false)
        let remote = Remote(listed: [playing], [changed])
        XCTAssertTrue(transport(remote).pausePlayingItems().isEmpty)
    }

    func testUnavailableMetadataStillRequiresSamePlayerAndPausedState() {
        let receipt = MediaPlaybackSnapshot(playerID: paused.playerID, isPlaying: false)
        var after = receipt; after.isPlaying = true
        let remote = Remote([receipt, after])
        transport(remote).resume(receipt)
        XCTAssertEqual(remote.commands, [.play])
    }
}
