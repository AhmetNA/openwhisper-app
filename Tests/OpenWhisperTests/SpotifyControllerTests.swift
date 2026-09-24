import XCTest
@testable import OpenWhisper

/// Only input-validation paths are exercised: each returns before any Web API request or
/// AppleScript runs, so these tests never touch the real Spotify app or account.
final class SpotifyControllerTests: XCTestCase {
    func testTrackURIValidationRejectsAppleScriptInjection() {
        XCTAssertTrue(SpotifyController.isValidTrackURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC"))

        let malicious = [
            "spotify:track:abc\" & (do shell script \"id\") & \"",
            "spotify:track:abc\ntell application \"Finder\"",
            "spotify:track:",
            "spotify:album:4uLU6hMCjMI75M1A2tKUQC",
            "spotify:track:abc def",
            "https://open.spotify.com/track/abc",
        ]
        for uri in malicious {
            XCTAssertFalse(SpotifyController.isValidTrackURI(uri), "Accepted unsafe URI: \(uri)")
        }
    }

    func testInvalidTrackURIIsRefusedBeforeAnySideEffect() async {
        let track = SpotifyWebAPI.TrackResult(uri: "spotify:track:x\" & quit & \"", name: "x", artist: "y")
        let result = await SpotifyController.shared.playTrack(track)
        XCTAssertFalse(result.succeeded)
    }

    func testContextURIValidation() {
        XCTAssertTrue(SpotifyController.isValidContextURI("spotify:artist:1Xyo4u8uXC1ZmMpatF05PJ"))
        XCTAssertTrue(SpotifyController.isValidContextURI("spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"))
        XCTAssertFalse(SpotifyController.isValidContextURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertFalse(SpotifyController.isValidContextURI("spotify:album:x\" & quit & \""))
    }

    func testOutOfRangeVolumeIsRefused() async {
        for volume in [-1, 101, 1000] {
            let result = await SpotifyController.shared.setVolume(volume)
            XCTAssertFalse(result.succeeded, "Accepted volume \(volume)")
        }
    }

    func testBlankSearchQueryIsRefused() async {
        let result = await SpotifyController.shared.searchAndPlay(.freeText("   "))
        XCTAssertFalse(result.succeeded)
    }
}
