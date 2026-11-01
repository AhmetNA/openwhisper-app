import XCTest
@testable import OpenWhisper

final class AkakcePricesTests: XCTestCase {
    private let product = "Philips 5500 LatteGo EP5543/80"
    private let page = URL(string: "https://www.akakce.com/espresso-makinesi/en-ucuz-philips-fiyati,649995567.html")!

    private func snapshot() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "akakce-philips-prices", withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPriceExcerptSkipsMenusButKeepsMerchant() {
        let content = String(repeating: "navigation ", count: 1500) + "Satıcı Örnek Mağaza: 1250 TL ücretsiz kargo"
        let excerpt = WebSearch.pricePassage(content)
        XCTAssertTrue(excerpt.contains("Örnek Mağaza"))
        XCTAssertTrue(excerpt.contains("1250 TL"))
        XCTAssertLessThan(excerpt.count, 700)
    }

    func testActualPagePreservesMerchantsPricesAndShipping() throws {
        let result = AkakcePrices.parse(html: try snapshot(), product: product, pageURL: page)
        XCTAssertEqual(result.offers.count, 3)
        XCTAssertEqual(result.offers.first(where: { $0.seller == "Trendyol/ALDIMGİTTİ" })?.price, 21350)
        XCTAssertEqual(result.offers.first(where: { $0.seller == "Hepsiburada/Ayağıma Getir" })?.price, 22532.13)
        XCTAssertTrue(result.offers.allSatisfy { $0.shipping == 0 })
        // Even a failed local JSON extraction must not throw away structured site offers.
        let answer = ScreenQuestion.offerReply(raw: "invalid model reply", evidence: result.evidence, currentPrice: 22532.13, verifiedOffers: result.offers)
        XCTAssertTrue(answer.contains("ALDIMGİTTİ"))
        XCTAssertTrue(answer.contains("21.350 TL"))
        XCTAssertFalse(answer.contains("bulamadım"))
    }

    func testRejectsOtherVariantAndDoesNotAssumeShipping() throws {
        let html = try snapshot()
        XCTAssertTrue(AkakcePrices.parse(html: html, product: "Philips EP5543/90", pageURL: page).offers.isEmpty)
        let withoutShipping = html.components(separatedBy: "<astro-island")[0]
        let offers = AkakcePrices.parse(html: withoutShipping, product: product, pageURL: page).offers
        XCTAssertEqual(offers.count, 3)
        XCTAssertTrue(offers.allSatisfy { $0.shipping == nil })
    }

    func testExcludesUsedAndUnavailableOffers() throws {
        let html = try snapshot().replacingOccurrences(of: "/InStock", with: "/OutOfStock")
        XCTAssertTrue(AkakcePrices.parse(html: html, product: product, pageURL: page).offers.isEmpty)
        let used = try snapshot().replacingOccurrences(of: "/NewCondition", with: "/UsedCondition")
        XCTAssertTrue(AkakcePrices.parse(html: used, product: product, pageURL: page).offers.isEmpty)
    }

    func testSearchLinksKeepExactModelAndSameSiteOnly() {
        let html = #"<a href="/espresso/en-ucuz-philips-fiyati,1.html" title="Philips EP5543/80">yes</a><a href="/espresso/en-ucuz-philips-fiyati,2.html" title="Philips EP5543/90">no</a><a href="https://elsewhere.test/en-ucuz-fiyati,3.html" title="Philips EP5543/80">no</a>"#
        let links = AkakcePrices.productLinks(html: html, product: product)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.host, "www.akakce.com")
    }
}
