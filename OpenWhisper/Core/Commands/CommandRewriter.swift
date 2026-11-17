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
        if folded.range(of: pattern, options: .regularExpression) != nil { return true }
        // A misheard verb ("parlaklığı kız", "şarkıyı durdr"): the last word is one letter off.
        guard let last = folded.split(separator: " ").last.map(String.init), last.count >= 3 else { return false }
        return verbs.split(separator: "|").contains { verb in
            verb.count >= 3 && !verb.contains("\\") && CorrectionEngine.levenshtein(last, String(verb)) == 1
        }
    }

    /// A word that may be Claude as Whisper hears it ("cloud", "klod", "clad", "klaude"); only
    /// the model can tell from the sentence whether the app was meant.
    static func mentionsClaude(_ text: String) -> Bool {
        let folded = text.lowercased(with: Locale(identifier: "tr_TR"))
        return folded.range(of: "(?:^|[^\\p{L}])(?:\(AgentCommandParser.claudeSpellings))", options: .regularExpression) != nil
    }

    /// Asks the model for one canonical command sentence; nil when it says it isn't one,
    /// is unreachable or slow. With `cloud` set (Jarvis's chat is on the cloud) the cloud model is
    /// asked first (a `FallbackChat` hands a slow or failing cloud over to Ollama).
    static func rewrite(_ text: String, model: String, timeout: TimeInterval = 4,
                        client: any LLMClient = LLM.default,
                        cloud: (client: any ChatStreaming, model: String)? = nil) async -> String? {
        let answer: String
        if let cloud {
            let request = LLMChatRequest(model: cloud.model, messages: [["role": "user", "content": prompt(for: text)]],
                                         timeout: timeout, temperature: 0.0, maxTokens: 40)
            var reply = ""
            do {
                for try await piece in cloud.client.streamChat(request) { reply += piece }
            } catch {
                owLog("[CommandRewriter] Cloud (\(cloud.model)) gave no usable answer: \(ChatFallback.describe(error))")
                return nil
            }
            // No stop sequence on the cloud: keep the first line, as `stop: ["\n"]` does locally.
            answer = reply.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        } else {
            let request = LLMRequest(model: model, prompt: prompt(for: text), timeout: timeout,
                                     temperature: 0.0, maxTokens: 40, stop: ["\n"])
            guard let local = try? await client.generate(request) else { return nil }
            answer = local
        }
        let line = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard !line.isEmpty, line.uppercased() != "YOK", line.count < 120 else { return nil }
        return line
    }

    static func prompt(for text: String) -> String {
        """
        Bir sesli asistanın komut tanıyıcısısın. Kullanıcının cümlesi konuşmadan yazıya çevrildi; \
        kelimeler yanlış duyulmuş ya da eksik olabilir (ör. "parlaklığı kız" = "Ekran parlaklığını azalt", \
        "şarkıy durdur" = "Şarkıyı durdur", "safariy aş" = "Safari'yi aç", "sesi artr" = "Sesi artır", "sesi biraz kısık yap" = "Sesi azalt"). \
        Kullanıcının büyük olasılıkla istediği bilgisayar komutunu aşağıdaki örneklerdekine benzer tek bir \
        kısa Türkçe komut cümlesi olarak yaz; makul bir komut okunabiliyorsa onu yaz. Cümle sohbet, bilgi \
        sorusu ya da dikte ise, yani bilgisayardan bir iş istemiyorsa yalnızca YOK yaz. Açıklama yazma, \
        yalnızca komutu yaz.
        Örnek komutlar:
        Sesi artır / Sesi azalt / Sesi yüzde 30 yap / Sesi kapat
        Ekran parlaklığını artır / Ekran parlaklığını azalt
        Karanlık modu aç / Karanlık modu kapat
        Wi-Fi'yi aç / Wi-Fi'yi kapat / Bluetooth'u aç / Bluetooth'u kapat
        Safari'yi aç / Safari'ye geç / Spotify'a geç
        Ekran görüntüsü al / Saat kaç / Pil kaç
        Bugün ne var / Okunmamış mail var mı
        Şarkıyı durdur / Müziği devam ettir / Sonraki şarkı / Önceki şarkı / Tarkan çal / Beğendiğim şarkıları çal
        Videoyu durdur / Videoyu tam ekran yap / Videoyu 10 saniye ileri al
        Yeni sekme aç / Sayfayı yenile / Google'da kedi ara / Bu sayfayı özetle
        Claude'a geç / Claude'da son sohbeti özetle / Codex'te son sohbeti özetle / Biten sohbete geç / \
        Claude'da yeni sohbet aç / Claude'da vergi sohbetine geç
        "cloud", "klod", "clad", "klaude", "kılod" gibi kelimeler çoğu zaman Claude uygulamasının yanlış \
        duyulmuş halidir; cümleden hangisi kastedildiğini çıkar ("claude da en son ne görüştük" = \
        "Claude'da son sohbeti özetle"). Gerçekten bulut ya da iCloud kastediliyorsa Claude yazma \
        ("cloud modeli neden yavaş" = YOK, "iCloud yedeği dolmuş" = YOK).
        Kullanıcı: \(text)
        Komut:
        """
    }

    /// The rewrite read by `CommandRegistry` as a system or Spotify command (never a timer, an
    /// agent message or a shortcut), unless it is one that shouldn't come from a guess.
    static func safeCommand(_ rewritten: String, context: CommandRegistry.Context) -> VoiceCommand? {
        var context = context
        context.shortcuts = { [] }
        switch CommandRegistry.match(rewritten, in: CommandRegistry.systemDomains.union([.spotify]), context: context) {
        case .system(let command)?:
            return isSafe(command) ? .system(command) : nil
        case .spotify(let request)?:
            return .spotify(request)
        default:
            return nil
        }
    }

    /// A search, address or song the user never said ("jarvana karşı en iyi pick ne" →
    /// "Google'da kedi ara", copied from the examples): a rewrite may fix a misheard verb, but
    /// what to look for or play has to come from the user's own words.
    static func inventsPayload(_ command: VoiceCommand, rewritten: String, original: String) -> Bool {
        let locale = Locale(identifier: "tr_TR")
        let payload: String
        switch command {
        case .system(.browser(.search(_, let query))), .system(.browser(.youtubeTitle(let query))),
             .system(.browser(.open(let query))):
            payload = query
        case .spotify:
            let lower = rewritten.lowercased(with: locale).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard lower.hasSuffix(" çal") else { return false }
            payload = String(lower.dropLast(4))
        default:
            return false
        }
        func words(_ text: String) -> [String] {
            text.lowercased(with: locale).components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
        }
        let said = words(original)
        let wanted = words(payload)
        return !wanted.isEmpty && !wanted.contains { word in
            said.contains { word.hasPrefix($0.prefix(4)) || $0.hasPrefix(word.prefix(4)) }
        }
    }

    /// The rewrite as a system command, unless it is one that shouldn't come from a guess
    /// (quitting apps, sleeping, locking, marking mail read, mail replies, calendar entries, shortcuts).
    static func safeSystemCommand(_ rewritten: String, installedApps: [String]) -> SystemCommand? {
        guard let command = SystemCommandParser.parse(rewritten, installedApps: installedApps, shortcuts: []) else { return nil }
        return isSafe(command) ? command : nil
    }

    private static func isSafe(_ command: SystemCommand) -> Bool {
        switch command {
        case .disableWakeWord, .quitApp, .forceQuitApp, .sleep, .displaySleep, .lockScreen, .screenSaver, .mailMarkAllRead,
             .scene, .runShortcut, .calendarEvent, .headset, .mailReplyDraft, .mailAttachment, .mailConversation, .agentChatHistory, .clipboard(.sendWhatsApp):
            return false
        default:
            return true
        }
    }
}
