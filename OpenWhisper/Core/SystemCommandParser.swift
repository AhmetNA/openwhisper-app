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
    /// Scroll the content under the pointer in the frontmost app.
    case scroll(up: Bool, large: Bool)
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
    /// "Chrome'u zorla kapat / öldür": kills the app and every process that belongs to it.
    case forceQuitApp(String)
    /// "Safari'ye geç": brings the app to the front (launching it if needed) and waits until it
    /// is frontmost, so the next command of a chain ("… ve videoyu başlat") runs there.
    case switchToApp(String)
    /// "Claude Code'a geç", "ChatGPT'ye geç": the agent app, through `AgentAppActivator`.
    case switchToAgent(AgentApp)
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
    /// "Developer modu aç": opens Claude and ChatGPT/Codex, sets the volume to 40% and
    /// plays Liked Songs in Spotify (`SystemController.startDeveloperMode`).
    case developerMode
    /// "Yarın saat 3'te Mehmet'le toplantı ekle" (`CalendarEventParser`).
    case calendarEvent(CalendarEventParser.Event)
    /// Safari tabs, searches and "bu sayfayı özetle" (`BrowserController`).
    case browser(BrowserAction)
    /// The video playing in Safari: pause, seek, speed, subtitles (`VideoController`).
    case video(VideoAction)
}

enum BrowserAction: Equatable, Sendable {
    enum Engine: String, Sendable { case google, youtube }
    case newTab
    case closeTab
    case reload
    case back
    case forward
    case nextTab
    case previousTab
    /// A full URL ("https://github.com").
    case open(String)
    case search(Engine, String)
    case summarize
}

/// Pure parsing of short Turkish (and some English) commands from the raw Whisper transcript:
/// "Bluetooth'u kapat", "parlaklığı artır", "Safari'yi aç". Only a short utterance that is
/// nothing but the command counts, so dictation that mentions Wi-Fi is never executed.
/// Volume levels stay with `SpotifyManager` ("sesi 40 yap", "biraz kıs"); only muting is here.
enum SystemCommandParser {
    private static let locale = Locale(identifier: "tr_TR")
    private static let maxWords = 7

    // Whisper spellings seen for these words, after lowercasing with the Turkish locale.
    private static let bluetooth = #"(?:bluetooth|bluetoot|bluetut|blutut|blututh|blu tut|blue tooth|blotut|bulutut|bl[uü]t+el|blütut|bt)"#
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
    static func parse(_ text: String, installedApps: [String] = [], shortcuts: [String] = [], now: Date = Date()) -> SystemCommand? {
        // Dates and addresses need the raw text: cleaning turns "15:30" and "github.com" apart.
        if let event = CalendarEventParser.parse(text, now: now) { return .calendarEvent(event) }
        if let browse = parseBrowserRequest(text) { return .browser(browse) }
        if let video = parseVideoRequest(text) { return .video(video) }
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
        if isDeveloperMode(cleaned) { return .developerMode }
        // First, and with a longer limit: shortcut names are free text ("Wi-Fi ile Sabah Özeti")
        // that would otherwise read as a Wi-Fi or app command.
        if let shortcut = parseShortcut(cleaned, shortcuts: shortcuts) { return shortcut }
        guard cleaned.split(separator: " ").count <= maxWords else { return nil }
        if let briefing = parseBriefing(cleaned) { return briefing }

        if let mail = parseMail(cleaned) { return mail }
        if let query = parseQuery(cleaned) { return query }
        if let action = parseAction(cleaned) { return action }
        if let tab = parseBrowserTab(cleaned) { return .browser(tab) }
        if let target = parseSwitch(cleaned, installedApps: installedApps) { return target }

        let off = matches(cleaned, offVerb)
        let on = matches(cleaned, onVerb)
        if off != on {
            if matches(cleaned, headset) { return .headset(connect: on) }
            if matches(cleaned, bluetooth) { return .bluetooth(on: on) }
            if matches(cleaned, wifi) { return .wifi(on: on) }
        }
        return parseApp(cleaned, installedApps: installedApps)
    }

