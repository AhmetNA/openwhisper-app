import Foundation

/// A Mac action Jarvis can carry out by voice.
enum SystemCommand: Equatable, Sendable {
    case wifi(on: Bool)
    case bluetooth(on: Bool)
    /// Connect or disconnect a paired Bluetooth audio device ("kulaklığı bağla / bağlantıyı kes").
    case headset(connect: Bool)
    case mute(Bool)
    /// nil = step (up when `up`), otherwise an absolute level 0…100.
    case brightness(up: Bool, level: Int?)
    case darkMode(on: Bool)
    case lockScreen
    case displaySleep
    case sleep
    case screenSaver
    case screenshot
    case battery
    case time
    /// An installed app by its file name without ".app" ("Safari", "Google Chrome").
    case openApp(String)
    case quitApp(String)
    /// Apple Mail (`MailController`).
    case mailCount
    case mailLatest
    case mailOpen
    case mailCheck
    case mailReadUnread
    case mailMarkAllRead
    /// "Bugün ne var?": calendar, reminders and mail for today (0) or tomorrow (1).
    case briefing(dayOffset: Int)
    /// A Shortcuts.app shortcut by its exact name.
    case runShortcut(String)
}

/// Pure parsing of short Turkish (and some English) commands from the raw Whisper transcript:
/// "Bluetooth'u kapat", "parlaklığı artır", "Safari'yi aç". Only a short utterance that is
/// nothing but the command counts, so dictation that mentions Wi-Fi is never executed.
/// Volume levels stay with `SpotifyManager` ("sesi 40 yap", "biraz kıs"); only muting is here.
enum SystemCommandParser {
    private static let locale = Locale(identifier: "tr_TR")
    private static let maxWords = 7

    // Whisper spellings seen for these words, after lowercasing with the Turkish locale.
    private static let bluetooth = #"(?:bluetooth|bluetoot|bluetut|blutut|blututh|blu tut|blue tooth|blotut|bulutut|bt)"#
    private static let wifi = #"(?:wi-?fi|wifi|wi fi|vayfay|vay fay|wayfay|vaifai|kablosuz(?: ağ)?|internet)"#
    private static let headset = #"(?:kulaklı[kğ]|airpods|buds|kulaklar)"#
    private static let offVerb = #"(?:kapat|kapa|devre dışı|kes|ayır|kopar|çıkar|turn off|disable|disconnect)"#
    private static let onVerb = #"(?:\baç|etkinleştir|başlat|bağla(?!ntı)|turn on|enable|connect)"#
    private static let upVerb = #"(?:artır|arttır|yükselt|\baç|aydınlat|çoğalt)"#
    private static let downVerb = #"(?:azalt|düşür|kıs|karart|kapat)"#

    /// Apps "Spotify'ı aç / kapat" must not reach: `SpotifyManager` already plays and pauses them.
    private static let appsHandledElsewhere: Set<String> = ["spotify"]

    /// `installedApps`: app names to resolve "X'i aç / kapat" against (see `SystemController`).
    /// `shortcuts`: names from `shortcuts list`, for "X kısayolunu çalıştır".
    static func parse(_ text: String, installedApps: [String] = [], shortcuts: [String] = []) -> SystemCommand? {
        var cleaned = text.lowercased(with: locale)
            .replacingOccurrences(of: #"[.,!?;:"“”]"#, with: " ", options: .regularExpression)
        // A leading call to the assistant or a filler is not part of the command.
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)\s+)?(?:(?:lütfen|şunu|bi|bir)\s+)?"#,
            with: "", options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        // First, and with a longer limit: shortcut names are free text ("Wi-Fi ile Sabah Özeti")
        // that would otherwise read as a Wi-Fi or app command.
        if let shortcut = parseShortcut(cleaned, shortcuts: shortcuts) { return shortcut }
        guard cleaned.split(separator: " ").count <= maxWords else { return nil }
        if let briefing = parseBriefing(cleaned) { return briefing }

        if let mail = parseMail(cleaned) { return mail }
        if let query = parseQuery(cleaned) { return query }
        if let action = parseAction(cleaned) { return action }

