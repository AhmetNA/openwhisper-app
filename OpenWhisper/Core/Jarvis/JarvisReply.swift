import Foundation

/// What Jarvis says back after a voice command: short and butler-like. Questions ("saat kaç?")
/// get their answer; every action he takes on the computer gets a one-word ack; failures say
/// why. Plain dictation gets nothing. Nothing narrates what Spotify is doing, the ack is enough.
/// Now and then the user is addressed as "patron" / "efendim" / "sör", never twice in a row.
struct JarvisReply {
    private var rng: any RandomNumberGenerator
    private var addressedLastTime = false
    /// The variant said last per category, so the same one ("Tamamdır.") never comes twice in a row.
    private var lastPick: [String: String] = [:]
    /// Share of replies that address the user.
    var addressChance: Double = 0.3

    init(rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.rng = rng
    }

    static let acks = ["Tamamdır.", "Hallettim.", "Hemen.", "Oldu.", "Anlaşıldı.", "Tamam.",
                       "Derhal.", "Emredersiniz.", "Başüstüne.", "Elbette.", "Hemen hallediyorum."]
    static let addresses = ["patron", "efendim", "sör"]
    /// Replies that repeat word for word, by category, with the variants one is picked from.
    /// All are pre-synthesized into `tts-cache/<voice>/<category>/`, so they play at once.
    static let phrases: [(category: String, variants: [String])] = [
        ("onay", acks),
        ("gonderme", ["Gönderdim.", "İlettim.", "Yolladım.", "Mesaj gitti."]),
        ("yazma", ["Yazdım.", "Yazdım, göndermedim.", "Metni yazdım."]),
        ("oturum", ["Yeni session açtım.", "Yeni sohbet açtım.", "Yeni session hazır."]),
        ("gecis", ["Cevabı gelen sohbete geçtim.", "Biten sohbete geçtim.", "Cevap gelen sohbeti açtım."]),
        ("not", ["Not ettim.", "Aklımda tutuyorum.", "Not ettim, unutmam.", "Hafızama ekledim."]),
        ("unutma", ["Unuttum.", "Hafızamdan çıkardım.", "Artık hatırlamıyorum."]),
        ("hatirlatici", ["Hatırlatıcıyı sildim.", "Hatırlatıcı silindi."]),
        ("muzik", ["Beğenilen şarkılar açılıyor.", "Beğendiğiniz şarkıları açıyorum."]),
        ("hal", ["Gayet iyiyim, sizin için buradayım.", "Her zamanki gibi tetikteyim.",
                 "Sistemler sorunsuz çalışıyor, teşekkürler."]),
        ("ayar", ["Sesle uyandırmayı kapattım."]),
    ]
    /// Every phrase outside `acks`.
    static let fixedPhrases = phrases.filter { $0.category != "onay" }.flatMap(\.variants)

    /// The `phrases` category of a reply, with or without the address; "diger" for any other.
    static func category(of reply: String) -> String {
        var body = reply
        for who in addresses { body = body.replacingOccurrences(of: ", \(who).", with: ".") }
        return phrases.first { $0.variants.contains(body) }?.category ?? "diger"
    }

    /// Endings of `SystemController` statuses that mean it didn't work: "değiştirilemedi",
    /// "çalıştırılamadı", "bulunamadı", "Bağlı kulaklık yok".
    private static let failureMarkers = ["emedi", "amadı", " yok"]
    /// The same in English statuses: "Couldn't change the brightness", "Safari not found", "No headset connected".
    private static let englishFailureMarkers = ["couldn't", "can't", "not found", " no ", "didn't"]

    // MARK: - Per route

