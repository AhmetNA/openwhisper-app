import ApplicationServices
import XCTest
@testable import OpenWhisper

final class ScreenTaskTests: XCTestCase {
    private func element(_ label: String, role: String = "AXButton", isOn: Bool? = nil) -> ScreenElement {
        ScreenElement(element: AXUIElementCreateSystemWide(), role: role, label: label,
                      region: "orta", inDialog: false, isOn: isOn)
    }

    func testGoalsGoToTheLoop() {
        XCTAssertTrue(ScreenTask.isGoal("Ayarlar'da bildirimleri kapat"))
        XCTAssertTrue(ScreenTask.isGoal("arama kutusuna kedi videoları yaz"))
        XCTAssertTrue(ScreenTask.isGoal("bildirim ayarlarında sesi kapat lütfen"))
        XCTAssertTrue(ScreenTask.isGoal("analizleri indir"))
        XCTAssertTrue(ScreenTask.isGoal("kullanım raporunu indir lütfen"))
    }

    func testNamesStayOnTheSinglePress() {
        XCTAssertFalse(ScreenTask.isGoal("Kaydet'e bas"))
        XCTAssertFalse(ScreenTask.isGoal("sağ üstteki çarpıya bas"))
        XCTAssertFalse(ScreenTask.isGoal("izin ver"))
        XCTAssertFalse(ScreenTask.isGoal("indir"))
        // The splitter's: two system commands, not a screen goal.
        XCTAssertFalse(ScreenTask.isGoal("sesi kıs ve Bluetooth'u kapat"))
        // Writing needs a field to write into.
        XCTAssertFalse(ScreenTask.isGoal("bana bir mail yaz"))
    }

    func testParseStep() {
        XCTAssertEqual(ScreenTask.parseStep(#"{"action":"press","index":2,"text":null}"#, count: 3), .press(1))
        XCTAssertEqual(ScreenTask.parseStep(#"Tamam: {"action":"type","index":1,"text":"kedi"}"#, count: 3), .type(0, "kedi"))
        XCTAssertEqual(ScreenTask.parseStep(#"{"action":"done","index":null,"text":null}"#, count: 3), .done)
        XCTAssertEqual(ScreenTask.parseStep(#"{"action":"fail"}"#, count: 3), .fail)
        XCTAssertNil(ScreenTask.parseStep(#"{"action":"press","index":4}"#, count: 3))
        XCTAssertNil(ScreenTask.parseStep(#"{"action":"type","index":1,"text":"  "}"#, count: 3))
        XCTAssertNil(ScreenTask.parseStep(#"{"action":"scroll","index":1}"#, count: 3))
        XCTAssertNil(ScreenTask.parseStep("3", count: 3))
    }

    func testParseVision() {
        XCTAssertEqual(ScreenTask.parseVision(#"{"action":"click","bbox_2d":[100,200,300,400]}"#), .click(CGPoint(x: 200, y: 300)))
        XCTAssertEqual(ScreenTask.parseVision(#"{"action":"done"}"#), .done)
        XCTAssertEqual(ScreenTask.parseVision("NONE"), .none)
        XCTAssertEqual(ScreenTask.parseVision("bilmiyorum"), .none)
    }

    func testOnlySaidTextIsTyped() {
        XCTAssertTrue(ScreenTask.isSaid("kedi videoları", in: "arama kutusuna kedi videoları yaz"))
        XCTAssertTrue(ScreenTask.isSaid("Kedi Videoları", in: "arama kutusuna kedi videoları yaz"))
        XCTAssertFalse(ScreenTask.isSaid("köpek videoları", in: "arama kutusuna kedi videoları yaz"))
        XCTAssertFalse(ScreenTask.isSaid("", in: "arama kutusuna kedi videoları yaz"))
    }

    func testPromptShowsSwitchStates() {
        let prompt = ScreenTask.prompt(goal: "bildirimleri kapat", app: "Ayarlar", history: [],
                                       elements: [element("Bildirimler", role: "AXCheckBox", isOn: true), element("Tamam")])
        XCTAssertTrue(prompt.contains("1. onay kutusu \"Bildirimler\" (orta, açık)"))
        XCTAssertTrue(prompt.contains("2. düğme \"Tamam\" (orta)"))
        XCTAssertTrue(prompt.contains("Henüz bir şey yapmadın."))
    }

    func testTurningASwitchCountsAsAChange() {
        let before = ScreenTask.fingerprint([element("Bildirimler", role: "AXCheckBox", isOn: true), element("Tamam")])
        let after = ScreenTask.fingerprint([element("Bildirimler", role: "AXCheckBox", isOn: false), element("Tamam")])
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before, ScreenTask.fingerprint([element("Bildirimler", role: "AXCheckBox", isOn: true), element("Tamam")]))
    }
}
