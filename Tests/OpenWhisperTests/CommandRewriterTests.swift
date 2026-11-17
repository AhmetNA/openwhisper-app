import XCTest
@testable import OpenWhisper

final class CommandRewriterTests: XCTestCase {
    func testLooksLikeCommand() {
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Ortalık çok karanlık, ekranı biraz aç bakalım"))
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Şu müziği bir durdurur musun"))
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Biraz sessizlik lütfen, sesi kısabilir misin?"))
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Parlaklığı kız"))
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Şarkıyı durdr"))
        XCTAssertFalse(CommandRewriter.looksLikeCommand("Kara delikler nasıl oluşur?"))
        XCTAssertFalse(CommandRewriter.looksLikeCommand("Sağ ol"))
        XCTAssertFalse(CommandRewriter.looksLikeCommand("Of course"))
        XCTAssertFalse(CommandRewriter.looksLikeCommand("Bugün hava çok güzel"))
    }

    func testRewriteOnlyRunsSafeSystemCommands() {
        let apps = ["Safari", "Spotify"]
        XCTAssertEqual(CommandRewriter.safeSystemCommand("Karanlık modu aç", installedApps: apps), .darkMode(on: true))
        XCTAssertNil(CommandRewriter.safeSystemCommand("Safari'yi kapat", installedApps: apps))
        XCTAssertNil(CommandRewriter.safeSystemCommand("Bilgisayarı uyut", installedApps: apps))
        XCTAssertNil(CommandRewriter.safeSystemCommand("YOK", installedApps: apps))
    }

    func testRewriteNeverInventsWhatToSearchOrPlay() {
        let kedi = VoiceCommand.system(.browser(.search(.google, "kedi")))
        XCTAssertTrue(CommandRewriter.inventsPayload(kedi, rewritten: "Google'da kedi ara", original: "jarvana karşı en iyi pick ne"))
        XCTAssertFalse(CommandRewriter.inventsPayload(kedi, rewritten: "Google'da kedi ara", original: "gugılda kedi ar"))
        XCTAssertTrue(CommandRewriter.inventsPayload(.spotify("Tarkan çal"), rewritten: "Tarkan çal", original: "bugün hava nasıl"))
        XCTAssertFalse(CommandRewriter.inventsPayload(.spotify("Tarkan çal"), rewritten: "Tarkan çal", original: "tarkanı çal"))
        XCTAssertFalse(CommandRewriter.inventsPayload(.spotify("Sesi artır"), rewritten: "Sesi artır", original: "sesi artr"))
        XCTAssertFalse(CommandRewriter.inventsPayload(.system(.darkMode(on: true)), rewritten: "Karanlık modu aç", original: "karanlık mod"))
    }

    func testMisheardVolumeTrustsTheModelsDirection() async {
        let up = SpotifyRequestParser.OllamaParse(intent: .volumeUp)
        let down = SpotifyRequestParser.OllamaParse(intent: .volumeDown)
        XCTAssertNotNil(SpotifyManager.decide(rules: nil, parse: up, text: "sesi artr", commandMode: true))
        XCTAssertNotNil(SpotifyManager.decide(rules: nil, parse: down, text: "sesi azlt", commandMode: true))
        XCTAssertNil(SpotifyManager.decide(rules: nil, parse: up, text: "sesi kıs", commandMode: true))
        XCTAssertNil(SpotifyManager.decide(rules: nil, parse: up, text: "bugün hava güzel", commandMode: true))
        // A rewrite to a volume command reaches the Spotify path without any model.
        let rewritten = await SpotifyManager.isSpotifyCommand("Sesi artır", commandMode: true)
        XCTAssertTrue(rewritten)
    }

    func testClaudeLikeWordsGoToTheModelAndItsExamplesRoute() {
        for text in ["claude da en son ne görüştük", "Cloud'da son sohbet", "klod a geç", "clad ne yaptı", "Klaude'daki işi özetle"] {
            XCTAssertTrue(CommandRewriter.mentionsClaude(text), text)
        }
        for text in ["iCloud yedeği", "bugün hava güzel", "kalorifer"] {
            XCTAssertFalse(CommandRewriter.mentionsClaude(text), text)
        }
        // The prompt's Claude examples must be ones the rules know.
        XCTAssertEqual(AgentCommandParser.sessionSummaryTarget("Claude'da son sohbeti özetle"), .claudeCode)
        XCTAssertEqual(AgentCommandParser.sessionSummaryTarget("Codex'te son sohbeti özetle"), .codex)
        XCTAssertNotNil(AgentCommandParser.finishedChatRequest("Biten sohbete geç"))
        XCTAssertTrue(CloudSessionNavigation.isRequest("Claude'da vergi sohbetine geç"))
        XCTAssertTrue(CloudSessionNavigation.isRequest("Claude'da yeni sohbet aç"))
    }
}

