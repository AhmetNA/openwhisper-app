import Foundation

/// "İndirilenlerdeki son PDF'i aç", "geçen hafta düzenlediğim raporu aç" (`FileFinder`).
struct FileQuery: Equatable, Sendable {
    enum Folder: String, Sendable { case downloads, desktop, documents }
    enum Kind: String, Sendable { case pdf, word, spreadsheet, presentation, image, video, archive }
    enum Period: String, Sendable { case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth }
    var folder: Folder?
    var kind: Kind?
    /// A word of the file name as heard, without its case ending ("rapor").
    var name: String?
    var period: Period?
}

/// "Safari sola", "bunu diğer ekrana at", "pencereyi büyüt" (`WindowManager`).
struct WindowAction: Equatable, Sendable {
    enum Position: String, Sendable { case left, right, maximize, fullscreen, nextScreen }
    /// An installed app's name; nil = the frontmost app.
    var app: String?
    var position: Position
}

/// The clipboard history (`ClipboardHistory`).
enum ClipboardAction: Equatable, Sendable {
    /// "Panodaki son linki aç".
    case openLink
    /// "Az önce kopyaladığımı WhatsApp'tan Ali'ye at": the name as heard, read back before sending.
    case sendWhatsApp(String)
}

/// "Bu makaleyi oku", "devam et", "dur" (`ArticleReader`).
enum ReadingAction: Equatable, Sendable {
    case start
    case resume
    case stop
}

/// Pure parsing of the everyday commands: files, windows, scenes, the clipboard and reading
/// aloud. Gets the cleaned text of `SystemCommandParser.parseMac` (lowercased, no punctuation
/// but apostrophes, no leading "Jarvis").
enum DailyCommandParser {
    private static let locale = Locale(identifier: "tr_TR")

    static func parse(_ text: String, installedApps: [String], scenes: [String], readingPaused: Bool,
                      readingJustCut: Bool = false) -> SystemCommand? {
        guard text.split(separator: " ").count <= 10 else { return nil }
        if let reading = parseReading(text, paused: readingPaused, justCut: readingJustCut) { return .reading(reading) }
        if let clipboard = parseClipboard(text) { return .clipboard(clipboard) }
        if let scene = parseScene(text, scenes: scenes) { return .scene(scene) }
        if let window = parseWindow(text, installedApps: installedApps) { return .window(window) }
        if let file = parseFile(text) { return .openFile(file) }
        return nil
    }

    // MARK: - Reading

