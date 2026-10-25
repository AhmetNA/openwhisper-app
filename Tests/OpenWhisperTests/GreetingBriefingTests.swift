import XCTest
@testable import OpenWhisper

final class GreetingBriefingTests: XCTestCase {
    func testNaturalGreetingWithoutSwallowingCommands() {
        for text in ["Hey Jarvis selam naber", "Selam, ne haber?", "Merhaba naber?"] {
            XCTAssertEqual(JarvisReply.greeting(in: text), .howAreYou, text)
        }
        XCTAssertNil(JarvisReply.greeting(in: "Selam naber müziği aç"))
        XCTAssertNil(JarvisReply.greeting(in: "Selam naber yaz"))
    }

    func testExpandedGreetingsAndRecentWorkCheckIns() {
        let examples: [(String, JarvisReply.Greeting)] = [
            ("Günaydın Carviz", .goodMorning),
            ("Günaydın Jervis.", .goodMorning),
            ("Caresim selamlar.", .hello),
            ("Sıra Jarvis sonuçları özetle.", .howAreYou),
            ("Ne haber. Nasılsın.", .howAreYou),
            ("Jarvis’im selamlar", .hello),
            ("Carvizim, selamlar!", .hello),
            ("Jarvis'im, selam", .hello),
            ("Ne haber, nasılsın?", .howAreYou),
            ("Günaydın Jarvis, ne haber nasıl gidiyor?", .howAreYou),
            ("Selamlar, ne var ne yok?", .howAreYou),
            ("Carviz ne yaptık ya son işleri", .howAreYou),
            ("Jarvis, en son neler yaptık?", .howAreYou),
            ("Jarvis, nerede kalmıştık?", .howAreYou),
            ("Son işleri özetle", .howAreYou)
        ]
        for (text, greeting) in examples {
            XCTAssertEqual(JarvisReply.greeting(in: text), greeting, text)
        }
    }

    func testExpandedGreetingsLeaveOtherRequestsAlone() {
        for text in ["Günaydın Carviz müziği aç", "Jarvis’im selamlar bunu yaz",
                     "Son işleri sil", "En son neler yaptık bunu Ali’ye gönder",
                     "Günaydın toplantıyı hatırlat", "Jarvis", "Bu projede ne yaptık"] {
            XCTAssertNil(JarvisReply.greeting(in: text), text)
        }
    }

    func testObservedWhisperCheckIns() {
        for text in ["Bu servis nerede kalmıştık?", "Tecaviz nerede kalmıştık?",
                     "Ticavisi nerede kalmıştık?", "Ne cariz? Nerede kalmıştık?",
                     "Günaydın Jarvis.", "Tecaviz sonuçları özetle."] {
            XCTAssertNotNil(JarvisReply.greeting(in: text), text)
            XCTAssertTrue(JarvisReply.isAddressedGreeting(in: text), text)
        }
        for text in ["Bu servis nerede çalışıyor?", "Tecaviz sonuçları sil",
                     "Ne cariz? Nerede kalmıştık bunu yaz", "Sonuçları özetle",
                     "Jarvis sonuçları özetle ve müziği aç"] {
            XCTAssertNil(JarvisReply.greeting(in: text), text)
            XCTAssertFalse(JarvisReply.isAddressedGreeting(in: text), text)
        }
    }

    func testWeatherIsCurrentAndDistinguishesNight() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clearNight = Data(#"{"current":{"time":1700000000,"temperature_2m":14.6,"weather_code":0,"is_day":0}}"#.utf8)
        XCTAssertEqual(GreetingBriefing.weatherLine(from: clearNight, now: now), "İstanbul'da şu an hava açık, 15 derece.")
        XCTAssertNil(GreetingBriefing.weatherLine(from: clearNight, now: now.addingTimeInterval(7200)))
        XCTAssertEqual(GreetingBriefing.weatherDescription(code: 0, isDay: true), "güneşli")
        XCTAssertEqual(GreetingBriefing.weatherDescription(code: 63, isDay: true), "yağmurlu")
        XCTAssertNil(GreetingBriefing.weatherDescription(code: 999, isDay: true))
        XCTAssertNil(GreetingBriefing.weatherLine(from: Data("{}".utf8), now: now))
    }