    /// nil = stay silent (the Mac is going to sleep, sound is muted, …).
    mutating func system(_ command: SystemCommand, status: String) -> String? {
        switch command {
        case .mute(true), .sleep, .displaySleep, .lockScreen, .screenSaver:
            return nil
        case .time, .battery, .mailCount, .mailCheck, .mailLatest, .mailReadUnread, .mailOpen, .briefing,
             .mailReadLatest, .mailFrom, .mailReplyDraft, .mailAttachment, .mailConversation, .agentChatHistory, .whatsAppUnread, .whatsAppFrom,
             .whatsAppConversation, .whatsAppSearch:
            return answer(Self.speakable(Self.shortened(status, for: command)))
        case .disableWakeWord:
            return Self.isFailure(status) ? failure(Self.speakable(status)) : answer(L("Sesle uyandırmayı kapattım.", "Voice wake-up is off."))
        case .unlockRequest:
            return answer(Self.speakable(status))
        case .displayWake:
            return Self.isFailure(status) ? failure(Self.speakable(status)) : ack()
        case .calendarEvent:
            // Say the date and time back, so a wrong hour is caught right away.
            if Self.isFailure(status) { return failure(Self.speakable(status)) }
            return answer(Self.speakable(status.replacingOccurrences(of: "Takvime eklendi:", with: "Takvime ekledim:")
                .replacingOccurrences(of: "Added to the calendar:", with: "I added to the calendar:")))
        case .browser(let action):
            // A summary or a search query may contain "yok"; only the fixed statuses are failures.
            if BrowserController.failures.contains(status) || YouTubeList.failures.contains(status) {
                return failure(Self.speakable(status))
            }
            if case .youtubeTitle = action, status.hasPrefix(FileFinder.openingPrefix) { return answer(status) }
            if YouTubeList.isListing(status) { return answer(status) }
            if action == .summarize { return answer(Self.speakable(Self.shortened(status, for: command))) }
            return ack()
        case .switchToApp, .switchToAgent:
            // The switch itself is the answer; an ack would talk over a video or song the
            // next command of the chain starts.
            return Self.isFailure(status) ? failure(Self.speakable(status)) : nil
        case .video(let action):
            if status == BrowserController.youTubeNeedsVideo { return answer(status) }
            if VideoController.failures.contains(status) || VideoController.isFullscreenFailure(status) { return failure(Self.speakable(status)) }
            switch action {
            case .remaining: return answer(Self.speakable(status))
            // Pausing or silencing it: a short ack. Anything that keeps it playing stays silent,
            // so Jarvis doesn't talk over the video (as with starting a song).
            case .pause, .mute(true): return ack()
            default: return nil
            }
        case .openFile:
            // The name says which file it picked, so a wrong guess is caught at once. A file
            // name may contain "yok"; only the fixed statuses are failures.
            guard status.hasPrefix(FileFinder.openingPrefix) else { return failure(Self.speakable(status)) }
            let name = String(status.dropFirst(FileFinder.openingPrefix.count))
            return answer(L("Açıyorum: ", "Opening ") + Self.speakable((name as NSString).deletingPathExtension) + ".")
        case .window, .reading(.stop):
            // The window moving, or the voice stopping, is the answer.
            return Self.isFailure(status) ? failure(Self.speakable(status)) : nil
        case .reading:
            // The reading itself follows.
            return status.hasPrefix(SystemController.readingPrefix) || status == SystemController.readingResumed ? nil : failure(Self.speakable(status))
        default:
            if Self.isFailure(status) { return failure(Self.speakable(status)) }
            // "Safari zaten kapalı": worth saying instead of a plain ack.
            if status.lowercased(with: CommandLanguage.locale).contains(L("zaten", "already")) {
                return answer(Self.speakable(status))
            }
            return ack()
        }
    }

    /// A scene: one sentence for all of its steps, naming the ones that didn't work.
    mutating func scene(_ name: String, failed: [String]) -> String {
        guard !failed.isEmpty else { return addressing(L("\(name) hazır.", "\(name) is ready.")) }
        return answer(L("\(name) hazır, ama şunlar olmadı: ", "\(name) is ready, but these didn't work: ") + "\(failed.joined(separator: ", ")).")
    }

