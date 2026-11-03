import XCTest
@testable import OpenWhisper

final class ScreenPointerTests: XCTestCase {
    private func tr(_ text: String) -> PointerCommand? { ScreenPointer.parse(text, english: false) }
    private func en(_ text: String) -> PointerCommand? { ScreenPointer.parse(text, english: true) }

    func testOverlayCommands() {
        XCTAssertEqual(tr("Numaraları göster."), .showNumbers)
        XCTAssertEqual(tr("Jarvis numaraları göster lütfen"), .showNumbers)
        XCTAssertEqual(tr("Izgarayı göster"), .showGrid(fullScreen: false))
        XCTAssertEqual(tr("ızgara"), .showGrid(fullScreen: false))
        XCTAssertEqual(tr("tüm ekran ızgarası"), .showGrid(fullScreen: true))
        XCTAssertEqual(tr("numaraları gizle"), .hideOverlay)
        XCTAssertEqual(tr("ızgarayı kapat"), .hideOverlay)
        XCTAssertEqual(tr("ekran modunu aç"), .open)
    }

    func testNumbersInEveryCase() {
        XCTAssertEqual(tr("Beş."), .number(5, nil))
        XCTAssertEqual(tr("5"), .number(5, nil))
        XCTAssertEqual(tr("on iki"), .number(12, nil))
        XCTAssertEqual(tr("yirmi beşe bas"), .number(25, .press))
        XCTAssertEqual(tr("5'e bas"), .number(5, .press))
        XCTAssertEqual(tr("12'ye tıkla"), .number(12, .press))
        XCTAssertEqual(tr("dörde bas"), .number(4, .press))
        XCTAssertEqual(tr("beşebas"), .number(5, .press))
        XCTAssertEqual(tr("beş numaraya bas"), .number(5, .press))
        XCTAssertEqual(tr("beşe basar mısın"), .number(5, .press))
    }

    func testMouseVerbs() {
        XCTAssertEqual(tr("beşe çift tıkla"), .number(5, .doubleClick))
        XCTAssertEqual(tr("çift tıkla beşe"), .number(5, .doubleClick))
        XCTAssertEqual(tr("on ikiye sağ tıkla"), .number(12, .rightClick))
        XCTAssertEqual(tr("beşin üstüne gel"), .number(5, .hover))
        XCTAssertEqual(tr("beşe git"), .number(5, .hover))
        XCTAssertEqual(tr("Kaydet'e sağ tıkla"), .name("kaydet", .rightClick))
        XCTAssertEqual(tr("Kaydet'in üstüne gel"), .name("kaydet", .hover))
        XCTAssertEqual(tr("sağ tıkla"), .here(.rightClick))
        XCTAssertEqual(tr("çift tıkla"), .here(.doubleClick))
        XCTAssertEqual(tr("tıkla"), .here(.press))
        XCTAssertEqual(tr("buraya tıkla"), .here(.press))
        XCTAssertEqual(tr("iki kere tıkla"), .here(.doubleClick))
    }

    func testDrag() {
        XCTAssertEqual(tr("beşi dokuza sürükle"), .dragNumbers(5, 9))
        XCTAssertEqual(tr("beşten on ikiye taşı"), .dragNumbers(5, 12))
        XCTAssertEqual(tr("5'i 9'a sürükle"), .dragNumbers(5, 9))
        XCTAssertEqual(tr("dosyayı klasöre sürükle"), .dragNames("dosyayı", "klasöre"))
        XCTAssertEqual(tr("yeni dosyayı arşiv klasörüne sürükle"), .dragNames("yeni dosyayı", "arşiv klasörüne"))
    }

    func testNudge() {
        XCTAssertEqual(tr("biraz sağa"), .nudge(dx: 30, dy: 0))
        XCTAssertEqual(tr("azıcık yukarı"), .nudge(dx: 0, dy: -10))
        XCTAssertEqual(tr("fareyi sola götür"), .nudge(dx: -60, dy: 0))
        XCTAssertEqual(tr("imleci çok aşağı"), .nudge(dx: 0, dy: 200))
        XCTAssertEqual(tr("biraz daha sağa"), .nudge(dx: 30, dy: 0))
    }