    /// "Bu makaleyi oku", "sayfayı sesli oku", "bunu bana oku". A bare "devam et" only while a
    /// reading was cut short a few minutes ago, a bare "dur" only in the recording that cut it:
    /// otherwise both are the music's.
    static func parseReading(_ text: String, paused: Bool, justCut: Bool = false) -> ReadingAction? {
        let page = #"(?:bu |şu )?(?:makaleyi|sayfayı|yazıyı|haberi|metni|bunu)"#
        if matches(text, #"^\#(page) (?:bana )?(?:sesli |yüksek sesle )?(?:oku|okur musun|okuyabilir misin|okumaya başla)(?: bana)?(?: lütfen)?$"#) {
            return .start
        }
        if matches(text, #"^okumaya devam(?: et)?(?: lütfen)?$|^(?:makaleyi|okumayı) sürdür$"#) { return .resume }
        if paused, matches(text, #"^(?:devam|devam et|devam eder misin|kaldığın yerden devam et)(?: lütfen)?$"#) { return .resume }
        if justCut, matches(text, #"^(?:dur|sus|yeter|tamam|okumayı (?:bırak|durdur|kes)|durdur)(?: lütfen)?$"#) { return .stop }
        return nil
    }

    // MARK: - Clipboard

    private static let copied = #"(?:(?:az önce |en son |son |demin )?kopyaladığım(?:ı| şeyi| metni| yazıyı)|panodaki(?:ni|leri| metni| yazıyı| şeyi)?|panoyu)"#

    static func parseClipboard(_ text: String) -> ClipboardAction? {
        if matches(text, #"^(?:(?:az önce |en son |son |demin )?kopyaladığım|panodaki) (?:son )?(?:link|bağlantı|adres|url)\S* (?:aç|açar mısın|safari'?de aç)(?: lütfen)?$"#) {
            return .openLink
        }
        guard let regex = try? NSRegularExpression(pattern: #"^\#(copied) (?:whats ?app\S* )?(.+?)(['’]?)(?:ya|ye|a|e) (?:whats ?app\S* )?(?:at|gönder|yolla|ilet)(?: lütfen)?$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var name = String(text[range]).trimmingCharacters(in: .whitespaces)
        // "aliye" → "ali" + "ye": without an apostrophe the y belongs to the ending after a vowel.
        if match.range(at: 2).length == 0, name.hasSuffix("y"), name.dropLast().last.map(isVowel) == true { name.removeLast() }
        let notNames: Set<String> = ["bur", "bura", "şur", "şura", "or", "ora", "ban", "san", "on", "bun", "şun", "kendim"]
        guard !name.isEmpty, name.split(separator: " ").count <= 3, !notNames.contains(name) else { return nil }
        return .sendWhatsApp(capitalized(name))
    }

    // MARK: - Scenes

    /// "Çalışma modu", "çalışma modunu aç", "akşam sahnesini başlat": a scene name from the
    /// scenes file, with or without an opening verb.
    static func parseScene(_ text: String, scenes: [String]) -> String? {
        guard !scenes.isEmpty else { return nil }
        let verb = #"(?:aç|açar mısın|başlat|başlatır mısın|geç|geçelim|etkinleştir|çalıştır)"#
        let spoken = text.replacingOccurrences(of: #"\s+\#(verb)(?: lütfen)?$"#, with: "", options: .regularExpression)
        let key = sceneKey(spoken)
        guard !key.isEmpty else { return nil }
        return scenes.first { sceneKey($0) == key }
    }

    /// "Çalışma modu" and "çalışma moduna" both → "calisma".
    static func sceneKey(_ name: String) -> String {
        fold(name).replacingOccurrences(of: #"\s+(?:mod|modu|modunu|moduna|mode|sahne|sahnesi|sahnesini|sahnesine)$"#, with: "", options: .regularExpression)
    }

    // MARK: - Windows

    private static let left = #"(?:sola|sol tarafa|sol yarıya)"#
    private static let right = #"(?:sağa|sağ tarafa|sağ yarıya)"#
    private static let otherScreen = #"(?:diğer|öbür|öteki|ikinci|başka|yandaki) (?:ekrana|monitöre)"#
    private static let maximize = #"(?:büyüt|ekranı kaplasın|ekrana yay|tam boy yap|ekranı kapla)"#
    private static let moveVerb = #"(?:at|al|koy|yasla|getir|taşı|gönder|geçir|çek)"#

    /// "Safari sola, Claude sağa" (one placement per command; the comma splits them),
    /// "Safari'yi sola al", "bunu diğer ekrana at", "pencereyi büyüt".
    static func parseWindow(_ text: String, installedApps: [String]) -> WindowAction? {
        let pattern = #"^(.+?) (\#(left)|\#(right)|\#(otherScreen)|\#(maximize))(?: \#(moveVerb))?(?:ır mısın|ar mısın)?(?: lütfen)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let targetRange = Range(match.range(at: 1), in: text),
              let whereRange = Range(match.range(at: 2), in: text) else { return nil }
        let place = String(text[whereRange])
        let position: WindowAction.Position = matches(place, "^\(left)$") ? .left
            : matches(place, "^\(right)$") ? .right
            : matches(place, "^\(otherScreen)$") ? .nextScreen : .maximize
        let target = String(text[targetRange])
        if matches(target, #"^(?:bunu|bu pencereyi|pencereyi|şu pencereyi|şunu|bu uygulamayı|uygulamayı|öndekini)$"#) {
            return WindowAction(app: nil, position: position)
        }
        let spoken = target.replacingOccurrences(of: #" (?:penceresini|uygulamasını)$"#, with: "", options: .regularExpression)
        guard let app = SystemCommandParser.resolveApp(spoken, in: installedApps) else { return nil }
        return WindowAction(app: app, position: position)
    }

    /// The app a "… tam ekran yap" names ("Claude'u tam ekran yap"), or nil for the front one.
    static func fullscreenTarget(_ text: String, installedApps: [String]) -> String? {
        let cleaned = text.lowercased(with: locale)
            .replacingOccurrences(of: #"[.,!?;:"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let range = cleaned.range(of: " tam ekran") else { return nil }
        let spoken = String(cleaned[..<range.lowerBound])
        guard !matches(spoken, #"^(?:bunu|bu pencereyi|pencereyi|şunu|video\S*|youtube\S*)$"#) else { return nil }
        return SystemCommandParser.resolveApp(spoken, in: installedApps)
    }

    // MARK: - Files

    private static let fileVerb = #"(?:aç|açar mısın|açabilir misin|göster|bul ve aç|bul)"#
    private static let participle = #"(?:düzenlediğim|indirdiğim|kaydettiğim|oluşturduğum|yazdığım|açtığım|eklediğim|aldığım|çektiğim)"#

    static func parseFile(_ text: String) -> FileQuery? {
        guard let body = group(#"^(.+?) \#(fileVerb)(?: lütfen)?$"#, in: text) else { return nil }
        var query = FileQuery()
        var rest = " " + body + " "
        func take(_ pattern: String) -> Bool {
            guard let range = rest.range(of: pattern, options: .regularExpression) else { return false }
            rest.replaceSubrange(range, with: " ")
            return true
        }
        if take(#" (?:indirilenler|downloads)\S* "#) { query.folder = .downloads }
        else if take(#" masaüstü\S* "#) { query.folder = .desktop }
        else if take(#" belgeler\S* "#) { query.folder = .documents }

        if take(#" geçen hafta\S* "#) { query.period = .lastWeek }
        else if take(#" bu hafta\S* "#) { query.period = .thisWeek }
        else if take(#" geçen ay\S* "#) { query.period = .lastMonth }
        else if take(#" bu ay\S* "#) { query.period = .thisMonth }
        else if take(#" (?:dün|dünkü) "#) { query.period = .yesterday }
        else if take(#" (?:bugün|bugünkü) "#) { query.period = .today }

        let kinds: [(String, FileQuery.Kind)] = [
            (#" pdf\S* "#, .pdf), (#" (?:word|docx?)\S* "#, .word), (#" (?:excel|tablo|xlsx?)\S* "#, .spreadsheet),
            (#" (?:sunum|powerpoint|keynote)\S* "#, .presentation),
            (#" (?:ekran görüntüsü|ekran resmi|resim|fotoğraf|görsel)\S* "#, .image),
            (#" (?:video|vidyo)\S* "#, .video), (#" (?:zip|arşiv)\S* "#, .archive),
        ]
        for (pattern, kind) in kinds where take(pattern) {
            query.kind = kind
            break
        }
        let named = take(#" (?:dosya|dosyayı|dosyasını|dosyamı|belgeyi|belgesini) "#)
        // "Son indirdiğim …" is in Downloads.
        if query.folder == nil, take(" indirdiğim ") { query.folder = .downloads }
        let edited = take(" \(participle) ")
        while take(#" (?:en|son|adlı|isimli|olan) "#) {}
        // Something must say it is a file: "raporu aç" alone could be anything.
        guard query.folder != nil || query.kind != nil || named || edited else { return nil }
        let words = rest.split(separator: " ").map(String.init)
        guard words.count <= 2 else { return nil }
        if !words.isEmpty {
            let name = stem(words.joined(separator: " "))
            guard name.count >= 2 else { return nil }
            query.name = name
        }
        return query
    }

    /// "raporu" → "rapor", "faturayı" → "fatura", "sunum'u" → "sunum".
    private static func stem(_ word: String) -> String {
        if let apostrophe = word.firstIndex(where: { "'’".contains($0) }) { return String(word[..<apostrophe]) }
        for suffix in ["yı", "yi", "yu", "yü", "nı", "ni", "nu", "nü", "ı", "i", "u", "ü"] where word.hasSuffix(suffix) && word.count > suffix.count + 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    // MARK: - Helpers

    private static func isVowel(_ c: Character) -> Bool { "aeıioöuü".contains(c) }

    private static func capitalized(_ name: String) -> String {
        name.split(separator: " ").map { $0.prefix(1).uppercased(with: locale) + $0.dropFirst() }.joined(separator: " ")
    }

    private static func fold(_ text: String) -> String {
        text.lowercased(with: locale)
            .folding(options: .diacriticInsensitive, locale: locale)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func group(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges - 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
