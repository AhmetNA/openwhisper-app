import Foundation

/// Decides, for a "Jarvis" session that is no command, whether the user is talking to Jarvis
/// (he answers out loud) or dictating / talking to someone else (the text is typed). Typing is
/// the safe side: only a clearly addressed question or request reaches the chat.
enum JarvisAddressee {
    private static let locale = Locale(identifier: "tr_TR")

    /// Chat only at or above this score (0–100). `defaults write com.openwhisper.app jarvisChatMinScore 60`
    static var minScore: Int {
        let stored = UserDefaults.standard.integer(forKey: "jarvisChatMinScore")
        return (1...100).contains(stored) ? stored : 70
    }

    static func isForJarvis(score: Int?, minScore: Int) -> Bool {
        guard let score else { return false }
        return score >= minScore
    }

    // MARK: - Trailing "yaz"

    // "… yaz", "… yazsana", "… yazar mısın", "… bunu yaz", "… yaz bunu", "… ve yaz."
    private static let typeRegex: NSRegularExpression = {
        let quotes = #""'“”‘’«»`"#
        let pattern = #"[\s,;:.!?\-"# + quotes + #"]*(?:\bve\s+)?(?:\b(?:bunu|şunu|sunu|onu)\s+)?\byaz(?:sana|sın|ın|abilir\s+m[iı]s[iı]n|ar\s+m[iı]s[iı]n)?(?:\s+(?:bunu|şunu|onu|hemen|lütfen))?[\s.!?,;:"# + quotes + #"]*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "bu yaz", "geçen yaz": the season, not the verb.
    private static let seasonWords: Set<String> = ["bu", "geçen", "gelecek", "o", "her", "bütün", "tüm", "bir", "bizim", "sıcak"]

    /// The text before a trailing "yaz" command, or nil when the text doesn't end with one.
    static func trailingTypeCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        guard lowered.utf16.count == trimmed.utf16.count,
              let match = typeRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered))
        else { return nil }
        let cut = String.Index(utf16Offset: match.range.location, in: trimmed)
        let matched = String(lowered[String.Index(utf16Offset: match.range.location, in: lowered)...])
        let before = String(trimmed[..<cut])
        // A bare "yaz" right after a season word is the noun.
        let bareYaz = matched.split(whereSeparator: { !$0.isLetter }) == ["yaz"]
        if bareYaz, let previous = before.split(whereSeparator: { !$0.isLetter }).last,
           seasonWords.contains(previous.lowercased(with: locale)) {
            return nil
        }
        let body = before.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-\"'“”‘’«»`")))
        return body.isEmpty ? nil : body
    }

    // MARK: - LLM score

    /// 0–100: how likely the user is talking to Jarvis. nil when the model is unreachable,
    /// slow or answers nonsense, which the caller treats as "type it".
    static func score(text: String, frontApp: String?, lastReply: String?, model: String) async -> Int? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt(text: text, frontApp: frontApp, lastReply: lastReply),
            "stream": false,
            "think": false,
            "format": "json",
            "keep_alive": LLMCleanup.keepAlive,
            "options": ["temperature": 0.0, "num_predict": 16],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let answer = json["response"] as? String
        else { return nil }
        return parseScore(answer)
    }

    /// `{"score": 85}`, `{"score": "85"}` or a bare number, clamped to 0–100.
    static func parseScore(_ answer: String) -> Int? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            if let number = json["score"] as? NSNumber { return min(max(number.intValue, 0), 100) }
            if let string = json["score"] as? String, let value = Int(string) { return min(max(value, 0), 100) }
            return nil
        }
        guard let value = Int(trimmed) else { return nil }
        return min(max(value, 0), 100)
    }

    static func prompt(text: String, frontApp: String?, lastReply: String?) -> String {
        let context = lastReply.map { "\nJarvis'in az önceki cevabı (devam sorusu olabilir): \"\($0)\"" } ?? ""
        return """
            Mac'te Jarvis adında sesli bir asistan var. Kullanıcı "Jarvis" diye seslendi, kayıt başladı; \
            o seslenme zaten oldu, yani "Jarvis" kelimesi tek başına bir şey kanıtlamaz. Kayıt sırasında \
            kullanıcı bazen Jarvis'le konuşur, bazen de odadaki birine döner, ya da bir mesaj / metin \
            dikte eder. Dikte edilen metin önde duran uygulamaya yazılacak.
            Önde duran uygulama: \(frontApp ?? "bilinmiyor")\(context)

            Aşağıdaki cümle Jarvis'e mi söylendi? 0 ile 100 arası puan ver:
            100 = açıkça Jarvis'e soru ya da istek (sohbet, bilgi, fikir sorma).
            0 = açıkça başkasına söylenmiş ya da yazılacak bir mesaj / metin.
            Emin değilsen 50 civarı ver.

            Jarvis'e (yüksek puan): "kara deliği kısaca anlat", "sence bu mantıklı mı", "selam nasılsın", \
            "bana bir espri yap", "yarın yağmur yağar mı sence", "peki neden" (az önceki cevaba devam).
            Başkasına ya da yazılacak (düşük puan): "abi akşam geliyor musun", "tamam hocam hallederim", \
            "arkadaşlar raporu cuma atıyorum", "Jarvis çok iyi çalışıyor bak", "anne yemek hazır mı", \
            "toplantı yarın saat üçte başlıyor", "merhaba, dosyayı ekte gönderiyorum". \
            WhatsApp, Slack, Mail, Messages, Telegram, Discord önde ise mesaj yazıyor olması daha olası.

            Cümle: "\(text)"
            Sadece JSON ver: {"score": <0-100>}
            """
    }
}