        let off = matches(cleaned, offVerb)
        let on = matches(cleaned, onVerb)
        if off != on {
            if matches(cleaned, headset) { return .headset(connect: on) }
            if matches(cleaned, bluetooth) { return .bluetooth(on: on) }
            if matches(cleaned, wifi) { return .wifi(on: on) }
        }
        return parseApp(cleaned, installedApps: installedApps)
    }

    /// "Bugün ne var", "bugün neyimiz var", "programımız ne", "yarın planım ne", "günün özeti".
    private static func parseBriefing(_ text: String) -> SystemCommand? {
        let day = #"(?:bugün|bugünkü|bu gün|yarın|yarınki)"#
        let ask = #"(?:ne var|neler var|neyim var|neyimiz var|nelerimiz var|program|plan|ajanda|takvim)"#
        let asksDay = matches(text, day) && matches(text, ask)
        let generic = matches(text, #"^(?:günlük özet|günün özeti|özet ver|programım ne|programımız ne|programım nedir|programımız nedir|ajandam|ajandamda ne var|takvimimde ne var)$"#)
        guard asksDay || generic else { return nil }
        return .briefing(dayOffset: matches(text, #"yarın"#) ? 1 : 0)
    }

    /// Words that mark a shortcut run; the plain verb alone only counts with a known name.
    static let shortcutMention = #"kısayol|kısa yol|shortcut|çalıştır"#

    /// "Sabah Özeti kısayolunu çalıştır", "kısayol Jarvis'i başlat", "Sabah Özeti'ni çalıştır".
    private static func parseShortcut(_ text: String, shortcuts: [String]) -> SystemCommand? {
        guard !shortcuts.isEmpty, text.split(separator: " ").count <= 14 else { return nil }
        let patterns = [
            #"^(.+?)\s+(?:kısayolunu|kısa yolunu|kısayolu|shortcut\S*)\s+(?:çalıştır|başlat|aç|yürüt)$"#,
            #"^(?:kısayol|kısa yol|shortcut)\S*\s+(.+?)\s+(?:çalıştır|başlat|yürüt)$"#,
            #"^(.+?)\s+(?:çalıştır|yürüt)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            if let name = resolveName(String(text[range]), in: shortcuts) { return .runShortcut(name) }
        }
        return nil
    }

    // "mail", "maili", "mailler", "e-posta", "email", and Whisper's "meyl", "meil".
    private static let mail = #"(?:e-?mail|mail|meyl|meil|e-?posta)"#

    /// Before the app form: "maili aç" is the newest mail, not just the Mail app.
    private static func parseMail(_ text: String) -> SystemCommand? {
        guard matches(text, mail) else { return nil }
        if matches(text, #"okundu (?:yap|işaretle)"#) { return .mailMarkAllRead }
        if matches(text, #"(?:kontrol et|yenile|kontrol)"#) { return .mailCheck }
        if matches(text, #"okunmamış.*\#(mail)\w* oku|\#(mail)\w* oku"#), !matches(text, #"^son"#) { return .mailReadUnread }
        if matches(text, #"\baç"#) { return .mailOpen }
        if matches(text, #"son (?:gelen )?\#(mail)|kimden|konusu"#) { return .mailLatest }
        if matches(text, #"kaç|var mı|geldi mi|yeni \#(mail)|okunmamış"#) { return .mailCount }
        return nil
    }

    /// Questions answered in the flow bar.
    private static func parseQuery(_ text: String) -> SystemCommand? {
        if matches(text, #"^(?:saat kaç|saat ne|şu an saat kaç)"#) { return .time }
        if matches(text, #"(?:\bşarj|\bpil|batarya)\b.*(?:kaç|ne kadar|durum|yüzde|var mı|kaldı)|^(?:şarj|pil|batarya) (?:durumu|seviyesi)$"#) { return .battery }
        return nil
    }

    /// Fixed actions, checked before the generic "X'i aç / kapat" app form.
    private static func parseAction(_ text: String) -> SystemCommand? {
        // Brightness: "parlaklığı artır", "ekranı biraz karart", "parlaklığı yüzde 50 yap".
        if matches(text, #"parlaklı|parlak|^arlaklı|ekranı karart|ekranı aydınlat"#) {
            if let level = percent(in: text) { return .brightness(up: true, level: level) }
            if matches(text, #"sonuna kadar|en yüksek|maksimum|full|tam"#) { return .brightness(up: true, level: 100) }
            if matches(text, #"en düşük|minimum"#) { return .brightness(up: false, level: 0) }
            if matches(text, downVerb) { return .brightness(up: false, level: nil) }
            if matches(text, upVerb) { return .brightness(up: true, level: nil) }
            return nil
        }
        // Dark mode: "karanlık modu aç", "koyu temaya geç", "aydınlık modu aç" (= dark off).
        if matches(text, #"(?:karanlık|koyu|dark|gece) (?:mod|tema|görünüm)"#) {
            if matches(text, #"kapat|kapa|devre dışı"#) { return .darkMode(on: false) }
            if matches(text, #"\baç|geç|etkinleştir|yap"#) { return .darkMode(on: true) }
        }
        if matches(text, #"(?:aydınlık|açık|light) (?:mod|tema|görünüm)"#),
           matches(text, #"\baç|geç|etkinleştir|yap"#) { return .darkMode(on: false) }
        if matches(text, #"(?:ekranı|bilgisayarı|mac'?i|makineyi) kilitl[ei]|^kilitle$|lock (?:the )?screen"#) { return .lockScreen }
        if matches(text, #"^ekranı (?:kapat|kapa|söndür|uyut)"#) { return .displaySleep }
        if matches(text, #"(?:bilgisayarı|mac'?i|makineyi|sistemi) (?:uyut|uykuya al|uyku moduna al)|^uyku moduna (?:geç|al)$"#) { return .sleep }
        if matches(text, #"ekran koruyucu"#), !matches(text, #"kapat"#) { return .screenSaver }
        if matches(text, #"ekran (?:görüntüsü|resmi)|screenshot|ekranı kaydet$"#) { return .screenshot }
        // Mute only; "sesi aç / kıs / 40 yap" is a volume level and stays with SpotifyManager.
        if matches(text, #"^(?:sessize al|sesi (?:kapat|kapa|sustur|tamamen kapat)|sustur)$"#) { return .mute(true) }
        if matches(text, #"^(?:sessizden çıkar|sesi geri aç|sessizi kapat|sessiz modu kapat)$"#) { return .mute(false) }
        return nil
    }

    /// "Safari'yi aç", "Chrome'u kapat", "Notlar uygulamasını aç".
    private static func parseApp(_ text: String, installedApps: [String]) -> SystemCommand? {
        guard !installedApps.isEmpty,
              let match = text.range(of: #"^(.+?)\s+(?:uygulamasını\s+|programını\s+)?(aç|başlat|kapat|kapa|çık)$"#, options: .regularExpression)
        else { return nil }
        let phrase = String(text[match])
        let parts = phrase.split(separator: " ")
        guard let verb = parts.last else { return nil }
        let nameWords = parts.dropLast().filter { $0 != "uygulamasını" && $0 != "programını" }
        guard !nameWords.isEmpty else { return nil }
        let spoken = nameWords.joined(separator: " ")
        guard let app = resolveApp(spoken, in: installedApps) else { return nil }
        let quit = verb == "kapat" || verb == "kapa" || verb == "çık"
        return quit ? .quitApp(app) : .openApp(app)
    }

    /// Matches a spoken app name ("safari'yi", "chromeu", "vs code'u") to an installed app.
    static func resolveApp(_ spoken: String, in apps: [String]) -> String? {
        resolveName(spoken, in: apps.filter { !appsHandledElsewhere.contains(fold($0)) })
    }

    /// Matches a spoken name, possibly with a Turkish case ending, to one of `names`.
    static func resolveName(_ spoken: String, in names: [String]) -> String? {
        let base = fold(spoken.components(separatedBy: CharacterSet(charactersIn: "'’`")).first ?? spoken)
        // Turkish accusative/dative endings Whisper glues on when it drops the apostrophe.
        var candidates = [base]
        for suffix in ["yı", "yi", "yu", "yü", "nı", "ni", "nu", "nü", "ı", "i", "u", "ü", "ya", "ye", "a", "e"].map(fold)
        where base.hasSuffix(suffix) && base.count > suffix.count + 2 {
            candidates.append(String(base.dropLast(suffix.count)))
        }
        let folded = names.map { (name: $0, key: fold($0)) }
        for candidate in candidates {
            if let exact = folded.first(where: { $0.key == candidate }) { return exact.name }
        }
        for candidate in candidates where candidate.count >= 4 {
            // "chrome" → "Google Chrome", "code" → "Visual Studio Code".
            if let word = folded.first(where: { $0.key.split(separator: " ").contains(Substring(candidate)) }) { return word.name }
            if let close = folded.first(where: { WakeWordVerifier.editDistance($0.key, candidate) <= 1 }) { return close.name }
        }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.lowercased(with: locale)
            .folding(options: .diacriticInsensitive, locale: locale)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "50", "yüzde elli", "yüzde yetmiş beş", "yüzde yüz".
    private static func percent(in text: String) -> Int? {
        if let range = text.range(of: #"\d{1,3}"#, options: .regularExpression),
           let value = Int(text[range]), (0...100).contains(value) { return value }
        guard let yuzde = text.range(of: "yüzde ") else { return nil }
        let tens = ["on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60, "yetmiş": 70, "seksen": 80, "doksan": 90, "yüz": 100]
        let units = ["sıfır": 0, "bir": 1, "iki": 2, "üç": 3, "dört": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9]
        var value: Int?
        for word in text[yuzde.upperBound...].split(separator: " ").map(String.init) {
            if let ten = tens[word], value == nil { value = ten; continue }
            if let unit = units[word] { value = (value ?? 0) + unit }
            break
        }
        return value.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