    func testProjectFallbackNamesProjectAndDatesItsActivity() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15))!
        let today = GreetingBriefing.Work(project: "OpenWhisper", title: "Ses yönlendirmesini düzeltme", excerpt: "", activity: now)
        XCTAssertEqual(GreetingBriefing.workLine(today, now: now), "Bugün OpenWhisper projesinde Ses yönlendirmesini düzeltme üzerinde çalışıyorduk.")
        let old = GreetingBriefing.Work(project: "Roomly", title: "Test dağıtımı", excerpt: "", activity: now.addingTimeInterval(-86400 * 7))
        XCTAssertTrue(GreetingBriefing.workLine(old, now: now).hasPrefix("En son Roomly"))
    }

    func testUnavailableSessionDoesNotInventWork() async {
        let text = await GreetingBriefing.summary(nil, model: "", ollamaAvailable: false)
        XCTAssertEqual(text, "Son proje oturumuna erişemedim.")
    }
}

@MainActor
final class GreetingWakeRoutingTests: XCTestCase {
    func testExpandedCheckInsReachBriefingAfterWake() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                      focus: .editable, hasTargetApp: true, greetingAfterWake: true)
        for text in ["Günaydın Carviz", "Jarvis’im selamlar", "Ne haber nasılsın",
                     "Carviz ne yaptık ya son işleri", "Jarvis en son neler yaptık",
                     "Son işleri özetle", "Günaydın Jervis.", "Caresim selamlar.",
                     "Sıra Jarvis sonuçları özetle.", "Ne haber. Nasılsın.", "Ne haber nasılsın?"] {
            guard case .greeting = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Expected greeting briefing: \(text)")
                continue
            }
        }
    }

    func testExpandedCheckInStaysDictationInEditorWithoutWake() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                      focus: .editable, hasTargetApp: true)
        if case .greeting = VoiceRouter.route("Selamlar ne haber nasılsın", facts: facts) {
            XCTFail("A greeting dictated into an editor should stay dictation")
        }
    }

    func testObservedWhisperCheckInsInWakeAndFollowUp() {
        for afterWake in [true, false] {
            let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                          focus: .editable, hasTargetApp: true,
                                          targetBundleID: "com.openai.codex", greetingAfterWake: afterWake)
            for text in ["Bu servis nerede kalmıştık?", "Tecaviz nerede kalmıştık?",
                         "Ticavisi nerede kalmıştık?", "Ne cariz? Nerede kalmıştık?",
                         "Günaydın Jarvis.", "Tecaviz sonuçları özetle."] {
                guard case .greeting = VoiceRouter.route(text, facts: facts) else {
                    XCTFail("Expected briefing (wake=\(afterWake)): \(text)")
                    continue
                }
            }
        }
    }

    func testExplicitDictationStillWinsOverRecoveredGreeting() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                      focus: .editable, hasTargetApp: true, greetingAfterWake: true)
        for text in ["Buraya yaz Tecaviz nerede kalmıştık?", "Günaydın Jarvis bunu yaz"] {
            guard case .typed = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Expected explicit dictation: \(text)")
                continue
            }
        }
        let dictation = VoiceRouter.Facts(isVoiceCommand: false, acceptsCommands: true,
                                          focus: .editable, hasTargetApp: true)
        if case .greeting = VoiceRouter.route("Günaydın Jarvis.", facts: dictation) {
            XCTFail("Dictation keys must continue typing addressed greetings")
        }
    }

    func testWakeGreetingWorksWithFocusedComposer() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                      focus: .editable, hasTargetApp: true, greetingAfterWake: true)
        guard case .greeting(.howAreYou) = VoiceRouter.route("Selam naber", facts: facts) else {
            return XCTFail("An explicit wake greeting must be answered even over an editor")
        }
    }
}
