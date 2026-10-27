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

    func testPageIsNotSpotify() {
        // 27 Oct 2026: "Bu sayfayı özetle" became "Bu Spotify'ı özetle" and was typed instead.
        let text = "Bu sayfayı özetle. Sayfada, sayfaya, sayfanın, sayfası, sayfalar, sofaya, safaya"
        XCTAssertEqual(fix(text), text)
        // A name already right is not glued to the next word: "Spotify 5" kept its 5.
        for text in ["Spotify 5 dakika sonra kapansın", "Spotify vs. Apple Music", "Spotify ile aç"] {
            XCTAssertEqual(fix(text), text)
        }
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

    func testAppSectionOnlyInThatApp() {
        let claude = AppFocus(appName: "Claude", entries: entries)
        let inClaude = AppFocus.soundAlikeEntries(entries, focus: claude)
        let keep = ["Google Cloud"]
        XCTAssertEqual(SoundAlikeCorrector.correct("Cloud'a sor, cloudda dene", entries: inClaude, keeping: keep).0, "Claude'a sor, Claude'da dene")
        XCTAssertEqual(SoundAlikeCorrector.correct("Google Cloud'da iCloud ve Cloudflare", entries: inClaude, keeping: keep).0,
                       "Google Cloud'da iCloud ve Cloudflare")
        // Heard in Claude, 24 Oct 2026.
        XCTAssertEqual(SoundAlikeCorrector.correct("CloudCode'da aç, CloudMD dosyasına yaz, Cloud 'u", entries: inClaude).0,
                       "Claude Code'da aç, Claude.md dosyasına yaz, Claude'u")
        XCTAssertEqual(SoundAlikeCorrector.correct("Cloud Code'u kapat", entries: inClaude).0, "Claude Code'u kapat")
        // Global lines still apply in Claude.
        XCTAssertEqual(SoundAlikeCorrector.correct("vatsapı aç", entries: inClaude).0, "WhatsApp'ı aç")

        let inSafari = AppFocus.soundAlikeEntries(entries, focus: AppFocus(appName: "Safari", entries: entries))
        XCTAssertEqual(SoundAlikeCorrector.correct("cloud'a yükle", entries: inSafari).0, "cloud'a yükle")
        XCTAssertEqual(SoundAlikeCorrector.correct("cloud'a yükle", entries: AppFocus.soundAlikeEntries(entries, focus: nil)).0, "cloud'a yükle")
    }

    func testFrontAppFirstKeepsEveryApp() {
        let focus = AppFocus(appName: "Claude", entries: [])!
        XCTAssertEqual(focus.frontFirst(["Safari", "Claude", "Notes"]), ["Claude", "Safari", "Notes"])
        XCTAssertEqual(focus.prioritized(["GitHub", "claude"]), ["Claude", "GitHub"])
    }

    func testAppHeaderParsing() {
        let parsed = SoundAlikeCorrector.parse("A = a1\n@Claude\nClaude = cloud\n@\nB = b1\n")
        XCTAssertEqual(parsed.map(\.app), [nil, "Claude", nil])
    }
}
