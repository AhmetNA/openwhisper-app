import XCTest
@testable import OpenWhisper

final class SoundAlikeCorrectorTests: XCTestCase {
    private let entries = SoundAlikeCorrector.parse(SoundAlikeCorrector.defaultFile)

    private func fix(_ text: String) -> String { SoundAlikeCorrector.correct(text, entries: entries).0 }

    func testRealSpotifyMishearings() {
        // All heard on 25 Sep 2026.
        XCTAssertEqual(fix("Sputfayda şarkı aç"), "Spotify'da şarkı aç")
        XCTAssertEqual(fix("Spatfada şarkı aç."), "Spotify'da şarkı aç.")
        XCTAssertEqual(fix("Kutfaida şarkac."), "Spotify'da şarkac.")
        XCTAssertEqual(fix("Pöt fayda şarkıc."), "Spotify'da şarkıc.")
        XCTAssertEqual(fix("supotufy aç"), "Spotify aç")
        XCTAssertEqual(fix("spotfader dur"), "Spotify dur")
    }

    func testUnlistedSoundAlikeIsCaughtToo() {
        XCTAssertEqual(fix("Spotifayda bir şey çal"), "Spotify'da bir şey çal")
        XCTAssertEqual(fix("Spotfaydan müzik aç"), "Spotify'dan müzik aç")
    }

    func testEverydayWordsUntouched() {
        let text = "spor spot spotu sporda potansiyel sofa stop sıfat şifa sepet kutu fayda faydalı aç kapat YouTube Spotify'da"
        XCTAssertEqual(fix(text), text)
    }

    func testOtherEntries() {
        XCTAssertEqual(fix("vatsapı aç"), "WhatsApp'ı aç")
        XCTAssertEqual(fix("Blututu kapat"), "Bluetooth'u kapat")
    }

    func testFileFormat() {
        let parsed = SoundAlikeCorrector.parse("# yorum\nFoo Bar = foo bar, fubar\nBaz [bas] =\n")
        XCTAssertEqual(parsed, [
            .init(canonical: "Foo Bar", spoken: nil, variants: ["foo bar", "fubar"]),
            .init(canonical: "Baz", spoken: "bas", variants: []),
        ])
    }
}
