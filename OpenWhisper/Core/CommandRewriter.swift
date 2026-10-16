import Foundation

/// Second chance for a command no rule recognised ("ortalık çok karanlık, ekranı biraz
/// aç bakalım"): the local model rewrites it into one plain command sentence, which then
/// has to pass the same deterministic parsers as a spoken command. The model never runs
/// anything itself, and commands that are hard to undo are not taken from a rewrite.
enum CommandRewriter {
    /// Ends like a request to do something ("… aç", "… kapatır mısın", "… yapabilir misin").
    static func looksLikeCommand(_ text: String) -> Bool {
        let locale = Locale(identifier: "tr_TR")
        let folded = text.lowercased(with: locale)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
        guard !folded.isEmpty, folded.split(separator: " ").count <= 14 else { return false }
        let verbs = "aç|kapat|kıs|azalt|yükselt|arttır|artır|çal|oynat|durdur|başlat|geç|kur|ayarla|göster|getir|söyle|oku|yap|et|ver|al|koy|gönder|bul|ara|atla|değiştir|indir|kaldır|sustur|aktif\\s+et|ekle"
        let pattern = "(?:^|\\s)\\S*(?:\(verbs))(?:ır|ir|ur|ür|ar|er|abilir|ebilir)?(?:\\s*m[ıiuü]s[ıiuü]n(?:[ıiuü]z)?)?(?:\\s+lütfen)?(?:\\s+bakalım)?$"
        return folded.range(of: pattern, options: .regularExpression) != nil
    }

    /// Asks the model for one canonical command sentence; nil when it says it isn't one,
    /// is unreachable or slow.
    static func rewrite(_ text: String, model: String, timeout: TimeInterval = 4) async -> String? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt(for: text),
            "stream": false,
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "options": ["temperature": 0.0, "num_predict": 40, "stop": ["\n"]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let answer = json["response"] as? String else { return nil }
        let line = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard !line.isEmpty, line.uppercased() != "YOK", line.count < 120 else { return nil }
        return line
    }

    static func prompt(for text: String) -> String {
        """
        Bir sesli asistanın komut tanıyıcısısın. Kullanıcının cümlesini, aşağıdaki örneklerdekine benzer \
        tek bir kısa Türkçe komut cümlesine çevir. Cümle bir bilgisayar komutu değilse ya da emin değilsen \
        yalnızca YOK yaz. Açıklama yazma, yalnızca komutu yaz.
        Örnek komutlar:
        Sesi kıs / Sesi aç / Sesi yüzde 30 yap / Sesi kapat
        Ekran parlaklığını artır / Ekran parlaklığını azalt
        Karanlık modu aç / Karanlık modu kapat
        Wi-Fi'yi aç / Wi-Fi'yi kapat / Bluetooth'u aç / Bluetooth'u kapat
        Safari'yi aç / Safari'ye geç / Spotify'a geç
        Ekran görüntüsü al / Saat kaç / Pil kaç
        Bugün ne var / Okunmamış mail var mı
        Şarkıyı durdur / Müziği devam ettir / Sonraki şarkı / Önceki şarkı / Tarkan çal / Beğendiğim şarkıları çal
        Videoyu durdur / Videoyu tam ekran yap / Videoyu 10 saniye ileri al
        Yeni sekme aç / Sayfayı yenile / Google'da kedi ara / Bu sayfayı özetle
        Kullanıcı: \(text)
        Komut:
        """
    }

    /// The rewrite as a system command, unless it is one that shouldn't come from a guess
    /// (quitting apps, sleeping, locking, marking mail read, mail replies, calendar entries, shortcuts).
    static func safeSystemCommand(_ rewritten: String, installedApps: [String]) -> SystemCommand? {
        guard let command = SystemCommandParser.parse(rewritten, installedApps: installedApps, shortcuts: []) else { return nil }
        switch command {
        case .quitApp, .forceQuitApp, .sleep, .displaySleep, .lockScreen, .screenSaver, .mailMarkAllRead,
             .developerMode, .runShortcut, .calendarEvent, .headset, .mailReplyDraft:
            return nil
        default:
            return command
        }
    }
}