    func testOtherStepsAreLeftAlone() {
        XCTAssertNil(tr("Kaydet'e bas"))
        XCTAssertNil(tr("geri butonuna bas"))
        XCTAssertNil(tr("aşağı kaydır"))
        XCTAssertNil(tr("yukarı kaydır"))
        XCTAssertNil(tr("biraz aşağı kaydır"))
        XCTAssertNil(tr("aşağı"))
        XCTAssertNil(tr("sağa"))
        XCTAssertNil(tr("beş yaz"))
        XCTAssertNil(tr("geri git"))
        XCTAssertNil(tr("tamamdır"))
        XCTAssertNil(tr("merhaba yaz ve gönder"))
        XCTAssertNil(tr("beş dakika sonra hatırlat"))
        XCTAssertNil(tr("bugün hava nasıl"))
        XCTAssertNil(tr("Safari'yi aç"))
    }

    func testEnglish() {
        XCTAssertEqual(en("Show numbers."), .showNumbers)
        XCTAssertEqual(en("show grid"), .showGrid(fullScreen: false))
        XCTAssertEqual(en("hide grid"), .hideOverlay)
        XCTAssertEqual(en("five"), .number(5, nil))
        XCTAssertEqual(en("twenty five"), .number(25, nil))
        XCTAssertEqual(en("click 12"), .number(12, .press))
        XCTAssertEqual(en("double click seven"), .number(7, .doubleClick))
        XCTAssertEqual(en("right click Save"), .name("save", .rightClick))
        XCTAssertEqual(en("hover over Save"), .name("save", .hover))
        XCTAssertEqual(en("right click"), .here(.rightClick))
        XCTAssertEqual(en("drag 5 to 9"), .dragNumbers(5, 9))
        XCTAssertEqual(en("move left a bit"), .nudge(dx: -30, dy: 0))
        XCTAssertNil(en("click Save"))
        XCTAssertNil(en("scroll down"))
        XCTAssertNil(en("left"))
    }

    func testFinishedSteps() {
        for text in ["beş", "5", "on iki", "beşe bas", "beşebas", "beşi dokuza sürükle", "çift tıkla", "sağ tıkla", "tıkla",
                     "Kaydet'e sağ tıkla", "beşin üstüne gel", "biraz sağa", "fareyi aşağı götür", "numaraları göster", "ızgara"] {
            XCTAssertTrue(ScreenPointer.isFinished(text, english: false), text)
        }
        for text in ["five", "12", "click 12", "double click seven", "drag 5 to 9", "move left", "show grid"] {
            XCTAssertTrue(ScreenPointer.isFinished(text, english: true), text)
        }
    }

    /// The start of a longer step, with a pause in it, must not stop the mic.
    func testStartsOfStepsAreNotFinished() {
        for text in ["beşi", "beşe", "beşten", "on", "yirmi", "çok aşağı", "biraz aşağı", "Kaydet'e bas", "aşağı kaydır"] {
            XCTAssertFalse(ScreenPointer.isFinished(text, english: false), text)
        }
        for text in ["click", "right click", "right click Save", "twenty", "click twenty", "drag 5 to twenty"] {
            XCTAssertFalse(ScreenPointer.isFinished(text, english: true), text)
        }
    }

    func testOneAndTenAreNotEverydayWords() {
        XCTAssertNil(tr("ona bas"))
        XCTAssertNil(tr("yine ona bas"))
        XCTAssertEqual(tr("bir tıkla"), .here(.press))
        XCTAssertEqual(tr("şuna bir tıkla"), .here(.press))
        XCTAssertEqual(tr("on'a bas"), .number(10, .press))
        XCTAssertEqual(tr("10'a bas"), .number(10, .press))
        XCTAssertEqual(tr("bire bas"), .number(1, .press))
        XCTAssertEqual(tr("bir"), .number(1, nil))
    }

    func testGridCells() {
        let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertEqual(ScreenPointer.gridCell(1, in: rect), CGRect(x: 100, y: 50, width: 100, height: 100))
        XCTAssertEqual(ScreenPointer.gridCell(4, in: rect), CGRect(x: 400, y: 50, width: 100, height: 100))
        XCTAssertEqual(ScreenPointer.gridCell(5, in: rect), CGRect(x: 100, y: 150, width: 100, height: 100))
        XCTAssertEqual(ScreenPointer.gridCell(12, in: rect), CGRect(x: 400, y: 250, width: 100, height: 100))
        XCTAssertNil(ScreenPointer.gridCell(0, in: rect))
        XCTAssertNil(ScreenPointer.gridCell(13, in: rect))
        XCTAssertFalse(ScreenPointer.isLastGridLevel(rect))
        XCTAssertTrue(ScreenPointer.isLastGridLevel(CGRect(x: 0, y: 0, width: 40, height: 30)))
    }
}
