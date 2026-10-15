import XCTest
@testable import OpenWhisper

final class VideoCommandTests: XCTestCase {
    private func video(_ text: String) -> VideoAction? {
        guard case .video(let action)? = SystemCommandParser.parse(text) else { return nil }
        return action
    }

    func testPlayAndPause() {
        XCTAssertEqual(video("Videoyu durdur."), .pause)
        XCTAssertEqual(video("Hey Jarvis, videoyu duraklat"), .pause)
        XCTAssertEqual(video("YouTube'u durdur"), .pause)
        XCTAssertEqual(video("Durdur videoyu"), .pause)
        XCTAssertEqual(video("Filmi durdur lütfen"), .pause)
        XCTAssertEqual(video("Videoyu başlat"), .play)
        XCTAssertEqual(video("Videoya devam et"), .play)
        XCTAssertEqual(video("Videoyu kaldığı yerden devam ettir"), .play)
        XCTAssertEqual(video("Videoyu oynat."), .play)
    }

    func testRestartAndSeek() {
        XCTAssertEqual(video("Videoyu başa sar"), .restart)
        XCTAssertEqual(video("Videoyu sıfıra al"), .restart)
        XCTAssertEqual(video("Videoyu baştan başlat"), .restart)
        XCTAssertEqual(video("En başa sar"), .restart)
        XCTAssertEqual(video("10 saniye ileri sar"), .seekBy(10))
        XCTAssertEqual(video("Videoyu 30 saniye geri al"), .seekBy(-30))
        XCTAssertEqual(video("Bir dakika ileri sar"), .seekBy(60))
        XCTAssertEqual(video("1 dakika 30 saniye ileri sar"), .seekBy(90))
        XCTAssertEqual(video("Yarım dakika geri sar"), .seekBy(-30))
        XCTAssertEqual(video("Videoyu biraz ileri sar"), .seekBy(10))
        XCTAssertEqual(video("Videoyu geri sar"), .seekBy(-10))
        XCTAssertEqual(video("Videoyu 5. dakikaya al"), .seekTo(300))
        XCTAssertEqual(video("Videonun 12. dakikasına git"), .seekTo(720))
        XCTAssertEqual(video("Videoyu 2 dakika 30 saniyeye al"), .seekTo(150))
    }

    func testSpeedMuteAndYouTube() {
        XCTAssertEqual(video("Video hızını 1.5 yap"), .speed(1.5))
        XCTAssertEqual(video("Videoyu 2x yap"), .speed(2))
        XCTAssertEqual(video("Hızı bir buçuk yap"), .speed(1.5))
        XCTAssertEqual(video("Videoyu iki kat hızlandır"), .speed(2))
        XCTAssertEqual(video("Videoyu normal hıza al"), .speed(1))
        XCTAssertEqual(video("Hızı normale al"), .speed(1))
        XCTAssertEqual(video("Videoyu hızlandır"), .speedStep(faster: true))
        XCTAssertEqual(video("Videoyu biraz yavaşlat"), .speedStep(faster: false))
        XCTAssertEqual(video("Videonun sesini kapat"), .mute(true))
        XCTAssertEqual(video("Videonun sesini aç"), .mute(false))
        XCTAssertEqual(video("Altyazıyı aç"), .subtitles(on: true))
        XCTAssertEqual(video("Altyazıları kapat"), .subtitles(on: false))
        XCTAssertEqual(video("Sonraki videoya geç"), .next)
        XCTAssertEqual(video("Bu videoyu geç"), .next)
        XCTAssertEqual(video("Tam ekran yap"), .fullscreen)
        XCTAssertEqual(video("Videonun bitmesine ne kadar var?"), .remaining)
        XCTAssertEqual(video("Videonun kaç dakikası kaldı"), .remaining)
        XCTAssertEqual(video("Videonun süresi ne kadar"), .remaining)
    }

    func testNotVideoCommands() {
        // Spotify, volume, Safari history and plain dictation keep their routes.
        XCTAssertNil(video("Durdur"))
        XCTAssertNil(video("Devam et"))
        XCTAssertNil(video("Şarkıyı durdur"))
        XCTAssertNil(video("Sesi 40 yap"))
        XCTAssertEqual(SystemCommandParser.parse("Geri git"), .browser(.back))
        XCTAssertEqual(SystemCommandParser.parse("İleri git"), .browser(.forward))
        XCTAssertEqual(SystemCommandParser.parse("Sessize al"), .mute(true))
        XCTAssertNil(video("Bu videoyu çok beğendim"))
        XCTAssertNil(video("Yarın bir video çekelim"))
        XCTAssertNil(video("Videoyu durdurdum ama sonra devam ettim, çok güzeldi"))
        XCTAssertNil(video("Lofi videosunu oynat"))
        XCTAssertNil(video("5 dakika al"))
        XCTAssertNil(video("Yeni filmin çıkmasına ne kadar var?"))
        XCTAssertNil(video("Dizinin bitmesine ne kadar var bilmiyorum"))
        if case .browser(.search(.youtube, _))? = SystemCommandParser.parse("YouTube'da lofi ara") {} else {
            XCTFail("YouTube search must stay a browser search")
        }
    }

    func testJavaScriptHasNoDoubleQuotes() {
        let actions: [VideoAction] = [.play, .pause, .restart, .seekBy(-10), .seekTo(90), .speed(1.5),
                                      .speedStep(faster: true), .mute(true), .subtitles(on: true), .next, .remaining]
        for action in actions {
            XCTAssertFalse(VideoController.javaScript(for: action).contains("\""), "\(action)")
        }
        XCTAssertTrue(VideoController.javaScript(for: .speed(1.5)).contains("v.playbackRate=1.5"))
    }

    func testFormatting() {
        XCTAssertEqual(VideoController.duration(90), "1 dakika 30 saniye")
        XCTAssertEqual(VideoController.duration(3700), "1 saat 1 dakika")
        XCTAssertEqual(VideoController.clock(150), "2:30")
        XCTAssertEqual(VideoController.rate(1.5), "1,5")
    }
}
