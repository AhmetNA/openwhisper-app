import XCTest
@testable import OpenWhisper

final class SharedCommandResolverTests: XCTestCase {
    func testCalendarWriteNeedsAnExplicitCreationRequest() {
        for text in ["Toplantı yarın saat üçte", "Takvime ekleme testini düzelt", "Yarınki toplantıyı ekleme",
                     "Rapora takvime yarın toplantı ekle cümlesini yaz"] {
            XCTAssertFalse(CalendarEventParser.isCreationRequest(text), text)
        }
        for text in ["Yarın saat üçe toplantı ekle", "Takvime not düş salı öğlen yemek", "Yarına etkinlik oluşturur musun",
                     "Yeni etkinlik ekle tarih 7 Kasım'a Gaziantep uçuş gidiş geliş"] {
            XCTAssertTrue(CalendarEventParser.isCreationRequest(text), text)
        }
    }
    private func predictions(_ task: String, _ label: String, confidence: Double = 0.999) -> [String: SetFitDecider.Decision] {
        var values = [String: SetFitDecider.Decision]()
        for (key, value) in [("command_structure", "single"), ("routing_intent", "command"), (task, label)] {
            values[key] = .init(label: value, confidence: confidence, probabilities: [value: confidence], ms: 1)
        }
        return values
    }

    func testExplicitVideoRequestUsesCanonicalGuardedCommand() {
        XCTAssertEqual(SharedCommandResolver.resolve("Tamam videoyu durdurur musun?",
            decisions: predictions("video_intent", "pause"), context: .init()), .system(.video(.pause)))
    }

    func testQuotedNegatedAndTechnicalTextNeverExecutesEvenWithConfidentWrongPredictions() {
        for text in ["Videoyu durdur diye yaz", "Videoyu durdurma", "Video durdurma kodunu düzelt",
                     "Rapora videoyu durdur örneğini ekle", "Videoyu durdurmanı istemiyorum",
                     "Videoyu durdur cümlesini metne yaz"] {
            XCTAssertNil(SharedCommandResolver.resolve(text, decisions: predictions("video_intent", "pause"), context: .init()), text)
        }
    }

    func testDestructiveAndSlotDependentPredictionsAreNotSynthesized() {
        for (task, label, text) in [("system_intent", "lock", "Bilgisayarı kilitler misin"),
            ("app_action", "force_quit", "Safari'yi zorla kapatır mısın"),
            ("agent_intent", "send_existing", "Yazdığım mesajı gönder"),
            ("reminder_intent", "delete", "Hatırlatıcıyı sil"),
            ("video_intent", "seek_to", "Videoyu beşinci dakikaya al")] {
            XCTAssertNil(SharedCommandResolver.resolve(text, decisions: predictions(task, label), context: .init()), label)
        }
    }

    func testApplicationTargetMustBePresentInInstalledList() {
        let text = "Safari uygulamasını başlatır mısın"
        let values = predictions("app_action", "open")
        XCTAssertNil(SharedCommandResolver.resolve(text, decisions: values, context: .init()))
        XCTAssertEqual(SharedCommandResolver.resolve(text, decisions: values, context: .init(installedApps: ["Safari"])), .system(.openApp("Safari")))
    }

    func testLowConfidenceMultipleAndAgentDictationAreRejected() {
        XCTAssertNil(SharedCommandResolver.resolve("Videoyu durdur", decisions: predictions("video_intent", "pause", confidence: 0.97), context: .init()))
        var values = predictions("video_intent", "pause")
        values["command_structure"] = .init(label: "multiple", confidence: 1, probabilities: [:], ms: 1)
        XCTAssertNil(SharedCommandResolver.resolve("Videoyu durdur", decisions: values, context: .init()))
        values = predictions("video_intent", "pause")
        values["routing_intent"] = .init(label: "agent", confidence: 1, probabilities: [:], ms: 1)
        XCTAssertNil(SharedCommandResolver.resolve("Videoyu durdur", decisions: values, context: .init()))
    }

    func testConflictingHeadsDoNotGuessWhichActionWasIntended() {
        var values = predictions("video_intent", "pause")
        values["system_intent"] = .init(label: "mute", confidence: 1, probabilities: [:], ms: 1)
        XCTAssertNil(SharedCommandResolver.resolve("Bilgisayarın sesi ve videoyu durdur", decisions: values, context: .init()))
    }
}