    /// "Dev modu aç", "developer modunu başlat", "geliştirici moduna geç". It opens several apps
    /// and starts music, so the whole utterance must be the command: anything longer
    /// ("developer modu açınca ne oluyor") stays dictation. Whisper often glues and bends the
    /// words ("Devmodo Aç", "Def modu aç", "dev mod'u aç"), so the spellings are loose.
    static func isDeveloperMode(_ cleaned: String) -> Bool {
        let noun = #"(?:dev|def|deb|dew|developer|developır|devoloper|divelopır|divelopir|developper|geliştirici)"#
        let mode = #"(?:mod(?:['’]?(?:u|o|ı|i|e|a|unu|onu|una|ona))?|mode['’]?(?:u|a)?)"#
        let verb = #"(?:aç|ac|açar mısın|açalım|açın|başlat|etkinleştir|aktif et|aktifleştir|geç|geçelim)"#
        return matches(cleaned, #"^\#(noun)[ -]?\#(mode) \#(verb)(?: lütfen)?$"#)
    }

    /// "Bugün ne var", "bugün neyimiz var", "programımız ne", "yarın planım ne", "günün özeti".
    private static func parseBriefing(_ text: String) -> SystemCommand? {
        let day = #"(?:bugün|bugünkü|bu gün|yarın|yarınki)"#
        // Bound the roots so a word like "toplantı" cannot match the "plan" substring.
        let ask = #"\b(?:ne var|neler var|neyim var|neyimiz var|nelerimiz var|program\w*|plan\w*|ajanda\w*|takvim\w*)\b"#
        let asksQuestion = matches(text, #"\b(?:ne|neler|nedir|neyim|neyimiz|nelerimiz|var mı)\b"#)
        let asksDay = matches(text, day) && matches(text, ask) && asksQuestion
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
        // Scroll the frontmost app: "ekranı aşağı kaydır", "sayfayı yukarı çıkar".
        // Keep this explicit so ordinary dictation containing "aşağı/yukarı" is never run.
        let scrollTarget = #"(?:ekranı|ekran|sayfayı|sayfa)"#
        // Whisper sometimes turns the imperative "kaydır" into "kaydırır".
        let scrollVerb = #"(?:kaydır(?:ır)?|kaydir(?:ir)?|indir|çıkar|cikar|scroll)"#
        // It can also drop the final r entirely. Accept that only with an explicit screen/page
        // target below, so a conversational "yukarı kaydı" can never become an action.
        let clippedScrollVerb = #"(?:kaydı|kaydi)"#
        let largeScroll = #"(?:bayağı|baya|çok|epey|iyice|oldukça)(?:\s+bir)?"#
        let isLargeScroll = matches(text, largeScroll)
        let scrollText = text
            .replacingOccurrences(of: largeScroll, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if matches(scrollText, #"^(?:\#(scrollTarget)\s+)?(?:aşağı|aşşağı|asagi|down)(?:ya)?\s+\#(scrollVerb)(?:\s+lütfen)?$"#) {
            return .scroll(up: false, large: isLargeScroll)
        }
        if matches(scrollText, #"^(?:\#(scrollTarget)\s+)?(?:yukarı|yukari|up)(?:ya)?\s+\#(scrollVerb)(?:\s+lütfen)?$"#) {
            return .scroll(up: true, large: isLargeScroll)
        }
        if matches(scrollText, #"^\#(scrollTarget)\s+\#(scrollVerb)\s+(?:aşağı|aşşağı|asagi|down)(?:ya)?(?:\s+lütfen)?$"#) {
            return .scroll(up: false, large: isLargeScroll)
        }
        if matches(scrollText, #"^\#(scrollTarget)\s+\#(scrollVerb)\s+(?:yukarı|yukari|up)(?:ya)?(?:\s+lütfen)?$"#) {
            return .scroll(up: true, large: isLargeScroll)
        }
        if matches(scrollText, #"^\#(scrollTarget)\s+(?:aşağı|aşşağı|asagi|down)(?:ya)?\s+\#(clippedScrollVerb)$"#) {
            return .scroll(up: false, large: isLargeScroll)
        }
        if matches(scrollText, #"^\#(scrollTarget)\s+(?:yukarı|yukari|up)(?:ya)?\s+\#(clippedScrollVerb)$"#) {
            return .scroll(up: true, large: isLargeScroll)
        }
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

    // MARK: - Safari

    private static let youtube = #"(?:youtube|you tube|yutub|yutup|yutyub)"#
    private static let google = #"(?:google|gugıl|gugul|internet|web)"#
    /// "…'da", "… da", "…'ta", "…te": where to search.
    private static let at = #"\s?'?(?:da|de|ta|te)"#
    private static let searchVerb = #"(?:ara|arat|aratır mısın|arar mısın|bul|aç)"#

    /// Searches and sites, from the raw text: "YouTube'da lofi ara", "Google'da hava durumu ara",
    /// "lofi müziği YouTube'da aç", "github.com'u aç", "GitHub sitesini aç". A bare
    /// "Ahmet'i ara" is a phone call and never matches.
    static func parseBrowserRequest(_ text: String) -> BrowserAction? {
        let raw = text.lowercased(with: locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[!?;"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[.,]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)[\s,]+)?(?:lütfen\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.split(separator: " ").count <= 14 else { return nil }
        let polite = #"(?: lütfen)?$"#

        for (engine, site) in [(BrowserAction.Engine.youtube, youtube), (.google, google)] {
            let place = #"(?:\#(site)\#(at)|\#(site)\s?'?(?:dan|den|tan|ten))"#
            // "YouTube'da lofi ara" / "lofi'yi YouTube'da ara" / "lofi diye google'da ara".
            if let query = group(#"^\#(place) (.+?) (?:diye )?\#(searchVerb)\#(polite)"#, in: raw)
                ?? group(#"^(.+?) (?:diye )?\#(place) \#(searchVerb)\#(polite)"#, in: raw) {
                return .search(engine, searchQuery(query))
            }
        }
        // "Kara delik nedir google'la".
        if let query = group(#"^(.+?) (?:google|gugıl)'?la\#(polite)"#, in: raw) {
            return .search(.google, searchQuery(query))
        }

        // "github.com'u aç", "eksisozluk.com'a git".
        if let host = group(#"^((?:https?://)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|dev|app|ai|co|tv|me|edu|gov|tr)(?:\.tr)?)(?:/\S*)?(?:'?\p{L}{0,3})? (?:aç|git|gir)\#(polite)"#, in: raw) {
            return .open(host.hasPrefix("http") ? host : "https://" + host)
        }
        // "GitHub sitesini aç", "YouTube sitesine git".
        if let name = group(#"^(.+?) (?:sitesini aç|sitesine git|sitesine gir|web sitesini aç)\#(polite)"#, in: raw) {
            let host = name.folding(options: .diacriticInsensitive, locale: locale)
                .replacingOccurrences(of: "ı", with: "i")
                .replacingOccurrences(of: #"[^a-z0-9.-]"#, with: "", options: .regularExpression)
            guard !host.isEmpty else { return nil }
            return .open("https://" + (host.contains(".") ? host : host + ".com"))
        }
        return nil
    }

    // MARK: - Video

    /// "videoyu", "videoya", "YouTube'u", "filmi", "diziyi". A video command needs one of
    /// these, so a bare "durdur" / "devam et" stays with Spotify.
    private static let videoNoun = #"(?:video|vidyo|film|dizi|youtube|you tube|yutub|yutup)\S*"#
    private static let numberWord = #"(?:\d+(?:[.,]\d+)?|yarım|(?:(?:on|yirmi|otuz|kırk|elli|altmış|yetmiş|seksen|doksan)(?: (?:bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz))?|bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz)(?: buçuk)?)"#
    private static let timeUnit = #"(?:saat|dakika|dk|saniye|sn)"#

    /// "Videoyu durdur", "videoya devam et", "videoyu başa sar", "10 saniye ileri sar",
    /// "videoyu 5. dakikaya al", "video hızını 1.5 yap", "altyazıyı aç", "sonraki video".
    /// From the raw text: cleaning would turn "1.5" and "5." apart.
    static func parseVideoRequest(_ text: String) -> VideoAction? {
        let raw = text.lowercased(with: locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[!?;"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[.,]\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\D)[.,](?=\s)"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)[\s,]+)?(?:lütfen\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:lütfen|hemen)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.split(separator: " ").count <= 9 else { return nil }
        let noun = videoNoun
        let lead = #"^(?:\#(noun) )?(?:bu |şu )?"#

        // Subtitles and fullscreen name themselves; no noun needed.
        if let verb = group(#"\#(lead)altyaz\S* (aç|kapat|kapa)$"#, in: raw) { return .subtitles(on: verb == "aç") }
        // "tam ekran yap", "tam ekranı yap", "tam ekran yapar mısın", "tam ekrana alır mısın".
        // Whisper often bends "yap" ("Tam ekranjap", "Tam ekran, ja") and the noun ("Safar yi
        // tam ekran yap"), so up to two leading words and those spellings count too; the
        // sentence still has to end there, so "tam ekranı yapıyorum" stays dictation.
        let fullscreenVerb = #"(?:yap(?:ar mısın|sana|ıver)?|jap|ja|yab|yapp|hap)"#
        if matches(raw, #"^(?:\S+ ){0,2}tam ekran(?:ı?[ ,]*\#(fullscreenVerb)|a (?:al|geç|geçir)(?:ır mısın|sana)?|dan çık(?:ar mısın)?)$"#) { return .fullscreen }
        if matches(raw, #"^(?:bir )?(?:sonraki|diğer) video(?:ya)?(?: (?:geç|git|aç|oynat))?$|^(?:bu |şu )?\#(noun) (?:geç|atla)$"#) { return .next }

        let hasNoun = matches(raw, #"(?:^|\s)\#(noun)"#)
        if matches(raw, #"^(?:bu |şu )?\#(noun) (?:bitmesine |sonuna )?(?:ne kadar (?:kaldı|var)|kaç dakika\S* (?:kaldı|var)|süresi ne(?: kadar)?)$"#) { return .remaining }

        if hasNoun {
            if matches(raw, #"\#(lead)(?:ses\S* (?:kapat|kapa)|sessize al|sustur)$"#) { return .mute(true) }
            if matches(raw, #"\#(lead)(?:ses\S* (?:geri )?aç|sessizden çıkar)$"#) { return .mute(false) }
        }

        // Speed: "video hızını 1.5 yap", "videoyu 2x yap", "videoyu iki kat hızlandır",
        // "normal hıza al", "videoyu hızlandır / yavaşlat".
        if matches(raw, #"\#(lead)(?:hız\S* normale? (?:al|döndür|getir|yap|çek)|normal hız\S* (?:al|dön|döndür|getir|geç|yap))$"#) { return .speed(1) }
        if let value = group(#"\#(lead)(?:hız\S* )?(\#(numberWord)) ?(?:x|kat|katı)?(?:\S*)? (?:yap|al|ayarla|hızlandır|hızda oynat)$"#, in: raw),
           hasNoun || matches(raw, #"hız"#), let rate = number(value), (0.25...3).contains(rate) {
            return .speed(rate)
        }
        if hasNoun, matches(raw, #"\#(lead)(?:biraz )?hızlandır$"#) { return .speedStep(faster: true) }
        if hasNoun, matches(raw, #"\#(lead)(?:biraz )?yavaşlat$"#) { return .speedStep(faster: false) }

        // Seeking: relative ("30 saniye ileri sar", "videoyu biraz geri al"),
        // absolute ("videonun 5. dakikasına git", "2 dakika 30 saniyeye al").
        let seekVerb = #"(?:sar|al|git|atla|götür|getir|dön|gel)"#
        if let amount = group(#"\#(lead)((?:\#(numberWord) \#(timeUnit) ?)+|biraz |)(?:kadar )?(?:ileri|geri)(?:ye|ya)? \#(seekVerb)$"#, in: raw)
            ?? (matches(raw, #"\#(lead)(?:biraz )?(?:ileri|geri)(?:ye|ya)? \#(seekVerb)$"#) && hasNoun ? "" : nil) {
            // Bare "ileri git" / "geri git" never gets here: it is Safari's history.
            let seconds = durationSeconds(amount) ?? 10
            return .seekBy(matches(raw, #"geri"#) ? -seconds : seconds)
        }
        if let target = group(#"\#(lead)(?:\#(noun) )?((?:\d+\.? \#(timeUnit)\S* ?)+)(?:ine|ına|una|üne|sine|sına|a|e|ya|ye)? \#(seekVerb)$"#, in: raw),
           target.contains("."), let seconds = durationSeconds(target.replacingOccurrences(of: ".", with: "")) {
            // An ordinal ("5. dakika") is a position; "5 dakika" without "ileri" is too vague.
            return .seekTo(seconds)
        }
        if let target = group(#"\#(lead)(?:\#(noun) )?((?:\d+ \#(timeUnit)\S* ?)+)\S* \#(seekVerb)$"#, in: raw),
           matches(target, #"(?:ya|ye|ine|ına|sine|sına)\s*$"#), let seconds = durationSeconds(target) {
            // "2 dakika 30 saniyeye al": the dative marks a position.
            return .seekTo(seconds)
        }

        if matches(raw, #"\#(lead)(?:en )?başa sar$"#)
            || (hasNoun && matches(raw, #"\#(lead)(?:en )?(?:başa (?:sar|al|dön|döndür)|başından (?:başlat|oynat|al)|baştan (?:başlat|oynat|al|izle)|sıfıra (?:al|sar|çek)|sıfırla)$"#)) {
            return .restart
        }
        guard hasNoun else { return nil }
        if matches(raw, #"\#(lead)(?:bi |bir )?(?:durdur|duraklat|beklet|dondur|pause|stop)$|^(?:durdur|duraklat) \#(noun)$"#) { return .pause }
        if matches(raw, #"\#(lead)(?:devam et|devam ettir|başlat|oynat|play|sürdür|kaldığı yerden (?:devam et|devam ettir|başlat|oynat))$|^(?:başlat|oynat|devam ettir) \#(noun)$"#) { return .play }
        return nil
    }

    /// "1 dakika 30 saniye" → 90, "yarım dakika" → 30, "bir buçuk dakika" → 90.
    static func durationSeconds(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(\#(numberWord)) (\#(timeUnit))"#) else { return nil }
        var total = 0.0
        var found = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let valueRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let value = number(String(text[valueRange])) else { continue }
            let unit = text[unitRange]
            total += value * (unit == "saat" ? 3600 : unit.hasPrefix("d") ? 60 : 1)
            found = true
        }
        return found ? Int(total.rounded()) : nil
    }

    /// "1.5", "1,5", "iki", "bir buçuk", "otuz beş", "yarım".
    static func number(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(text.replacingOccurrences(of: ",", with: ".")) { return value }
        if text == "yarım" { return 0.5 }
        let tens = ["on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60, "yetmiş": 70, "seksen": 80, "doksan": 90]
        let units = ["bir": 1, "iki": 2, "üç": 3, "dört": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9]
        var value = 0.0
        var found = false
        for word in text.split(separator: " ").map(String.init) {
            if let ten = tens[word] { value += Double(ten); found = true }
            else if let unit = units[word] { value += Double(unit); found = true }
            else if word == "buçuk", found { value += 0.5 }
            else if let digits = Double(word) { value += digits; found = true }
            else { return nil }
        }
        return found ? value : nil
    }

    /// "lofi'yi" → "lofi"; spaces stay (URL-encoding happens in `BrowserController`).
    private static func searchQuery(_ query: String) -> String {
        query.replacingOccurrences(of: #"'(?:y?[ıiuü]|n[ıiuü])$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tab and page commands, from the cleaned text: "yeni sekme aç", "sekmeyi kapat",
    /// "sayfayı yenile", "geri git", "sonraki sekme", "bu sayfayı özetle".
    private static func parseBrowserTab(_ text: String) -> BrowserAction? {
        let text = text.replacingOccurrences(of: #"^safari'?(?:de|da|yi)? "#, with: "", options: .regularExpression)
        let page = #"(?:bu |şu )?(?:sayfayı|sayfa|siteyi|makaleyi|yazıyı|sekmeyi|haberi)"#
        if matches(text, #"^\#(page) (?:özetle|özetler misin|özetleyebilir misin|özetle bana|bana özetle)(?: lütfen)?$"#)
            || matches(text, #"^(?:bu |şu )?(?:sayfa|sayfada|makale|makalede|yazı|yazıda|haber|haberde) ne (?:anlatıyor|yazıyor|diyor)$"#)
            || matches(text, #"^(?:bu |şu )?sayfanın özeti(?:ni)?(?: ver| çıkar)?$"#) { return .summarize }
        if matches(text, #"^yeni (?:bir )?sekme(?: aç| oluştur)?(?: lütfen)?$"#) { return .newTab }
        if matches(text, #"^(?:bu )?sekme(?:yi)? kapa(?:t)?(?: lütfen)?$"#) { return .closeTab }
        if matches(text, #"^(?:sayfayı |sekmeyi )?(?:yenile|yeniden yükle)(?: lütfen)?$"#) { return .reload }
        if matches(text, #"^(?:(?:bir )?önceki sayfaya (?:git|dön)|geri git|sayfada geri git)$"#) { return .back }
        if matches(text, #"^(?:(?:bir )?sonraki sayfaya git|ileri git|sayfada ileri git)$"#) { return .forward }
        if matches(text, #"^(?:bir )?(?:sonraki|sağdaki) sekme(?:ye (?:geç|git))?$"#) { return .nextTab }
        if matches(text, #"^(?:bir )?(?:önceki|soldaki) sekme(?:ye (?:geç|git|dön))?$"#) { return .previousTab }
        return nil
    }

    private static func group(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges - 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// "Safari'yi aç", "Chrome'u kapat", "Notlar uygulamasını aç",
    /// "Chrome'u zorla kapat", "Slack'i öldür", "Xcode'u kill et".
    private static func parseApp(_ text: String, installedApps: [String]) -> SystemCommand? {
        guard !installedApps.isEmpty else { return nil }
        if let command = parseAppPhrase(text, installedApps: installedApps) { return command }
        // Whisper glues the case ending onto the verb: "Saferi Yaç", "Safer iyaç" (Safari'yi aç).
        // Move it back onto the name; the buffer "y" goes.
        let unglued = text.replacingOccurrences(
            of: #"^(.+?)\s+([ıiuüyn]{1,3})(aç|başlat|kapat|kapa|öldür|sonlandır)$"#,
            with: "$1$2 $3", options: .regularExpression
        ).replacingOccurrences(of: #"y+ (\S+)$"#, with: " $1", options: .regularExpression)
        return unglued == text ? nil : parseAppPhrase(unglued, installedApps: installedApps)
    }

    private static func parseAppPhrase(_ text: String, installedApps: [String]) -> SystemCommand? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s+(?:uygulamasını\s+|programını\s+)?(zorla\s+|tamamen\s+)?(aç|başlat|kapat|kapa|çık|öldür|sonlandır|kill et|killle|kille)$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let verbRange = Range(match.range(at: 3), in: text)
        else { return nil }
        let spoken = String(text[nameRange])
        let verb = String(text[verbRange])
        let forced = match.range(at: 2).location != NSNotFound
        guard let app = resolveApp(spoken, in: installedApps) else { return nil }
        if ["aç", "başlat"].contains(verb) { return forced ? nil : .openApp(app) }
        if forced || ["öldür", "sonlandır", "kill et", "killle", "kille"].contains(verb) { return .forceQuitApp(app) }
        return .quitApp(app)
    }

    /// "Safari'ye geç", "Spotify'a geç", "Claude Code'a geç", "Xcode uygulamasına geç",
    /// "ChatGPT'ye geçer misin". Unlike "aç / kapat" Spotify counts, and the name must be an
    /// exact or one-letter match: "şarkıya geç" is two letters from "Safari" and is a skip.
    private static func parseSwitch(_ text: String, installedApps: [String]) -> SystemCommand? {
        if let command = parseSwitchPhrase(text, installedApps: installedApps) { return command }
        // Whisper glues the case ending and the verb onto the name: "Cloud Codecage"
        // (Claude Code'a geç), "Safariyege" — split them back; the name must still resolve.
        let unglued = text.replacingOccurrences(
            of: #"^(.+?)(?:y|c)?([ae])\s?ge[çc]?$"#, with: "$1'$2 geç", options: .regularExpression)
        return unglued == text ? nil : parseSwitchPhrase(unglued, installedApps: installedApps)
    }

    private static func parseSwitchPhrase(_ text: String, installedApps: [String]) -> SystemCommand? {
        guard let spoken = group(
            #"^(.+?)\s+(?:uygulamasına\s+|programına\s+)?(?:geç|geçiş yap|git|dön)(?:er misin|er mısın|sene|elim|ebilir misin)?(?: lütfen)?$"#,
            in: text
        ) else { return nil }
        if let agent = AgentCommandParser.agentApp(named: spoken) { return .switchToAgent(agent) }
        return resolveName(spoken, in: installedApps).map { .switchToApp($0) }
    }

    /// Matches a spoken app name ("safari'yi", "chromeu", "vs code'u") to an installed app.
    static func resolveApp(_ spoken: String, in apps: [String]) -> String? {
        let apps = apps.filter { !appsHandledElsewhere.contains(fold($0)) }
        // Two misheard letters ("safer" → Safari) only for names long enough not to collide.
        return resolveName(spoken, in: apps) ?? resolveName(spoken, in: apps, looseFrom: 6)
    }

    /// Matches a spoken name, possibly with a Turkish case ending, to one of `names`.
    /// `looseFrom`: names at least this long also match at edit distance 2.
    static func resolveName(_ spoken: String, in names: [String], looseFrom: Int = .max) -> String? {
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
            let close = folded
                .map { (name: $0.name, key: $0.key, distance: WakeWordVerifier.editDistance($0.key, candidate)) }
                .filter { $0.distance <= ($0.key.count >= looseFrom ? 2 : 1) }
                .min { $0.distance < $1.distance }
            if let close { return close.name }
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
