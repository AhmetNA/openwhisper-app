import Foundation

/// Jarvis's internet search: the cloud model asks for it as a tool (`CloudChatClient`), Exa
/// answers with the top pages and their key passages, and the model answers from those.
enum WebSearch {
    static let toolName = "web_search"
    static let endpoint = URL(string: "https://api.exa.ai/search")!
    /// What the spoken answer is built from; more only slows the second request.
    private static let maxChars = 3000
    /// Per page, so one long page can't hide the others (and their dates) from the model. At
    /// 450 a month table ended before November and the model gave another city's number.
    private static let maxPassageChars = 900

    /// The tool as the OpenAI `tools` field describes it.
    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": toolName,
            "description": "İnternette güncel bilgi arar: haber, skor, hava durumu, fiyat, yakın tarihli olaylar.",
            "parameters": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Arama sorgusu. Kullanıcı bir gün söylediyse (\"31 Ekim\", \"dün\", \"bugün\") tarihi gün ay yıl olarak yaz, ör. \"31 Ekim 2026\"; yalnızca yıl yazma."]],
                "required": ["query"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func body(query: String, domains: [String] = [], priceComparison: Bool = false) -> [String: Any] {
        // `instant`: as fast as `fast` and as good for Jarvis's questions, at about half the price.
        var body: [String: Any] = ["query": query, "type": "instant", "numResults": 5, "contents": ["highlights": true]]
        if !domains.isEmpty { body["includeDomains"] = domains }
        if priceComparison {
            body["type"] = "auto"
            body["numResults"] = 3
            body["contents"] = ["text": ["maxCharacters": 6000], "maxAgeHours": 0] as [String: Any]
        }
        return body
    }

    static func search(_ query: String, key: String, product: String? = nil, excludingPage: String? = nil, domains: [String] = [], priceComparison: Bool = false) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: priceComparison ? 18 : 6)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(query: query, domains: domains, priceComparison: priceComparison))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LLMError.http(status) }
        return results(from: data, product: product, excludingPage: excludingPage, priceComparison: priceComparison)
    }

    /// One line per page (title, date, address) and its passages, for the model to read.
    static func results(from data: Data, product: String? = nil, excludingPage: String? = nil, priceComparison: Bool = false) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else { return "Sonuç bulunamadı." }
        var out = ""
        func compact(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
                .replacingOccurrences(of: "ı", with: "i")
                .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        }
        let filtered = results.filter { result in
            if let product {
                let title = compact(result["title"] as? String ?? "")
                if priceComparison {
                    let tokens = product.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { compact(String($0)) }
                        .filter { !["kadin", "erkek", "renk", "ve", "icin"].contains($0) && !$0.isEmpty }
                    guard !tokens.isEmpty, tokens.allSatisfy({ title.contains($0) }) else { return false }
                } else if !title.contains(compact(product)) { return false }
            }
            if let excludingPage, let page = URL(string: excludingPage), let url = URL(string: result["url"] as? String ?? ""),
               page.host == url.host && page.path == url.path { return false }
            return true
        }
        guard !filtered.isEmpty else { return "Tam eşleşen ek kaynak bulunamadı." }
        for (index, result) in filtered.enumerated() {
            let date = (result["publishedDate"] as? String).map { " (\($0.prefix(10)))" } ?? ""
            var passageText = priceComparison ? (result["text"] as? String ?? "") : ""
            if passageText.isEmpty { passageText = (result["highlights"] as? [String] ?? []).joined(separator: " … ") }
            if product != nil {
                // A bare catalog rating is not evidence of customer experiences.
                passageText = passageText.components(separatedBy: "\n").filter {
                    $0.trimmingCharacters(in: .whitespaces).range(of: #"^(?:[0-5](?:[.,]\d+)?|[★☆⭐]+)$"#, options: .regularExpression) == nil
                }.joined(separator: "\n")
            }
            let passages = passageText.prefix(priceComparison ? 4000 : maxPassageChars)
            out += "\(index + 1). \(result["title"] as? String ?? "")\(date) \(result["url"] as? String ?? "")\n\(passages)\n"
        }
        return String(out.prefix(priceComparison ? 8000 : maxChars))
    }
}
