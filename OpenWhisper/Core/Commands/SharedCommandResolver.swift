import Foundation

/// A second chance for a short, explicit command. Predictions never provide targets or slots.
/// Rules still own exact commands, message bodies, dates, recipients and destructive actions.
enum SharedCommandResolver {
    static func resolve(_ text: String, decisions: [String: SetFitDecider.Decision],
                        context: CommandRegistry.Context, frontBundleID: String? = nil) -> VoiceCommand? {
        let t = text.lowercased(with: Locale(identifier: "tr_TR"))
        guard text.count <= 200, text.split(whereSeparator: \.isWhitespace).count <= 20,
              CommandRewriter.looksLikeCommand(text), !isNarrationOrNegation(t),
              confident("command_structure", decisions)?.label == "single",
              confident("routing_intent", decisions)?.label == "command" else { return nil }
        var candidates: [VoiceCommand] = []
        func has(_ cues: [String]) -> Bool { cues.contains { t.contains($0) } }
        func propose(_ task: String, phrases: [String: String], cues: [String], enabled: Bool = false) {
            guard enabled || has(cues), let decision = confident(task, decisions),
                  let phrase = phrases[decision.label],
                  let command = CommandRewriter.safeCommand(phrase, context: context) else { return }
            if !candidates.contains(command) { candidates.append(command) }
        }
        propose("system_intent", phrases: ["wifi_on": "Wi-Fi'yi aç", "wifi_off": "Wi-Fi'yi kapat"],
                cues: ["wi-fi", "wifi", "vayfay", "kablosuz", "internet"])
        propose("system_intent", phrases: ["bluetooth_on": "Bluetooth'u aç", "bluetooth_off": "Bluetooth'u kapat"],
                cues: ["bluetooth", "blutut", "bluetoot"])
        propose("system_intent", phrases: ["brightness_up": "parlaklığı artır", "brightness_down": "parlaklığı azalt"],
                cues: ["parlak", "ekran", "aydınlat"])
        propose("system_intent", phrases: ["dark_on": "karanlık modu aç", "dark_off": "karanlık modu kapat"],
                cues: ["karanlık", "koyu", "tema", "görünüm"])
        propose("system_intent", phrases: ["scroll_up": "ekranı yukarı kaydır", "scroll_down": "ekranı aşağı kaydır"],
                cues: ["kaydır"])
        propose("system_intent", phrases: ["mute": "sesi kapat", "unmute": "sessizden çıkar"],
                cues: ["bilgisayar", "sistem", "mac", "sessiz"])
        propose("system_intent", phrases: ["screenshot": "ekran görüntüsü al"], cues: ["ekran", "görüntü"])
        propose("video_intent", phrases: ["play": "videoyu başlat", "pause": "videoyu durdur", "restart": "videoyu başa sar",
            "speed_up": "videoyu hızlandır", "speed_down": "videoyu yavaşlat", "mute": "videonun sesini kapat",
            "unmute": "videonun sesini aç", "subtitles_on": "altyazıyı aç", "subtitles_off": "altyazıyı kapat",
            "next": "sonraki video", "previous": "önceki video", "fullscreen": "videoyu tam ekran yap"],
                cues: ["video", "oynatıcı", "youtube", "altyazı"])
        let browser = frontBundleID.map { bundle in
            ["safari", "chrome", "firefox", "brave", "edge"].contains { bundle.lowercased().contains($0) }
        } ?? false
        propose("browser_intent", phrases: ["new_tab": "yeni sekme aç", "close_tab": "sekmeyi kapat", "reload": "sayfayı yenile",
            "back": "önceki sayfaya dön", "forward": "sonraki sayfaya git", "next_tab": "sonraki sekmeye geç",
            "previous_tab": "önceki sekmeye geç", "summarize": "bu sayfayı özetle", "youtube_home": "YouTube ana sayfasını aç",
            "youtube_more": "YouTube'da başka videolar göster", "youtube_visible": "ekrandaki YouTube videolarını oku"],
                cues: ["sekme", "sayfa", "tarayıcı", "safari", "youtube"], enabled: browser)
        propose("mail_intent", phrases: ["count": "kaç okunmamış mail var", "latest": "son mail kimden",
            "open": "Mail aç", "check": "mailleri kontrol et", "read_unread": "okunmamış mailleri oku",
            "read_latest": "son maili oku"], cues: ["mail", "e-posta", "eposta", "posta"])
        propose("whatsapp_intent", phrases: ["unread": "WhatsApp'ta okunmamış mesajları oku"], cues: ["whatsapp"],
                enabled: frontBundleID?.lowercased().contains("whatsapp") == true)
        propose("spotify_intent", phrases: ["play": "müziğe devam et", "pause": "şarkıyı durdur", "next": "sonraki şarkı",
            "previous": "önceki şarkı", "volume_up": "sesi artır", "volume_down": "sesi kıs", "current": "şu an ne çalıyor",
            "like": "bu şarkıyı beğen"], cues: ["müzik", "müziğ", "şarkı", "parça", "spotify", "ses"])
        propose("spotify_extended", phrases: ["play_liked": "beğendiğim şarkıları çal", "shuffle_on": "karışık çal",
            "shuffle_off": "sırayla çal", "repeat_track": "bu şarkıyı tekrarla", "repeat_context": "listeyi tekrarla",
            "repeat_off": "tekrarı kapat", "unlike": "çalan şarkıyı beğenilenlerden çıkar",
            "question_album": "bu şarkı hangi albümden", "question_remaining": "şarkının bitmesine ne kadar kaldı",
            "question_next": "sıradaki şarkı ne", "question_device": "Spotify hangi cihazda çalıyor",
            "cancel_sleep_timer": "uyku zamanlayıcısını iptal et"], cues: ["müzik", "müziğ", "şarkı", "parça", "spotify"])
        if let decision = confident("timer_intent", decisions), has(["sayaç", "zamanlayıcı", "alarm"]) {
            if decision.label == "remaining", context.timerActive { candidates.append(.timer(.remaining)) }
            if decision.label == "stop", context.ringing { candidates.append(.timer(.stop)) }
        }
        if let action = confident("app_action", decisions), ["open", "switch"].contains(action.label),
           let app = exactInstalledTarget(text, installedApps: context.installedApps) {
            let phrase = action.label == "open" ? "\(app)'yi aç" : "\(app)'ye geç"
            if let command = CommandRewriter.safeCommand(phrase, context: context), !candidates.contains(command) {
                candidates.append(command)
            }
        }
        // Independently confident but contradictory heads are uncertainty, not a vote.
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func confident(_ name: String, _ decisions: [String: SetFitDecider.Decision]) -> SetFitDecider.Decision? {
        guard let decision = decisions[name], decision.confidence >= 0.98 else { return nil }
        return decision
    }

    static func isNarrationOrNegation(_ text: String) -> Bool {
        if text.contains("«") || text.contains("»") || text.contains("\"") || text.contains("“") || text.contains("”") { return true }
        return text.range(of: #"\b(?:yaz\p{L}*|rapor\p{L}*|örnek\p{L}*|cümle\p{L}*|kod\p{L}*|fonksiyon\p{L}*|özellik\p{L}*|test\p{L}*|komut\p{L}*|metin\p{L}*|alıntı\p{L}*|demedim|istemiyorum|istemedim|isteme\p{L}*|yapma\p{L}*|açma\p{L}*|kapatma\p{L}*|durdurma\p{L}*|gönderme\p{L}*|çalma|silme\p{L}*|uyutma\p{L}*|kilitleme\p{L}*)\b"#,
                          options: .regularExpression) != nil
    }

    private static func exactInstalledTarget(_ text: String, installedApps: [String]) -> String? {
        let t = text.lowercased(with: Locale(identifier: "tr_TR"))
        let hits = installedApps.filter(SystemController.isVoiceApp).filter { app in
            t.range(of: #"(?<!\p{L})"# + NSRegularExpression.escapedPattern(for: app.lowercased(with: Locale(identifier: "tr_TR"))) + #"(?!\p{L})"#,
                    options: .regularExpression) != nil
        }
        return hits.count == 1 ? hits[0] : nil
    }
}
