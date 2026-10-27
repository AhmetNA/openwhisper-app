import XCTest
import JavaScriptCore
@testable import OpenWhisper

final class YouTubeListTests: XCTestCase {
    func testHomeCommands() {
        for text in ["YouTube'u aç", "Hey Jarvis, YouTube'da ne var?", "YouTube önerilerini oku", "YouTube'a gir",
                     "YouTube'da bugün ne var?", "Bugün YouTube'da ne var?", "YouTube da bu gün neler var",
                     "YouTube'da bugün hangi videolar var", "YouTube'daki videoları oku",
                     "YouTube'da ne izleyeyim", "YouTube'da şimdi neler öneriliyor",
                     "Youtube'da neler var", "YouTube ana sayfasını aç"] {
            XCTAssertEqual(SystemCommandParser.parse(text), .browser(.youtubeHome), text)
        }
        XCTAssertEqual(SystemCommandParser.parse("YouTube sitesini aç"), .browser(.open("https://youtube.com")))
        XCTAssertEqual(SystemCommandParser.parse("lofi'yi YouTube'da aç"), .browser(.youtubeTitle("lofi")))
        XCTAssertEqual(SystemCommandParser.parse("Başka önerileri oku"), .browser(.youtubeMore))
    }

    @MainActor
    func testYouTubeRoutingWithoutSafari() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                      focus: .notEditable, hasTargetApp: true,
                                      targetBundleID: "com.apple.finder")
        for text in ["YouTube'da bugün ne var?", "Bugün YouTube'da ne var?", "Yutup da bugün ne var"] {
            guard case .command(.system(.browser(.youtubeHome))) = VoiceRouter.route(text, facts: facts) else {
                return XCTFail("Wrong route: \(text)")
            }
        }
        XCTAssertEqual(SystemCommandParser.parse("videoyu durdur"), .video(.pause))
        XCTAssertEqual(SystemCommandParser.parse("YouTube'u durdur"), .video(.pause))
        XCTAssertEqual(SystemCommandParser.parse("YouTube'a devam et"), .video(.play))
        XCTAssertEqual(SystemCommandParser.parse("Bugün ne var"), .briefing(dayOffset: 0))
        XCTAssertNil(SystemCommandParser.parseMac("YouTube'da bugün ne var"))
        XCTAssertNil(SystemCommandParser.parse("YouTube'da bugün ne var diye sordum"))
    }

    func testMissingYouTubeVideoReply() {
        var reply = JarvisReply()
        reply.addressChance = 0
        XCTAssertEqual(reply.system(.video(.play), status: BrowserController.youTubeNeedsVideo),
                       BrowserController.youTubeNeedsVideo + ".")
        XCTAssertTrue(VideoController.failures.contains(BrowserController.youTubeNeedsVideo))
    }

    func testTitleCommandsAndSearchRemainDistinct() {
        for text in ["Çernobil videosunu aç", "Sağdaki çernobil videosunu aç", "YouTube'da çernobil videosunu aç",
                     "Çernobil başlıklı videoyu aç", "Çernobil adlı videoyu oynat", "YouTube'da çernobil aç"] {
            XCTAssertEqual(SystemCommandParser.parse(text), .browser(.youtubeTitle("çernobil")), text)
        }
        XCTAssertEqual(SystemCommandParser.parse("YouTube'da çernobil ara"), .browser(.search(.youtube, "çernobil")))
        XCTAssertEqual(SystemCommandParser.parse("videoyu başa sar"), .video(.restart))
        XCTAssertEqual(CommandFollowUp.domain(of: .system(.browser(.youtubeTitle("çernobil")))), .video)
    }

    func testPartialAndMisheardTitleRanking() {
        let videos: [YouTubeList.Video] = [
            .init(id: "a", title: "Uzayda Bir Gün"),
            .init(id: "b", title: "ÇERNOBİL: Felaketin Ardındaki Gerçekler"),
            .init(id: "c", title: "Çernobil Gezisi ve Terk Edilmiş Şehir")
        ]
        XCTAssertEqual(YouTubeList.bestMatch("çernobil", in: videos)?.id, "b")
        XCTAssertEqual(YouTubeList.bestMatch("cernobıl gezisi", in: videos)?.id, "c")
        XCTAssertEqual(YouTubeList.bestMatch("çernobıl felaket", in: videos)?.id, "b")
        XCTAssertEqual(YouTubeList.bestMatch("çernobil", in: [.init(id: "x", title: "Chernobyl Documentary")])?.id, "x")
        XCTAssertNil(YouTubeList.bestMatch("makarna tarifi", in: videos))
        XCTAssertNil(YouTubeList.bestMatch("", in: videos))
    }

    func testLivePageIncludesVisibleSidebarAndSkipsOffscreen() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var location={hostname:'www.youtube.com',pathname:'/watch'};
            var innerWidth=1200,innerHeight=800;
            function link(id,title,top,ad){return {
                href:'https://www.youtube.com/watch?v='+id,
                getBoundingClientRect:function(){return {width:200,height:40,top:top,bottom:top+40,left:900,right:1100}},
                closest:function(){return ad?{}:null},querySelector:function(){return null},
                getAttribute:function(){return title},textContent:title
            }}
            var document={querySelectorAll:function(){return [
                link('ad','Çernobil reklam',20,true),link('sidebar','Çernobil Belgeseli',100,false),
                link('offscreen','Çernobil Diğer',1100,false)]}};
            function URL(raw){this.pathname='/watch';this.searchParams={get:function(k){return k==='v'?raw.split('v=')[1]:null}}}
            """)
        let result = context.evaluateScript(YouTubeList.readJavaScript(path: nil, visibleOnly: true))?.toString()
        XCTAssertNil(context.exception)
        XCTAssertEqual(YouTubeList.decode(result ?? "").map(\.id), ["sidebar"])
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
