import XCTest
@testable import OpenWhisper

final class YouTubeListTests: XCTestCase {
    func testHomeCommands() {
        for text in ["YouTube'u aç", "Hey Jarvis, YouTube'da ne var?", "YouTube önerilerini oku", "YouTube'a gir",
                     "Youtube'da neler var", "YouTube ana sayfasını aç"] {
            XCTAssertEqual(SystemCommandParser.parse(text), .browser(.youtubeHome), text)
        }
        XCTAssertEqual(SystemCommandParser.parse("YouTube sitesini aç"), .browser(.open("https://youtube.com")))
        XCTAssertEqual(SystemCommandParser.parse("lofi'yi YouTube'da aç"), .browser(.search(.youtube, "lofi")))
        XCTAssertEqual(SystemCommandParser.parse("Başka önerileri oku"), .browser(.youtubeMore))
    }

    func testPickCommands() {
        XCTAssertEqual(SystemCommandParser.parse("İkinciyi aç"), .browser(.youtubePick(2)))
        XCTAssertEqual(SystemCommandParser.parse("Jarvis, ilk videoyu oynat."), .browser(.youtubePick(1)))
        XCTAssertEqual(SystemCommandParser.parse("2. videoyu aç"), .browser(.youtubePick(2)))
        XCTAssertEqual(SystemCommandParser.parse("Sonuncuyu aç"), .browser(.youtubePick(0)))
        XCTAssertEqual(SystemCommandParser.parse("Üçüncü öneriyi açar mısın"), .browser(.youtubePick(3)))
        XCTAssertNotEqual(SystemCommandParser.parse("İkinci sekmeyi aç"), .browser(.youtubePick(2)))
        XCTAssertNil(YouTubeList.pick(in: "ikinci şarkıyı çal", requireVerb: true))
        XCTAssertNil(YouTubeList.pick(in: "ikincisi", requireVerb: true))
    }

    func testFollowUpAfterList() {
        let list = CommandFollowUp.Domain.youtubeList
        XCTAssertEqual(CommandFollowUp.resolve("İkincisi", after: list), .system(.browser(.youtubePick(2))))
        XCTAssertEqual(CommandFollowUp.resolve("Onu aç", after: list), .system(.browser(.youtubePick(1))))
        XCTAssertEqual(CommandFollowUp.resolve("aç", after: list), .system(.browser(.youtubePick(1))))
        XCTAssertEqual(CommandFollowUp.resolve("Başka", after: list), .system(.browser(.youtubeMore)))
        XCTAssertEqual(CommandFollowUp.resolve("diğerlerini oku", after: list), .system(.browser(.youtubeMore)))
        XCTAssertNil(CommandFollowUp.resolve("bugün hava nasıl", after: list))
        XCTAssertEqual(CommandFollowUp.domain(of: .system(.browser(.youtubeHome))), .youtubeList)
        XCTAssertEqual(CommandFollowUp.domain(of: .system(.browser(.search(.youtube, "lofi")))), .youtubeList)
        XCTAssertNil(CommandFollowUp.domain(of: .system(.browser(.search(.google, "lofi")))))
        XCTAssertEqual(CommandFollowUp.domain(of: .system(.browser(.youtubePick(2)))), .video)
    }

    func testShortTitle() {
        XCTAssertEqual(YouTubeList.shortTitle("🔥 Sezen Aksu - Gidiyorum (Official Video) | 4K #pop"), "Sezen Aksu - Gidiyorum")
        XCTAssertEqual(YouTubeList.shortTitle("Evde Kolay Ekmek Nasıl Yapılır - Tarif | Mutfak"), "Evde Kolay Ekmek Nasıl Yapılır")
        XCTAssertEqual(YouTubeList.shortTitle("BU VİDEOYU İZLEMEDEN UYUMA!!"), "Bu videoyu izlemeden uyuma")
        XCTAssertEqual(YouTubeList.shortTitle("bir iki üç dört beş altı yedi sekiz dokuz on"), "bir iki üç dört beş altı yedi sekiz")
        XCTAssertEqual(YouTubeList.shortTitle("(Canlı) Maç Özeti"), "(Canlı) Maç Özeti")
    }

    func testListingAndDecode() {
        let videos = YouTubeList.decode(#"[{"id":"a","title":"  Lofi\n radio  "},{"id":"b","title":"12:34"},{"id":"c","title":"Kahve"},{"id":"d","title":"Dört"},{"id":"e","title":"Beş"}]"#)
        XCTAssertEqual(videos.map(\.id), ["a", "c", "d", "e"])
        XCTAssertEqual(YouTubeList.listing(videos, from: 0), "Bir: Lofi radio. İki: Kahve. Üç: Dört.")
        XCTAssertEqual(YouTubeList.listing(videos, from: 3), "Dört: Beş.")
        XCTAssertTrue(YouTubeList.isListing("Bir: Lofi radio."))
        XCTAssertFalse(YouTubeList.isListing("YouTube'da aranıyor: lofi"))
        XCTAssertEqual(YouTubeList.decode("jsoff"), [])
    }
}

extension VideoScriptCompileTests {
    func testYouTubeScriptsCompile() throws {
        XCTAssertEqual(try compile(YouTubeList.readScript(path: "/results")), "")
        XCTAssertEqual(try compile(YouTubeList.replaceTabScript("https://www.youtube.com/watch?v=x")), "")
    }

}
