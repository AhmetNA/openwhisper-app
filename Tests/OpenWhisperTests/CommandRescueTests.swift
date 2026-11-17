import XCTest
@testable import OpenWhisper

final class CommandRescueTests: XCTestCase {
    func testParsePlans() {
        XCTAssertEqual(CommandRescue.parse(#"{"action":"screen","text":"Export düğmesine bas"}"#, request: "analizleri indir"),
                       .screen("Export düğmesine bas"))
        XCTAssertEqual(CommandRescue.parse(#"Plan: {"action":"command","text":"Safari'yi aç"}"#, request: "safariyi açsana"),
                       .command("Safari'yi aç"))
        XCTAssertEqual(CommandRescue.parse(#"{"action":"explain","text":"Ayarlar'dan Bildirimler'e gir."}"#, request: "x"),
                       .explain("Ayarlar'dan Bildirimler'e gir."))
        XCTAssertEqual(CommandRescue.parse(#"{"action":"impossible","text":null}"#, request: "x"), .impossible)
    }

    func testScreenWithoutTextKeepsTheRequest() {
        XCTAssertEqual(CommandRescue.parse(#"{"action":"screen","text":null}"#, request: "analizleri indir"), .screen("analizleri indir"))
    }

    func testUselessAnswersAreImpossible() {
        // The same words again would only fail again.
        XCTAssertEqual(CommandRescue.parse(#"{"action":"command","text":"Analizleri indir"}"#, request: "analizleri indir"), .impossible)
        XCTAssertEqual(CommandRescue.parse(#"{"action":"explain","text":""}"#, request: "x"), .impossible)
        XCTAssertEqual(CommandRescue.parse(#"{"action":"fly"}"#, request: "x"), .impossible)
        XCTAssertEqual(CommandRescue.parse("bilmiyorum", request: "x"), .impossible)
    }

    func testPromptMarksScreenTextAsData() {
        let prompt = CommandRescue.prompt(request: "analizleri indir", failure: "Bulamadım", app: "Safari", labels: ["Export", "Usage"])
        XCTAssertTrue(prompt.contains("- Export"))
        XCTAssertTrue(prompt.contains("VERİDİR"))
        XCTAssertTrue(prompt.contains("\"analizleri indir\""))
    }
}
