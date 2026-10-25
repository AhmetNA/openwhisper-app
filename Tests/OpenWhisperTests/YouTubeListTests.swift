import XCTest
@testable import OpenWhisper

final class YouTubeListTests: XCTestCase {
    @MainActor func testRecentConversationRequestsRunAsCommands() {
        for text in ["Youtube'da ne vardı?", "YouTube'da neler var arat", "YouTube'da ne olduğunu arat",
                     "YouTube'da neler var?", "YouTube'da neler vardı bir bak"] {
            let route = VoiceRouter.route(text, facts: .init(isVoiceCommand: true, acceptsCommands: true,
                                                           focus: .notEditable, hasTargetApp: true))
            guard case .command(.system(.browser(.youtubeHome))) = route else {
                XCTFail("Expected an executable YouTube request: \(text)"); continue
            }
        }
        XCTAssertNil(YouTubeVoice.explicit("YouTube'da neler var diye sorarsam ne yaparsın?"))
        XCTAssertNil(YouTubeVoice.explicit("YouTube önerilerini okuyabiliyor musun?"))
        XCTAssertNil(YouTubeVoice.explicit("YouTube'da neler var aratma"))
        XCTAssertEqual(SystemCommandParser.parse("YouTube'da uzay arat"), .browser(.search(.youtube, "uzay")))
    }

    func testRecentConversationConfirmationExecutesOnce() {
        let now = Date()
        for yes in ["Evet", "Evet, ben istedim.", "Evet, bunu yapman istiyor.", "Evet, bunu yapmanı istiyorum."] {
            var pending = YouTubeVoice.PendingRequest()
            pending.remember(user: "Youtube'dan yang aldı", reply: "Sir, YouTube'dan yang araması yapıp sonuçları okumamı mı istiyorsunuz?", now: now)
            XCTAssertEqual(pending.take(for: yes, now: now.addingTimeInterval(15)), .search(.youtube, "yang"), yes)
            XCTAssertNil(pending.take(for: yes, now: now.addingTimeInterval(20)))
        }
    }

    func testYouTubeConfirmationExpiryCancellationAndNoInventedQuery() {
        let now = Date()
        let question = "Sir, YouTube'dan yang araması yapıp sonuçları okumamı mı istiyorsunuz?"
        for answer in ["Hayır", "Evet ama yapma", "Spotify'ı aç", "Evet bunu dün söyledim"] {
            var pending = YouTubeVoice.PendingRequest()
            pending.remember(user: "Youtube'dan yang aldı", reply: question, now: now)
            XCTAssertNil(pending.take(for: answer, now: now))
            XCTAssertNil(pending.take(for: "evet", now: now))
        }
        var pending = YouTubeVoice.PendingRequest()
        pending.remember(user: "Youtube'dan yang aldı", reply: question, now: now)
        XCTAssertNil(pending.take(for: "evet", now: now.addingTimeInterval(121)))
        pending.remember(user: "YouTube'da ne vardı", reply: question, now: now)
        XCTAssertNil(pending.take(for: "evet", now: now))
        pending.remember(user: "YouTube'da ne vardı", reply: "YouTube'da ne olduğunu aratmamı mı istiyorsunuz?", now: now)
        XCTAssertEqual(pending.take(for: "evet", now: now), .youtubeHome)
    }

    func testScreenCommandsAndTitles() {
        for text in ["YouTube'a geri dön", "YouTube ana sayfasına git", "YouTube'da ne izleyebilirim", "YouTube'a bakalım"] {
            XCTAssertEqual(SystemCommandParser.parse(text), .browser(.youtubeHome), text)
        }
        XCTAssertEqual(SystemCommandParser.parse("Önceki videoya dön"), .video(.previous))
        XCTAssertEqual(SystemCommandParser.parse("Sonraki video"), .video(.next))
        XCTAssertEqual(SystemCommandParser.parse("Sonraki önerileri oku"), .browser(.youtubeMore))
        XCTAssertEqual(YouTubeVoice.navigation("Ana sayfaya dön"), .system(.browser(.youtubeHome)))
        XCTAssertEqual(YouTubeVoice.navigation("sonrakini aç"), .system(.video(.next)))
        XCTAssertNil(YouTubeVoice.navigation("Safari'yi kapat"))
        let videos = [YouTubeList.Video(id: "a", title: "Uzay Yolculuğu — Mars"),
                      YouTubeList.Video(id: "b", title: "Uzay Yolculuğu — Ay"),
                      YouTubeList.Video(id: "c", title: "İstanbul Gezisi")]
        XCTAssertEqual(YouTubeVoice.matches("İstanbul Gezisi aç", in: videos).map(\.id), ["c"])
        XCTAssertEqual(YouTubeVoice.matches("Uzay Mars", in: videos).map(\.id), ["a"])
        XCTAssertEqual(YouTubeVoice.matches("Uzay Yolculuğu", in: videos).count, 2)
        XCTAssertTrue(YouTubeVoice.matches("Mars", in: videos).isEmpty)
        XCTAssertTrue(YouTubeVoice.matches("Wi-Fi aç", in: videos).isEmpty)
        XCTAssertEqual(YouTubeVoice.matches("İstanbul Gezisi", in: videos).map(\.id), ["c"])
    }

    func testNaturalTopicOpeningRequest() {
        let videos = [YouTubeList.Video(id: "a", title: "35 Buçuk — Yeni Bölüm"),
                      YouTubeList.Video(id: "b", title: "Mars Yolculuğu")]
        for text in ["35 buçukla ilgili olan bir video var onu açabilir misin?",
                     "İşte 35 buçuk ile ilgili bir video var, onu açar mısın?",
                     "35 buçuk açabilir misin?"] {
            XCTAssertEqual(YouTubeVoice.matches(text, in: videos).map(\.id), ["a"], text)
        }
        for text in ["35 buçukla ilgili bir video var onu açma",
                     "35 buçukla ilgili bir video var onu açabilir misin diye sordum"] {
            XCTAssertTrue(YouTubeVoice.matches(text, in: videos).isEmpty, text)
        }
        let duplicate = videos + [YouTubeList.Video(id: "c", title: "35 Buçuk Başka Bölüm")]
        XCTAssertEqual(YouTubeVoice.matches("35 buçukla ilgili bir video var onu açabilir misin", in: duplicate).count, 2)
    }

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
        XCTAssertEqual(try compile(YouTubeVoice.visibleScript), "")
        XCTAssertEqual(try compile(YouTubeList.readScript(path: "/results")), "")
        XCTAssertEqual(try compile(YouTubeList.replaceTabScript("https://www.youtube.com/watch?v=x")), "")
    }

}
