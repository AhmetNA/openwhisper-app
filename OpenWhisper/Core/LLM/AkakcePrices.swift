import Foundation

/// Read public Akakçe pages directly: its search finds model codes that a search-engine
/// index may miss, and Product/Offer JSON-LD preserves the actual merchant names.
enum AkakcePrices {
    struct Result {
        let evidence: String
        let offers: [ScreenQuestion.Offer]
    }

    static func search(product: String) async throws -> Result {
        var components = URLComponents(string: "https://www.akakce.com/arama/")!
        components.queryItems = [URLQueryItem(name: "q", value: ProductMatch.searchName(product))]
        let html = try await fetch(components.url!)
        let links = productLinks(html: html, product: product)
        guard !links.isEmpty else {
            owLog("[PriceSearch] Akakçe direct: no matching product link")
            return Result(evidence: "Akakçe'nin kendi aramasında modelle eşleşen ürün sayfası bulunamadı.", offers: [])
        }
        return await withTaskGroup(of: Result.self) { group in
            for url in links.prefix(3) {
                group.addTask {
                    do { return parse(html: try await fetch(url), product: product, pageURL: url) }
                    catch { return Result(evidence: "\(url.absoluteString): erişim/arama başarısız.", offers: []) }
                }
            }
            var evidence: [String] = [], offers: [ScreenQuestion.Offer] = []
            for await result in group { evidence.append(result.evidence); offers += result.offers }
            owLog("[PriceSearch] Akakçe direct: matched pages=\(links.count), structured offers=\(offers.count)")
            return Result(evidence: evidence.sorted().joined(separator: "\n"), offers: offers)
        }
    }

    private static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == "www.akakce.com" || response.url?.host == "akakce.com",
              data.count < 3_000_000 else { throw LLMError.malformed }
        return String(decoding: data, as: UTF8.self)
    }

    static func productLinks(html: String, product: String) -> [URL] {
        var seen = Set<String>()
        return captures(#"(?is)<a\b([^>]*)>"#, in: html).compactMap { attributes in
            guard let title = attribute("title", in: attributes), ProductMatch.matches(product: product, title: title),
                  let href = attribute("href", in: attributes),
                  let url = URL(string: href, relativeTo: URL(string: "https://www.akakce.com"))?.absoluteURL,
                  ["www.akakce.com", "akakce.com"].contains(url.host ?? ""),
                  url.scheme == "https", url.path.contains("-fiyati,"), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    static func parse(html: String, product: String, pageURL: URL) -> Result {
        var products: [[String: Any]] = []
        func visit(_ value: Any) {
            if let list = value as? [Any] { list.forEach(visit); return }
            guard let object = value as? [String: Any] else { return }
            if object["@type"] as? String == "Product" { products.append(object) }
            if let graph = object["@graph"] { visit(graph) }
        }
        for script in captures(#"(?is)<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#, in: html) {
            if let object = try? JSONSerialization.jsonObject(with: Data(script.utf8)) { visit(object) }
        }
        guard let object = products.first(where: { ProductMatch.matches(product: product, title: $0["name"] as? String ?? "") }),
              let aggregate = object["offers"] as? [String: Any], let rows = aggregate["offers"] as? [[String: Any]] else {
            return Result(evidence: "\(pageURL.absoluteString): eşleşen ürünün satıcı teklifleri okunamadı.", offers: [])
        }
        let shipping = shippingRows(html: html)
        var offers: [ScreenQuestion.Offer] = []
        for row in rows {
            guard (row["availability"] as? String)?.hasSuffix("/InStock") == true,
                  (row["itemCondition"] as? String)?.hasSuffix("/NewCondition") == true,
                  ["TRY", "TL"].contains(row["priceCurrency"] as? String ?? ""),
                  let seller = (row["seller"] as? [String: Any])?["name"] as? String, !seller.isEmpty,
                  let price = number(row["price"]), price > 0, price.isFinite else { continue }
            let ship = shipping.first { $0.seller == seller && abs($0.price - price) < 0.005 }?.shipping.flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
            let priceText = String(format: "%.2f", price).replacingOccurrences(of: ".", with: ",")
            let quote = "\(seller): \(priceText) TL. " + (ship == 0 ? "Ücretsiz kargo." : "Kargo: \(ship.map(String.init(describing:)) ?? "bilinmiyor").")
            offers.append(ScreenQuestion.Offer(seller: seller, price: price, shipping: ship, source: "akakce.com", quote: quote))
        }
        let name = object["name"] as? String ?? product
        return Result(evidence: "Ürün: \(name)\nKaynak URL: \(pageURL.absoluteString)\n" + offers.map(\.quote).joined(separator: "\n"), offers: offers)
    }

    private struct ShippingRow { let seller: String; let price: Double; let shipping: Double? }

    /// Shipping is not included in Akakçe's JSON-LD. Join its public hydration data to
    /// JSON-LD by the exact merchant AND price; never transfer one seller's free shipping.
    private static func shippingRows(html: String) -> [ShippingRow] {
        func unwrap(_ value: Any?) -> Any? {
            guard let pair = value as? [Any], pair.count >= 2 else { return nil }
            return pair[1]
        }
        for attributes in captures(#"(?is)<astro-island\b([^>]*)>"#, in: html) {
            guard attribute("component-export", in: attributes) == "PgViewContent",
                  let props = attribute("props", in: attributes),
                  let json = try? JSONSerialization.jsonObject(with: Data(props.utf8)) as? [String: Any],
                  let rows = unwrap(json["initialPgList"]) as? [Any] else { continue }
            return rows.compactMap { entry in
                guard let row = unwrap(entry) as? [String: Any], let marketplace = unwrap(row["vdName"]) as? String,
                      let price = number(unwrap(row["price"])) else { return nil }
                let nick = unwrap(row["pgNick"]) as? String ?? ""
                let seller = nick.isEmpty ? marketplace : marketplace + "/" + nick
                return ShippingRow(seller: seller, price: price, shipping: number(unwrap(row["shipPrice"])))
            }
        }
        return []
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        // Schema numbers use a decimal dot, unlike visible Turkish prices.
        return (value as? String).flatMap(Double.init)
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        let pattern = #"(?is)(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]*)""#
        if let value = captures(pattern, in: text).first { return entities(value) }
        return captures(#"(?is)(?:^|\s)"# + name + #"\s*=\s*'([^']*)'"#, in: text).first.map(entities)
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func entities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
