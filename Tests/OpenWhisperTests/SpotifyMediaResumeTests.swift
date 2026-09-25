import XCTest
@testable import OpenWhisper

final class SpotifyMediaResumeTests: XCTestCase {
    func testPlaybackCommandsKeepPausedMediaReleased() {
        for text in ["Spotify'ı durdur", "Spotify'da Tarkan çal"] {
            XCTAssertNotNil(SpotifyManager.explicitIntent(in: text), text)
            XCTAssertFalse(SpotifyManager.resumesPausedMedia(afterCommand: text), text)
        }
    }

    func testVolumeCommandAndDictationResumePausedMedia() {
        for text in ["sesi yüzde 30 yap", "Bugün hava çok güzel"] {
            XCTAssertTrue(SpotifyManager.resumesPausedMedia(afterCommand: text), text)
        }
    }
}
