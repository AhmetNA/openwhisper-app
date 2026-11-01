import XCTest
@testable import OpenWhisper

/// Spotify and video commands while the dictation language is English.
@MainActor
final class EnglishMediaCommandTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    private func intent(_ text: String) -> SpotifyManager.ExplicitSpotifyIntent? {
        SpotifyManager.explicitIntent(in: text)
    }

    func testTransport() {
        for text in ["Pause the music", "Stop the music", "Pause Spotify", "Please pause the song"] {
            XCTAssertEqual(intent(text), .pause, text)
        }
        XCTAssertEqual(intent("Resume the music"), .play)
        XCTAssertEqual(intent("Continue playing"), .play)
        for text in ["Next song", "Skip this song", "Play the next track", "Go to the next song"] {
            XCTAssertEqual(intent(text), .next, text)
        }
        XCTAssertEqual(intent("Previous song"), .previous)
        XCTAssertEqual(intent("Go back to the previous track"), .previous)
    }

    func testVolumeCurrentAndLike() {
        XCTAssertEqual(intent("Set the volume to 40"), .setVolume(40))
        XCTAssertEqual(intent("Volume 30"), .setVolume(30))
        XCTAssertEqual(intent("Turn the volume up"), .adjustVolume(20))
        XCTAssertEqual(intent("Turn the music down a bit"), .adjustVolume(-10))
        XCTAssertEqual(intent("Increase the volume"), .adjustVolume(20))
        XCTAssertEqual(intent("Lower the volume a bit"), .adjustVolume(-10))
        XCTAssertEqual(intent("What song is this?"), .currentTrack)
        XCTAssertEqual(intent("What's playing?"), .currentTrack)
        XCTAssertEqual(intent("Like this song"), .likeCurrentTrack)
        XCTAssertEqual(intent("Play my liked songs"), .playLikedSongs)
        XCTAssertEqual(intent("Play some music"), .playLikedSongs)
    }

    func testSearch() {
        let cases: [(String, SpotifySearchRequest)] = [
            ("Play Imagine Dragons on Spotify", .freeText("imagine dragons")),
            ("Open Taylor Swift from Spotify", .freeText("taylor swift")),
            ("Play the song Blinding Lights", SpotifySearchRequest(kind: .track, title: "blinding lights", artist: "", freeText: "blinding lights")),
            ("Play the album Midnights by Taylor Swift",
             SpotifySearchRequest(kind: .album, title: "midnights", artist: "taylor swift", freeText: "midnights by taylor swift")),
            ("Play my workout playlist", SpotifySearchRequest(kind: .playlist, title: "workout", artist: "", freeText: "workout")),
        ]
        for (text, request) in cases { XCTAssertEqual(intent(text), .search(request), text) }
        // A "by" inside a title: the whole name stays the last query tried.
        guard case .search(let stand)? = intent("Play Stand by Me on Spotify") else { return XCTFail() }
        XCTAssertEqual(stand.searchQueries.last, "stand by me")
    }

    func testProseAndVideoStayOut() {
        for text in ["I paused the song yesterday", "Stop the music at ten", "Play the game tomorrow",
                     "Pause the video", "Play Shape of You by Ed Sheeran"] {
            XCTAssertNil(intent(text), text)
        }
    }

    func testVideo() {
        let cases: [(String, VideoAction)] = [
            ("Pause the video", .pause), ("Play the video", .play), ("Resume the video", .play),
            ("Skip ahead 10 seconds", .seekBy(10)), ("Go back a minute", .seekBy(-60)),
            ("Rewind 30 seconds", .seekBy(-30)), ("Next video", .next), ("Restart the video", .restart),
            ("Turn on subtitles", .subtitles(on: true)), ("Full screen", .fullscreen), ("Mute the video", .mute(true)),
        ]
        for (text, action) in cases { XCTAssertEqual(SystemCommandParser.parseVideoRequest(text), action, text) }
        XCTAssertNil(SystemCommandParser.parseVideoRequest("Pause"))
    }

    func testTurkishSettingIgnoresEnglishRules() {
        UserDefaults.standard.set("tr", forKey: "language")
        XCTAssertNil(intent("Next song"))
        XCTAssertNil(SystemCommandParser.parseVideoRequest("Pause the video"))
        XCTAssertEqual(intent("Sonraki şarkıya geç"), .next)
    }
}
