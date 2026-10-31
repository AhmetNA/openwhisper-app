import Foundation

/// Jarvis's internet search: the cloud model asks for it as a tool (`CloudChatClient`), Exa
/// answers with the top pages and their key passages, and the model answers from those.
enum WebSearch {
    static let toolName = "web_search"
    static let endpoint = URL(string: "https://api.exa.ai/search")!
    /// What the spoken answer is built from; more only slows the second request.
    private static let maxChars = 3000
    /// Per page, so one long page can't hide the others (and their dates) from the model.
    private static let maxPassageChars = 450

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

    static func body(query: String) -> [String: Any] {
        // `instant`: as fast as `fast` and as good for Jarvis's questions, at about half the price.
        ["query": query, "type": "instant", "numResults": 5, "contents": ["highlights": true]]
    }

    static func search(_ query: String, key: String) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(query: query))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LLMError.http(status) }
        return results(from: data)
    }

    /// One line per page (title, date, address) and its passages, for the model to read.
    static func results(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else { return "Sonuç bulunamadı." }
        var out = ""
        for (index, result) in results.enumerated() {
            let date = (result["publishedDate"] as? String).map { " (\($0.prefix(10)))" } ?? ""
            let passages = (result["highlights"] as? [String] ?? []).joined(separator: " … ").prefix(maxPassageChars)
            out += "\(index + 1). \(result["title"] as? String ?? "")\(date) \(result["url"] as? String ?? "")\n\(passages)\n"
        }
        return String(out.prefix(maxChars))
    }
}
