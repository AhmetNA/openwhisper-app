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
        let question = ProcessInfo.processInfo.environment["SCREEN_QUESTION_TEXT"] ?? "bu bileklik nasıl"
        let prepared = await ScreenQuestion.prepare(for: question, lines: lines, model: ScreenQuestion.localVisionModel, app: fixture ? nil : app)
        let evidence = prepared.prompt
        print("LIVE EVIDENCE \(backend): \(evidence)")
        XCTAssertTrue(evidence.contains("Arama sonuçları:"))
        XCTAssertTrue(evidence.lowercased().contains("dorika"))
        let messages = [["role": "system", "content": evidence], ["role": "user", "content": question]]
        let answer: String
        if let direct = prepared.answer {
            answer = direct
        } else if backend == "cloud", let (client, model) = CloudLLM.client() {
            answer = try await client.complete(model: model, messages: messages, timeout: 20, maxTokens: 300)
        } else {
            answer = try await LLM.default.chat(LLMChatRequest(model: ScreenQuestion.localVisionModel, messages: messages, timeout: 30, temperature: 0, maxTokens: 300))
        }
        print("LIVE ANSWER \(backend): \(answer)")
        XCTAssertFalse(answer.isEmpty)
    }

    @MainActor
    func testLivePhilipsPriceRegression() async throws {
        guard ProcessInfo.processInfo.environment["SCREEN_PHILIPS_LIVE"] == "1" else { throw XCTSkip("Live Exa/Ollama regression") }
        UserDefaults.standard.addSuite(named: "com.openwhisper.app")
        defer { UserDefaults.standard.removeSuite(named: "com.openwhisper.app") }
        UserDefaults.standard.setVolatileDomain([ChatBackend.defaultsKey: "ollama"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        let lines = ["Pencere başlığı: Philips 5500 Serisi LatteGo Tam Otomatik Espresso Makinesi Fiyatı",
                     "Safari sekmesi: Philips 5500 Serisi LatteGo Tam Otomatik Espresso Makinesi — https://www.hepsiburada.com/philips-5500-serisi-lattego-tam-otomatik-espresso-makinesi-20-sicak-ve-soguk-icecek-renkli-dokunmatik-ekran-ep5543-80-p-HBCV0000670A50",
                     "Sayfadan: Philips 5500 Serisi LatteGo Tam Otomatik Espresso Makinesi 20 Sıcak ve Soğuk İçecek, Renkli Dokunmatik Ekran, EP5543/80. Satıcı: Ayağıma Getir."]
        let prepared = await ScreenQuestion.prepare(for: "bu ürün daha ucuza satılıyor mu", lines: lines, model: ScreenQuestion.localVisionModel, app: nil)
        print("PHILIPS EVIDENCE: \(prepared.prompt)")
        print("PHILIPS ANSWER: \(prepared.answer ?? "nil")")
        XCTAssertTrue(prepared.prompt.contains("akakce.com/"))
        XCTAssertNotNil(prepared.answer)
        XCTAssertFalse(prepared.answer?.contains("bulamadım") ?? true)
        XCTAssertTrue(prepared.answer?.contains("TL") ?? false)
    }

    func testModelIdentityIgnoresMarketingButPreservesVariant() {
        let merchant = "Philips 5500 Serisi LatteGo Tam Otomatik Espresso Makinesi 20 Sıcak ve Soğuk İçecek Renkli Dokunmatik Ekran EP5543/80"
        XCTAssertEqual(ProductMatch.searchName(merchant), "Philips EP5543/80")
        for title in ["Philips EP5543/80 5500 LatteGo Kahve Makinesi", "Philips 5500 Serisi LatteGo EP5543-80 Tam Otomatik Espresso Makinesi"] {
            XCTAssertTrue(ProductMatch.matches(product: merchant, title: title))
        }
        XCTAssertFalse(ProductMatch.matches(product: merchant, title: "Philips EP5543/90 LatteGo"))
        XCTAssertFalse(ProductMatch.matches(product: merchant, title: "Philips EP5544/80 LatteGo"))
        XCTAssertFalse(ProductMatch.matches(product: merchant, title: "Philips Kahve Makineleri"))
        XCTAssertEqual(ProductMatch.primaryPageModel(in: ["Safari sekmesi: Philips — https://www.hepsiburada.com/philips-ep5543-80-p-HBCV0000670A50?tracking=AB123456"]), "ep5543-80")
    }

    func testIntentDistinguishesDescriptionFromPrice() {
        for question in ["bu ürün ne", "bu ne", "bu ürün ne işe yarıyor", "bunun amacı nedir"] {
            XCTAssertTrue(ScreenQuestion.matches(question), question)
            XCTAssertEqual(ScreenQuestion.intent(question), .describe, question)
        }
        for question in ["bu ürün başka bir yerde daha ucuza var mı", "bunun en ucuzu nerede", "bu ürün ne kadar", "bu ürünün fiyatı kaç"] {
            XCTAssertTrue(ScreenQuestion.matches(question), question)
            XCTAssertEqual(ScreenQuestion.intent(question), .price, question)
        }
        XCTAssertEqual(ScreenQuestion.intent("bu bileklik nasıl"), .review)
        XCTAssertEqual(ScreenQuestion.intent("burada ne anlatılıyor"), .summary)
    }

    @MainActor
    func testDescriptionDoesNotRequireProductModelOrSearch() async {
        let result = await ScreenQuestion.context(for: "bu ürün ne", lines: ["Sayfadan: Dorika Kalp Bileklik, bileğe takılan aksesuar."], model: "unreachable-test-model", app: nil)
        XCTAssertTrue(result.contains("ne işe yaradığını"))
        XCTAssertTrue(result.contains("Dorika Kalp Bileklik"))
        XCTAssertFalse(result.contains("Arama sonuçları:"))
    }

    func testOfferRankingAndGrounding() {
        let evidence = "Kaynak: cimri.com\nBeta Elektronik 1.400 TL ücretsiz kargo.\nKaynak: akakce.com\nAlfa Teknoloji 1.500 TL ücretsiz kargo."
        let raw = #"[{"seller":"Alfa Teknoloji","price":1500,"shipping":0,"source":"akakce.com","quote":"Alfa Teknoloji 1.500 TL ücretsiz kargo."},{"seller":"Beta Elektronik","price":1400,"shipping":0,"source":"cimri.com","quote":"Beta Elektronik 1.400 TL ücretsiz kargo."}]"#
        let reply = ScreenQuestion.offerReply(raw: raw, evidence: evidence, currentPrice: 1300)
        XCTAssertTrue(reply.contains("Beta Elektronik"))
        XCTAssertTrue(reply.contains("1.400 TL"))
        XCTAssertTrue(reply.contains("daha ucuz değil"))
        XCTAssertFalse(reply.contains("Alfa Teknoloji"))
        XCTAssertTrue(ScreenQuestion.offerReply(raw: raw, evidence: "no such offers").contains("bulamadım"))
        XCTAssertEqual(ScreenQuestion.money("1.299,90"), 1299.9)
    }

    func testPriceSearchRequestsComparisonDomainAndFreshSellerText() {
        let body = WebSearch.body(query: "ürün", domains: ["akakce.com"], priceComparison: true)
        XCTAssertEqual(body["includeDomains"] as? [String], ["akakce.com"])
        let contents = body["contents"] as? [String: Any]
        XCTAssertEqual(contents?["maxAgeHours"] as? Int, 0)
        XCTAssertNotNil(contents?["text"])
        let data = Data(#"{"results":[{"title":"Model X fiyatları","url":"https://www.akakce.com/model-x.html","text":"Satıcı: Örnek Mağaza. Fiyat: 1250 TL. Kargo: ücretsiz."}]}"#.utf8)
        let evidence = WebSearch.results(from: data, priceComparison: true)
        XCTAssertTrue(evidence.contains("Örnek Mağaza"))
        XCTAssertTrue(evidence.contains("1250 TL"))
    }

    /// Model-behaviour check with synthetic offers, never real price claims.
    func testLiveDescriptionAndNamedCheapestSeller() async throws {
        guard ProcessInfo.processInfo.environment["SCREEN_INTENT_LIVE"] == "1" else { throw XCTSkip("Opt-in local model check") }
        let item = ScreenQuestion.Identity(product: "Deneme X100 256GB Siyah", store: "Ekran Mağazası", price: "2000 TL")
        let prompt = ScreenQuestion.pricePrompt(item: item, results: "Kaynak: akakce.com\nDeneme X100 256GB Siyah, stokta, Alfa Teknoloji, 1500 TL, ücretsiz kargo.\nKaynak: cimri.com\nDeneme X100 256GB Siyah, stokta, Beta Elektronik, 1400 TL, ücretsiz kargo.\nKaynak: epey.com\nDeneme X100 128GB Siyah, Gama, 1100 TL. Bunlar sentetik test teklifleridir.")
        let answer = await ScreenQuestion.priceAnswer(prompt: prompt, model: ScreenQuestion.localVisionModel)
        print("PRICE INTENT FIXTURE ANSWER: \(answer)")
        XCTAssertTrue(answer.contains("Beta Elektronik"))
        XCTAssertTrue(answer.contains("1400") || answer.contains("1.400"))
        XCTAssertFalse(answer.contains("Gama"))
        XCTAssertFalse(answer.contains("Alfa Teknoloji"))
        let description = try await LLM.default.chat(LLMChatRequest(model: ScreenQuestion.localVisionModel, messages: [["role": "system", "content": ScreenQuestion.descriptionPrompt(source: "Kadın Gold Renk Taşlı Dorika Kalp Bileklik")], ["role": "user", "content": "bu ürün ne"]], timeout: 30, temperature: 0, maxTokens: 250))
        print("DESCRIPTION INTENT FIXTURE ANSWER: \(description)")
        XCTAssertTrue(description.lowercased().contains("bilek"))
        XCTAssertFalse(description.lowercased().contains("bulamadım"))
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
