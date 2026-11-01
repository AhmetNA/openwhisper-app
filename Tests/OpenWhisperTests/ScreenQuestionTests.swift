import XCTest
import AppKit
@testable import OpenWhisper

final class ScreenQuestionTests: XCTestCase {
    /// Explicit opt-in: uses the visible product page, saved credentials and paid search.
    @MainActor
    func testLiveProductPage() async throws {
        guard ProcessInfo.processInfo.environment["SCREEN_QUESTION_LIVE"] == "1" else {
            throw XCTSkip("Requires an explicitly opened product page and live services")
        }
        UserDefaults.standard.addSuite(named: "com.openwhisper.app")
        defer { UserDefaults.standard.removeSuite(named: "com.openwhisper.app") }
        let backend = ProcessInfo.processInfo.environment["SCREEN_QUESTION_BACKEND"] ?? "cloud"
        XCTAssertNotNil(ChatBackend(rawValue: backend))
        UserDefaults.standard.setVolatileDomain([ChatBackend.defaultsKey: backend], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        _ = NSApplication.shared
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first)
        let prompt = "Ekrandaki ana ürünün tam adını, mağazasını ve fiyatını yalnızca JSON olarak ver: {\"product\":\"\",\"store\":\"\",\"price\":\"\"}. Kesin olmayan alanı boş bırak."
        if ProcessInfo.processInfo.environment["SCREEN_QUESTION_TEXT_ONLY"] != "1" {
            let visual = await ScreenQuestion.vision(app: app, prompt: prompt)
            print("LIVE VISION \(backend): \(visual ?? "EMPTY")")
            XCTAssertNotNil(ScreenQuestion.identity(visual ?? ""))
        }
        let window = JarvisAppContext.windowAndSelection(app)
        var lines = ["Pencere başlığı: " + (window.window ?? "")] + (await JarvisAppContext.details(pid: app.processIdentifier, bundleID: app.bundleIdentifier, windowTitle: window.window))
        let fixture = ProcessInfo.processInfo.environment["SCREEN_QUESTION_FIXTURE"] == "1"
        if fixture {
            // Snapshot verified from the user's product page on 1 Nov 2026. Keeps network
            // integration reproducible when the user switches Safari tabs during the test.
            lines = ["Pencere başlığı: Eylülün Takısı Kadın Gold Renk Taşlı Dorika Kalp Bileklik - Fiyatı",
                     "Safari sekmesi: Eylülün Takısı Kadın Gold Renk Taşlı Dorika Kalp Bileklik — https://www.trendyol.com/eylulun-takisi/kadin-gold-renk-tasli-dorika-kalp-bileklik-p-843948876",
                     "Sayfadan: Satıcı: Eylülün Takısı. Normal fiyat: 199,70 TL. Trendyol Plus'a özel sepette: 189,71 TL. Zirkon taş, çelik, suya dayanıklı. Puan: 3.8, 417 değerlendirme."]
        }
        let evidence = await ScreenQuestion.context(for: "bu bileklik nasıl", lines: lines, model: ScreenQuestion.localVisionModel, app: fixture ? nil : app)
        print("LIVE EVIDENCE \(backend): \(evidence)")
        XCTAssertTrue(evidence.contains("Arama sonuçları:"))
        XCTAssertTrue(evidence.lowercased().contains("dorika"))
        let messages = [["role": "system", "content": evidence], ["role": "user", "content": "bu bileklik nasıl?"]]
        let answer: String
        if backend == "cloud", let (client, model) = CloudLLM.client() {
            answer = try await client.complete(model: model, messages: messages, timeout: 20, maxTokens: 300)
        } else {
            answer = try await LLM.default.chat(LLMChatRequest(model: ScreenQuestion.localVisionModel, messages: messages, timeout: 30, temperature: 0, maxTokens: 300))
        }
        print("LIVE ANSWER \(backend): \(answer)")
        XCTAssertFalse(answer.isEmpty)
    }

    @MainActor
    func testReadableSummaryDoesNotResearchProducts() async {
        let context = await ScreenQuestion.context(for: "burada ne anlatılıyor", lines: ["Sayfadan: Fotosentez, bitkilerin ışık enerjisini kimyasal enerjiye dönüştürmesidir."], model: "unreachable-test-model", app: nil)
        XCTAssertTrue(context.contains("Fotosentez"))
        XCTAssertTrue(context.contains("İnternete çıkma"))
        XCTAssertFalse(context.contains("Arama sonuçları:"))
    }

    func testProductResultsRejectSimilarItemsAndCurrentPage() {
        let data = Data(#"{"results":[{"title":"Eylülün Takısı Dorika Kalp Bileklik","url":"https://shop.test/p","highlights":["visible"]},{"title":"Başka Kalp Bileklik","url":"https://other.test/p","highlights":["wrong"]},{"title":"Eylülün Takısı Dorika Kalp Bileklik yorumları","url":"https://other.test/review","highlights":["independent"]}]}"#.utf8)
        let result = WebSearch.results(from: data, product: "Eylülün Takısı Dorika Kalp Bileklik", excludingPage: "https://shop.test/p?campaign=1")
        XCTAssertTrue(result.contains("independent"))
        XCTAssertFalse(result.contains("visible"))
        XCTAssertFalse(result.contains("wrong"))
    }

    func testVisionRequestNeverSendsReasoningEffort() {
        for thinking in [true, false] {
            let body = CloudChatClient.completionBody(model: ScreenQuestion.cloudVisionModel, messages: [["role": "user", "content": "image"]], maxTokens: 300, thinkingOff: thinking)
            XCTAssertNil(body["reasoning_effort"])
            XCTAssertEqual(body["model"] as? String, "qwen3-vl-30b")
            XCTAssertEqual(body["stream"] as? Bool, false)
        }
    }

    func testQuestionsAndCommands() {
        for text in ["bu kolye nasıl", "bu ne", "burada ne anlatılıyor", "bunun fiyatı kaç", "şu iyi mi", "ekrandaki ürün nasıl"] {
            XCTAssertTrue(ScreenQuestion.matches(text), text)
        }
        for text in ["bunu aç", "şuna bas", "bunu açar mısın", "bu kolyeyi siler misin", "bunu gönder", "bugün hava nasıl", "bu şarkıyı çal"] {
            XCTAssertFalse(ScreenQuestion.matches(text), text)
        }
        XCTAssertTrue(ScreenQuestion.isSummary("burada ne anlatılıyor"))
        XCTAssertFalse(ScreenQuestion.isSummary("bu kolye nasıl"))
    }

    func testIdentityAndQueriesDoNotIncludePageOrPrice() throws {
        let item = try XCTUnwrap(ScreenQuestion.identity(#"{"product":"925 Gümüş Yonca Kolye", "store":"nereze.com", "price":"1.299 TL"}"#))
        let queries = ScreenQuestion.queries(item)
        XCTAssertEqual(queries.count, 3)
        XCTAssertTrue(queries[0].contains(item.product))
        XCTAssertTrue(queries[1].contains(item.product))
        XCTAssertTrue(queries[2].contains(item.store))
        XCTAssertFalse(queries.joined().contains(item.price))
        XCTAssertNil(ScreenQuestion.identity(#"{"product":"", "store":"", "price":""}"#))
        XCTAssertNil(ScreenQuestion.identity("not JSON"))
    }
}