    /// Spotify: a short ack, never a description of what plays. The caller holds the music
    /// back until the ack is spoken, so it doesn't talk over it. The one exception is Liked
    /// Songs started from a bare "şarkı aç": nothing was named, so he says what he put on.
    mutating func spotify(handled: Bool, likedSongs: Bool = false) -> String? {
        guard handled else { return nil }
        return likedSongs ? addressing(pick("muzik")) : ack()
    }

    /// A Spotify answer or result said as is: "Sıradaki şarkı: …", "Müzik 30 dakika sonra kapanacak".
    mutating func spotifyResult(_ message: String) -> String {
        // "Çalıyor: ♪ Sezen Aksu — Begonvil" reads without the note.
        let trimmed = message.replacingOccurrences(of: "♪", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return addressing(trimmed.hasSuffix(".") ? trimmed : trimmed + ".")
    }

    /// "Claude Code'a şunu yaz … gönder": the text went in, and was sent if asked.
    mutating func agent(sent: Bool) -> String {
        addressing(pick(sent ? "gonderme" : "yazma"))
    }

    /// "Claude Code'da yeni session aç" with nothing to write.
    mutating func newAgentSession() -> String {
        addressing(pick("oturum"))
    }

    /// "Biten sohbete geç": which chat is open now.
    mutating func finishedChat(_ title: String) -> String {
        addressing(title.isEmpty ? pick("gecis") : L("\(title) sohbetine geçtim.", "Switched to \(title)."))
    }

    /// "Bitirme projesine geç" / "Bitirme projesinde yeni session aç" with nothing to write.
    mutating func agentProject(_ name: String, isNew: Bool) -> String {
        addressing(isNew ? L("\(name) projesinde yeni session açtım.", "Opened a new session in \(name).")
                   : L("\(name) projesine geçtim.", "Switched to \(name)."))
    }

    /// `when` is the reminder's time ("bugün 15:46"), nil when it couldn't be set. Saying the
    /// time back catches a misheard one right away.
    mutating func reminder(at when: String?) -> String? {
        guard let when else { return failure(L("hatırlatıcıyı kuramadım", "I couldn't set the reminder")) }
        return answer(L("Not ettim, \(when) hatırlatırım", "Noted, I'll remind you \(when)"))
    }

    /// A reminder came due: "Patron, hatırlatma: toplantı."
    mutating func reminderDue(_ task: String) -> String {
        L("Patron, hatırlatma: ", "Sir, a reminder: ") + "\(Self.speakable(task))."
    }

    /// The status `TimerManager.perform` returned, as a sentence; a stop is a plain ack.
    mutating func timer(_ command: TimerCommandParser.Command, status: String) -> String {
        if case .stop = command { return ack() }
        return answer(Self.speakable(status))
    }

    /// "Patron, 20 dakika doldu." / "Patron, çay için süre doldu." / "Patron, alarm çalıyor."
    mutating func timerFired(label: String?, seconds: Int?) -> String {
        if let label { return L("Patron, \(label) için süre doldu.", "Sir, time is up for \(label).") }
        if let seconds { return L("Patron, \(SpokenDuration.spoken(seconds)) doldu.", "Sir, \(SpokenDuration.spoken(seconds)) are up.") }
        return L("Patron, alarm çalıyor.", "Sir, the alarm is ringing.")
    }

    mutating func reminderDeletion(_ result: ReminderManager.DeletionResult) -> String {
        switch result {
        case .confirmationRequired(let matches):
            if matches.count == 1, let name = matches.first {
                return L("\(name) hatırlatıcısını silmek üzereyim. Onaylıyor musunuz?", "I'm about to delete the reminder \(name). Do you confirm?")
            }
            let names = matches.prefix(3).joined(separator: ", ")
            return L("\(matches.count) hatırlatıcıyı silmek üzereyim: \(names). Onaylıyor musunuz?",
                     "I'm about to delete \(matches.count) reminders: \(names). Do you confirm?")
        case .deleted(let count, let appleVerified):
            if appleVerified {
                return addressing(count == 1 ? pick("hatirlatici") : L("\(count) hatırlatıcıyı sildim.", "Deleted \(count) reminders."))
            }
            return failure(L("yerel hatırlatıcıyı sildim fakat Apple Hatırlatıcılar kaydını doğrulayamadım",
                             "I deleted the local reminder but couldn't verify it in Apple Reminders"))
        case .notFound:
            return failure(L("eşleşen bir hatırlatıcı bulamadım", "I couldn't find a matching reminder"))
        case .ambiguous(let matches):
            let names = matches.prefix(3).joined(separator: ", ")
            return failure(L("birden fazla eşleşme buldum: \(names); hangisini sileceğinizi söyleyin",
                             "I found more than one match: \(names); tell me which one to delete"))
        case .cancelled:
            return L("İptal ettim. Hiçbir hatırlatıcı silinmedi.", "Cancelled. No reminder was deleted.")
        case .confirmationUnclear:
            return L("Anlayamadım. Silmemi onaylıyor musunuz? Evet ya da hayır deyin.", "I didn't catch that. Shall I delete it? Say yes or no.")
        case .notConfirmed:
            return L("Onay vermediğiniz için hiçbir hatırlatıcı silmedim.", "You didn't confirm, so I deleted nothing.")
        case .confirmationExpired:
            return L("Onay süresi doldu. Hiçbir hatırlatıcı silmedim.", "The confirmation timed out. I deleted nothing.")
        case .failed:
            return failure(L("hatırlatıcıları kontrol edemedim", "I couldn't check the reminders"))
        }
    }

    /// Several commands at once: answers and failures are all said, in order, but the acks
    /// fold into a single one ("Tamam. Tamam." would sound broken). nil when nothing is said.
    mutating func combined(_ replies: [String?]) -> String? {
        let said = replies.compactMap { $0 }
        let worded = said.filter { !Self.isAck($0) }
        if worded.isEmpty { return said.isEmpty ? nil : ack() }
        return worded.joined(separator: " ")
    }

    /// An ack from `ack()`, with or without the address.
    static func isAck(_ reply: String) -> Bool {
        category(of: reply) == "onay"
    }

    // MARK: - Building blocks

    mutating func ack() -> String {
        addressing(pick("onay"))
    }

    /// A random variant of a `phrases` category, never the one it gave last time.
    private mutating func pick(_ category: String) -> String {
        let variants = Self.phrases.first { $0.category == category }?.variants ?? []
        let fresh = variants.count > 1 ? variants.filter { $0 != lastPick[category] } : variants
        let choice = fresh[Int.random(in: 0..<fresh.count, using: &rng)]
        lastPick[category] = choice
        return choice
    }

    // MARK: - About Jarvis himself

    enum Meta: Equatable, Sendable {
        case repeatLast, help
        /// "Burada ne diyebilirim?": a few commands for the app in front.
        case whatCanISay
        /// "Ne duydun?": the last transcript, read back.
        case whatDidYouHear
        /// "Son komutu geri al".
        case undoLastCommand
    }

    static func meta(in text: String) -> Meta? {
        let locale = Locale(identifier: "tr_TR")
        var words = text.lowercased(with: locale)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        words.removeAll { ["jarvis", "hey", "patron", "pardon", "efendim", "lütfen", "bir", "daha"].contains($0) }
        switch words.joined(separator: " ") {
        case "ne dedin", "ne dediniz", "tekrar söyle", "tekrar eder misin", "tekrarla", "tekrar et",
             "söyle", "anlamadım tekrar söyle", "duymadım", "duyamadım", "duymadım tekrar söyle", "son söylediğini tekrarla":
            return words.isEmpty ? nil : .repeatLast
        case "ne yapabilirsin", "neler yapabilirsin", "sen ne yapabilirsin", "sen neler yapabilirsin",
             "neler yapabiliyorsun", "hangi komutları biliyorsun", "yardım", "yardım et", "nasıl kullanılıyorsun":
            return .help
        case "ne diyebilirim", "neler diyebilirim", "burada ne diyebilirim", "burada neler diyebilirim",
             "şimdi ne diyebilirim", "ne söyleyebilirim", "neler söyleyebilirim", "burada ne yapabilirim",
             "burada neler yapabilirim", "burada ne yapabilirsin", "burada neler yapabilirsin", "hangi komutları söyleyebilirim":
            return .whatCanISay
        case "ne duydun", "ne anladın", "beni nasıl duydun", "ne dediğimi duydun", "son ne dedim", "en son ne dedim",
             "ne dedim", "neyi duydun", "son söylediğimi oku":
            return .whatDidYouHear
        case "son komutu geri al", "son komutunu geri al", "komutu geri al", "son yaptığını geri al",
             "az önce yaptığını geri al", "yaptığını geri al", "son işlemi geri al", "son komutu iptal et":
            return .undoLastCommand
        default: return nil
        }
    }

    static var helpText: String { CommandLanguage.isEnglish ? englishHelpText : turkishHelpText }

    private static let englishHelpText = "I play music, set the volume, Wi-Fi, Bluetooth and the display, and open and switch apps. "
        + "I set timers, alarms, reminders and calendar events, give the day's briefing, and read your mail. "
        + "I search in Safari, summarize pages, control videos and write to Claude Code. "
        + "You can ask me to remember something, or just chat."

    private static let turkishHelpText = "Müzik çalarım, sesi, Wi-Fi'yi, Bluetooth'u ve ekranı ayarlarım, uygulama açıp geçiş yaparım. "
        + "Zamanlayıcı, alarm, hatırlatıcı ve takvim etkinliği kurarım, günün özetini veririm, mailleri okur, cevap taslağı hazırlarım. "
        + "Safari'de arama yapar, sayfayı özetler, videoyu yönetirim, Claude Code'a mesaj yazarım. "
        + "Bana bir şeyi hatırlamamı söyleyebilir ya da sadece sohbet edebilirsiniz."

    /// "Burada ne diyebilirim?": what fits the app in front, or the text field.
    static func whatCanISay(frontBundleID: String?, inTextField: Bool) -> String {
        if CommandLanguage.isEnglish { return englishWhatCanISay(frontBundleID: frontBundleID, inTextField: inTextField) }
        let anywhere = "Ekrandaki bir şeyi anlatman da yeter, örneğin 'kaydet' ya da 'izin ver'; 'son komutu geri al' da diyebilirsin."
        if inTextField {
            return "Söylediğini buraya yazarım. Sonra 'sil', 'son kelimeyi sil', 'Ahmed'i Ahmet yap' ya da 'enter'a bas' diyebilirsin."
        }
        switch frontBundleID {
        case "com.apple.Safari":
            return "Burada 'bu sayfayı özetle', 'YouTube'da lofi ara', 'yeni sekme aç' ya da 'geri git' diyebilirsin. " + anywhere
        case "com.spotify.client":
            return "Burada 'şarkıyı durdur', 'sonraki şarkı', 'Tarkan çal' ya da 'sesi kıs' diyebilirsin."
        case "com.apple.mail":
            return "Burada 'son maili oku', 'okunmamış mailleri oku' ya da 'bu maili özetle' diyebilirsin. " + anywhere
        case "net.whatsapp.WhatsApp", "desktop.WhatsApp":
            return "Burada 'WhatsApp'ta okunmamış var mı' ya da 'Ali'ye WhatsApp'tan yaz akşam geliyorum' diyebilirsin."
        case "com.anthropic.claudefordesktop", "com.openai.codex":
            return "Burada 'yeni session aç', 'son session'ı özetle', 'Bitirme projesine geç' ya da 'Claude'a yaz … gönder' diyebilirsin."
        default:
            return "'Safari'ye geç', 'Wi-Fi'yi kapat', '10 dakikalık zamanlayıcı kur' ya da 'bunu özetle' diyebilirsin. " + anywhere
        }
    }

    private static func englishWhatCanISay(frontBundleID: String?, inTextField: Bool) -> String {
        let anywhere = "You can also name something on screen, like 'save' or 'allow', or say 'undo that'."
        if inTextField {
            return "I type what you say here. Then you can say 'delete', 'delete the last word' or 'press enter'."
        }
        switch frontBundleID {
        case "com.apple.Safari":
            return "Here you can say 'summarize this page', 'search YouTube for lofi', 'open a new tab' or 'go back'. " + anywhere
        case "com.spotify.client":
            return "Here you can say 'pause the music', 'next song', 'play Tarkan' or 'turn the volume down'."
        case "net.whatsapp.WhatsApp", "desktop.WhatsApp":
            return "Here you can say 'send Ali a WhatsApp message saying I'm on my way'."
        case "com.anthropic.claudefordesktop", "com.openai.codex":
            return "Here you can say 'open a new session', 'switch to the finished chat' or 'tell Claude … and send it'."
        default:
            return "You can say 'switch to Safari', 'turn off Wi-Fi', 'set a 10 minute timer' or 'summarize this'. " + anywhere
        }
    }

    // MARK: - Memory

    /// "Bunu hatırla …" / "hakkımda ne biliyorsun?" / "… unut". `facts` is what is stored
    /// after the command ran; `removed` how many facts a forget took away.
    mutating func memory(_ command: UserMemoryCommand, facts: [String], removed: Int = 0) -> String {
        switch command {
        case .remember(let fact) where fact.hasPrefix(UserMemory.namePrefix):
            return L("Memnun oldum, ", "Nice to meet you, ") + "\(fact.dropFirst(UserMemory.namePrefix.count))."
        case .remember:
            return addressing(pick("not"))
        case .recall:
            guard !facts.isEmpty else { return addressing(L("Henüz bana kendinizle ilgili bir şey söylemediniz.", "You haven't told me anything about yourself yet.")) }
            let recent = facts.suffix(6).map { $0.hasSuffix(".") ? $0 : $0 + "." }
            return L("Bildiklerim şunlar: ", "Here is what I know: ") + recent.joined(separator: " ")
        case .forget:
            return removed > 0 ? addressing(pick("unutma")) :addressing(L("Bununla ilgili bir şey hatırlamıyorum.", "I don't remember anything about that."))
        case .forgetLast:
            return removed > 0 ? addressing(L("Son söylediğinizi unuttum.", "I forgot what you said last.")) : addressing(L("Hafızamda bir şey yok zaten.", "There is nothing in my memory anyway."))
        case .forgetAll:
            return addressing(L("Hafızamı temizledim.", "I cleared my memory."))
        }
    }

    /// Test mode: what happened to the answered item, then the next one to try.
    func voiceTest(_ command: VoiceTestCommand, outcome: VoiceTestOutcome) -> String {
        let done: String
        switch command {
        case .passed: done = "Geçti, listeden sildim. "
        case .failed: done = "Kaldı olarak yazdım. "
        case .skip: done = "Atladım. "
        case .start, .repeatItem, .stop: done = ""
        }
        switch outcome {
        case .next(let item, let remaining):
            let intro = command == .start ? "Test modu açık, \(remaining) madde var. " : done
            let ask = command == .start ? " Deneyince geçti ya da kaldı deyin." : " Geçti mi, kaldı mı?"
            let spoken = item.spoken.hasSuffix(".") || item.spoken.hasSuffix("?") ? item.spoken : item.spoken + "."
            return "\(intro)\(item.section): \(spoken)\(ask)"
        case .finished: return done + "Denenmemiş madde kalmadı, test modunu kapattım."
        case .todoMissing: return "TODO dosyasını bulamadım, bir şey yazmadım."
        case .itemChanged: return "Bu madde bu arada dosyada değişmiş, dokunmadım. Sıradaki için atla deyin."
        case .stopped: return "Test modunu kapattım."
        }
    }

    /// "Geçen hafta ne demiştim?" with nothing in the journal for that time.
    mutating func nothingRecalled(_ label: String) -> String {
        let when = label.prefix(1).uppercased(with: CommandLanguage.locale) + label.dropFirst()
        return addressing(L("\(when) konuştuğumuz bir şey kaydımda yok.", "I have no record of what we talked about \(label)."))
    }

    // MARK: - Greetings

    enum Greeting: Equatable, Sendable {
        case hello, goodMorning, goodDay, goodEvening, goodNight, howAreYou
    }

    /// The whole utterance is a greeting ("Günaydın", "Selam Jarvis", "Nasılsın?"); anything
    /// longer ("günaydın, müziği aç") is left to the command routes.
    static func greeting(in text: String) -> Greeting? {
        let locale = Locale(identifier: "tr_TR")
        var words = text.lowercased(with: locale)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let fillers: Set<String> = ["jarvis", "hey", "patron", "efendim", "ya", "canım", "dostum"]
        words.removeAll { fillers.contains($0) }
        switch words.joined(separator: " ") {
        case "günaydın", "günaydınlar": return .goodMorning
        case "merhaba", "selam", "selamlar", "selamün aleyküm", "selamun aleykum", "selamın aleyküm": return .hello
        case "iyi günler": return .goodDay
        case "iyi akşamlar": return .goodEvening
        case "iyi geceler": return .goodNight
        case "nasılsın", "naber", "ne haber", "nasıl gidiyor", "naber nasılsın", "selam nasılsın", "merhaba nasılsın", "günaydın nasılsın":
            return .howAreYou
        default: return nil
        }
    }

    /// A greeting answered by the clock: "günaydın" at 22:00 gets a gentle correction.
    mutating func greet(_ greeting: Greeting, hour: Int) -> String {
        if CommandLanguage.isEnglish { return englishGreet(greeting, hour: hour) }
        let fitting: String
        switch hour {
        case 5..<12: fitting = "Günaydın"
        case 12..<18: fitting = "İyi günler"
        case 18..<23: fitting = "İyi akşamlar"
        default: fitting = "İyi geceler"
        }
        switch greeting {
        case .howAreYou:
            return addressing(pick("hal"))
        case .goodNight:
            return hour >= 20 || hour < 5 ? addressing("İyi geceler, iyi dinlenin.") : addressing("Daha gün bitmedi ama iyi dinlenin.")
        case .goodMorning where !(5..<12).contains(hour):
            return hour < 5 ? addressing("Günaydın demek için biraz erken, yine de buradayım.")
                : addressing("Öğleni geçtik ama günaydın. \(fitting) demek daha doğru olur.")
        case .goodMorning, .hello, .goodDay, .goodEvening:
            let tail = choose(["Nasıl yardımcı olabilirim?", "Emrinizdeyim.", "Buradayım."])
            return "\(addressingGreeting(fitting)) \(tail)"
        }
    }

    private mutating func englishGreet(_ greeting: Greeting, hour: Int) -> String {
        let fitting: String
        switch hour {
        case 5..<12: fitting = "Good morning"
        case 12..<18: fitting = "Good afternoon"
        case 18..<23: fitting = "Good evening"
        default: fitting = "Good night"
        }
        switch greeting {
        case .howAreYou:
            return addressing(choose(["Very well, and at your service.", "Alert as always.", "All systems running smoothly, thank you."]))
        case .goodNight:
            return hour >= 20 || hour < 5 ? addressing("Good night, rest well.") : addressing("The day isn't over yet, but rest well.")
        case .goodMorning where !(5..<12).contains(hour):
            return hour < 5 ? addressing("It's a little early for good morning, but I'm here.")
                : addressing("We're past noon, but good morning. \(fitting) would be closer.")
        case .goodMorning, .hello, .goodDay, .goodEvening:
            addressedLastTime = true
            return "\(fitting), sir. " + choose(["How can I help?", "At your service.", "I'm here."])
        }
    }

    private mutating func addressingGreeting(_ word: String) -> String {
        addressedLastTime = true
        return "\(word) \(Self.addresses[Int.random(in: 0..<Self.addresses.count, using: &rng)])."
    }

    private mutating func choose(_ options: [String]) -> String {
        options[Int.random(in: 0..<options.count, using: &rng)]
    }

    mutating func answer(_ text: String) -> String {
        addressing(text.hasSuffix(".") ? text : text + ".")
    }

    mutating func failure(_ reason: String) -> String {
        addressing(L("Maalesef, ", "Sorry, ") + "\(Self.lowercasedFirst(reason)).")
    }

    /// Appends ", patron" to the sentence at `addressChance`, never on two replies in a row.
    private mutating func addressing(_ sentence: String) -> String {
        let use = !addressedLastTime && Double.random(in: 0..<1, using: &rng) < addressChance
        addressedLastTime = use
        guard use else { return sentence }
        let who = Self.addresses[Int.random(in: 0..<Self.addresses.count, using: &rng)]
        var body = sentence
        while let last = body.last, ".!".contains(last) { body.removeLast() }
        return "\(body), \(who)."
    }

    // MARK: - Text shaping

    static func isFailure(_ status: String) -> Bool {
        // A status still in Turkish counts by the Turkish markers either way.
        if CommandLanguage.isEnglish {
            let lower = " " + status.lowercased(with: CommandLanguage.locale)
            if englishFailureMarkers.contains(where: { lower.contains($0) }) { return true }
        }
        let lower = status.lowercased(with: Locale(identifier: "tr_TR"))
        return failureMarkers.contains { lower.contains($0) }
    }

    /// Keeps spoken answers short: unread mail is the count plus the first sender, the
    /// briefing its headline without the "— ilk:" tail if it is long.
    static func shortened(_ status: String, for command: SystemCommand) -> String {
        switch command {
        case .mailReadUnread:
            let items = status.components(separatedBy: " · ")
            guard items.count > 1 else { return status }
            return L("\(items.count) okunmamış mail, ilki \(items[0])", "\(items.count) unread mails, the first: \(items[0])")
        case .mailReadLatest:
            // The flow bar has more; about two sentences of the mail are enough to hear.
            guard status.count > 260 else { return status }
            let cut = status.prefix(260)
            if let end = cut.lastIndex(where: { ".!?".contains($0) }), cut.distance(from: cut.startIndex, to: end) > 80 {
                return String(cut[...end]) + L(" Devamı ekranda.", " The rest is on screen.")
            }
            return String(cut) + L("… Devamı ekranda.", "… The rest is on screen.")
        case .briefing:
            return status.count > 140 ? (status.components(separatedBy: " — ").first ?? status) : status
        case .browser(.summarize):
            // The whole summary is in the notification; two sentences are enough to hear.
            let sentences = status.components(separatedBy: ". ")
            return sentences.count > 2 ? sentences.prefix(2).joined(separator: ". ") + "." : status
        default:
            return status
        }
    }

    /// Flow-bar punctuation read aloud badly: "%80" → "yüzde 80", "—" / "·" → commas.
    static func speakable(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: #"%\s?(\d+)"#, with: L("yüzde $1", "$1 percent"), options: .regularExpression)
            .replacingOccurrences(of: #"(\d+)\s?%"#, with: L("yüzde $1", "$1 percent"), options: .regularExpression)
            .replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "·", with: ", ")
        for mark in ["“", "”", "\""] { out = out.replacingOccurrences(of: mark, with: "") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep names ("Wi-Fi", "Safari") as they are; only a plain Turkish word is lowered.
        let rest = text.dropFirst()
        let firstWord = text.prefix { !$0.isWhitespace }.dropFirst()
        // In English an apostrophe is "Couldn't", not a suffix on a name; "I" stays a capital.
        let keeps = CommandLanguage.isEnglish ? "-" : "-'’"
        if firstWord.contains(where: { $0.isUppercase || keeps.contains($0) }) { return text }
        if CommandLanguage.isEnglish, text.hasPrefix("I ") || text.hasPrefix("I'") || text == "I" { return text }
        return String(first).lowercased(with: CommandLanguage.locale) + rest
    }
}
