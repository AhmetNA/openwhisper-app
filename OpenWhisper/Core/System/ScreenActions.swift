import AppKit
import ApplicationServices

/// Something in the front window that can be pressed, selected or focused.
struct ScreenElement: @unchecked Sendable {
    let element: AXUIElement
    let role: String
    let label: String
    /// "sağ üst", "orta", "sol alt"…: where it sits in the window, for "sağ üstteki çarpı".
    let region: String
    /// In a sheet or dialog, which usually is what the user is answering.
    let inDialog: Bool

    var kind: String {
        switch role {
        case "AXLink": "bağlantı"
        case "AXCheckBox": "onay kutusu"
        case "AXRadioButton": "seçenek"
        case "AXPopUpButton", "AXMenuButton", "AXComboBox": "açılır menü"
        case "AXMenuItem": "menü öğesi"
        case "AXTextField", "AXTextArea", "AXSearchField": "yazı alanı"
        case "AXRow", "AXCell": "liste öğesi"
        case "AXTab": "sekme"
        default: "düğme"
        }
    }

    /// "düğmesine", "bağlantısına": for "… basayım mı?".
    var kindDative: String {
        switch kind {
        case "bağlantı": "bağlantısına"
        case "onay kutusu": "onay kutusuna"
        case "seçenek": "seçeneğine"
        case "açılır menü": "açılır menüye"
        case "menü öğesi": "menü öğesine"
        case "yazı alanı": "yazı alanına"
        case "liste öğesi": "liste öğesine"
        case "sekme": "sekmesine"
        default: "düğmesine"
        }
    }

    var isTextField: Bool { ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) }
}

/// "Kaydet", "izin ver", "sağ üstteki çarpıya bas", "ikinci videoyu aç": an on-screen element
/// named the way one would to a friend. A label said as it is written is pressed at once; any
/// other wording goes to the model with the list of what is on screen, and it answers with one
/// element or none (then the transcript goes on as usual: Spotify, dictation or chat).
enum ScreenActions {
    private static let locale = Locale(identifier: "tr_TR")

    // MARK: - Reading the window

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXDisclosureTriangle", "AXTab", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXRow",
    ]

    /// What can be acted on in `app`'s front window, top to bottom; at most `limit`.
    static func elements(of app: NSRunningApplication, limit: Int = 150) -> [ScreenElement] {
        guard let window = ScreenReader.focusedWindow(of: app), let windowFrame = frame(of: window) else { return [] }
        let windowIsDialog = ["AXDialog", "AXSystemDialog"].contains(ScreenReader.string(window, kAXSubroleAttribute) ?? "")
        let deadline = Date().addingTimeInterval(1.5)
        var found: [ScreenElement] = []
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int, inDialog: Bool) {
            guard found.count < limit, visited < 5000, depth < 50, Date() < deadline else { return }
            visited += 1
            let role = ScreenReader.string(node, kAXRoleAttribute) ?? ""
            let inDialog = inDialog || role == "AXSheet"
            let control = actionableRoles.contains(role)
            // Electron puts a whole window's content under one press-able AXGroup (Claude: 16
            // nodes read, "New" never seen, its children's texts pressed as one "button"). Such a
            // container counts only by its own name, and the walk always goes inside it.
            let pressOnly = !control && role != "AXWindow" && hasPress(node)
            if control || pressOnly,
               isEnabled(node), let elementFrame = frame(of: node), elementFrame.width > 1, elementFrame.height > 1,
               windowFrame.intersects(elementFrame), let label = control ? label(of: node, role: role) : ownLabel(of: node) {
                found.append(ScreenElement(element: node, role: role, label: label,
                                           region: region(of: elementFrame, in: windowFrame), inDialog: inDialog))
                // A row's label already holds its texts; its buttons still count.
                if control && role != "AXRow" && role != "AXLink" { return }
            }
            for child in ScreenReader.children(node) { walk(child, depth: depth + 1, inDialog: inDialog) }
        }
        walk(window, depth: 0, inDialog: windowIsDialog)
        // An Electron app asked for its tree a moment ago may still be building it.
        if visited < 30, ScreenReader.isElectron(app) {
            Thread.sleep(forTimeInterval: 0.4)
            found = []
            visited = 0
            walk(window, depth: 0, inDialog: windowIsDialog)
        }
        owLog("[Screen] \(found.count) elements in \(app.localizedName ?? "?") (\(visited) nodes)")
        return found
    }

    private static func label(of node: AXUIElement, role: String) -> String? {
        var candidates = [kAXTitleAttribute, kAXDescriptionAttribute]
        if ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
            candidates.append("AXPlaceholderValue")
        } else {
            candidates.append(kAXValueAttribute)
        }
        candidates.append(kAXHelpAttribute)
        for attribute in candidates {
            if let text = ScreenReader.string(node, attribute).map(flat), !text.isEmpty { return String(text.prefix(80)) }
        }
        // Rows and web buttons often carry their name in a child text.
        var texts: [String] = []
        func collect(_ node: AXUIElement, depth: Int) {
            guard depth < 4, texts.count < 3 else { return }
            for child in ScreenReader.children(node) {
                if let text = ScreenReader.string(child, kAXValueAttribute) ?? ScreenReader.string(child, kAXTitleAttribute) ?? ScreenReader.string(child, kAXDescriptionAttribute) {
                    let text = flat(text)
                    if !text.isEmpty { texts.append(text) }
                }
                collect(child, depth: depth + 1)
            }
        }
        collect(node, depth: 0)
        let joined = texts.joined(separator: " · ")
        return joined.isEmpty ? nil : String(joined.prefix(80))
    }

    private static func ownLabel(of node: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let text = ScreenReader.string(node, attribute).map(flat), !text.isEmpty { return String(text.prefix(80)) }
        }
        return nil
    }

    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func hasPress(_ node: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(node, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(kAXPressAction)
    }

    private static func isEnabled(_ node: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXEnabledAttribute as CFString, &value) == .success else { return true }
        return (value as? Bool) ?? true
    }

    private static func frame(of node: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    static func region(of element: CGRect, in window: CGRect) -> String {
        let x = (element.midX - window.minX) / max(window.width, 1)
        let y = (element.midY - window.minY) / max(window.height, 1)
        let column = x < 0.33 ? "sol" : x > 0.67 ? "sağ" : ""
        let row = y < 0.25 ? "üst" : y > 0.75 ? "alt" : ""
        let place = [column, row].filter { !$0.isEmpty }.joined(separator: " ")
        return place.isEmpty ? "orta" : place
    }

    // MARK: - Matching what was said

    /// Words around the name: "Kaydet'e tıklar mısın", "şu gönder butonuna bas lütfen".
    private static let fillers: Set<String> = [
        "jarvis", "hey", "lütfen", "şuna", "şunu", "buna", "bunu", "şu", "bu", "bir", "hadi",
        "butonuna", "butona", "butonu", "buton", "düğmesine", "düğmeye", "düğmesi", "düğme", "tuşuna", "tuşu",
        "linkine", "linke", "bağlantısına", "bağlantıya", "seçeneğine", "seçeneği", "sekmesine", "sekmesi",
        "tıkla", "tıklar", "tıklayın", "tıklayabilir", "tıklasana", "bas", "basar", "basabilir", "basın", "bassana",
        "mısın", "misin", "musun", "müsün", "mısınız", "misiniz",
    ]
    /// Words that say "the screen" without naming anything on it.
    private static let screenWords: Set<String> = [
        "tıkla", "tıklar", "tıklayın", "bas", "basar", "basın", "seç", "seçer", "işaretle", "onayla", "iptal", "kapat",
        "aç", "gir", "git", "buton", "butonuna", "butonu", "düğme", "düğmesine", "link", "linke", "linkine", "bağlantı",
        "menü", "menüyü", "sekme", "sekmeye", "kutucuğu", "kutuyu", "çarpı", "çarpıya", "sağ", "sağdaki", "sol",
        "soldaki", "üst", "üstteki", "alt", "alttaki", "ortadaki", "ilk", "ilkine", "ikinci", "ikinciye", "üçüncü",
        "sonuncu", "sonuncuya", "mavi", "kırmızı", "yeşil", "aşağıdaki", "yukarıdaki", "ekrandaki", "pencerede",
    ]
    private static let caseEndings = ["'ye", "'ya", "'yi", "'yı", "'yu", "'yü", "'e", "'a", "'i", "'ı", "'u", "'ü",
                                      "ye", "ya", "yi", "yı", "yu", "yü", "e", "a", "i", "ı", "u", "ü"]

    /// The name the user said, without the verb, the filler and the case ending's apostrophe.
    static func spokenName(_ text: String) -> String {
        let words = normalized(text).split(separator: " ").map(String.init).filter { !fillers.contains($0) }
        return words.joined(separator: " ")
    }

    /// "… tıkla", "… butonuna bas": clicking said outright, the only way in from a text field.
    static func saysClick(_ text: String) -> Bool {
        let words = normalized(text).replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        return words.contains { $0.hasPrefix("tıkla") || $0.hasPrefix("butonu") || $0.hasPrefix("butona") || $0.hasPrefix("düğme") }
            || words.last.map { ["bas", "basar", "basın", "bassana"].contains($0) } ?? false
    }

    /// Whether reading the window is worth it at all: short enough to be a name, or talking
    /// about the screen. A question to Jarvis ("yarın hava nasıl olacak?") skips the read.
    static func worthLooking(_ text: String) -> Bool {
        let words = normalized(text).replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 14 else { return false }
        if words.contains(where: screenWords.contains) { return true }
        return words.count <= 5 && !JarvisAddressee.looksLikeQuestion(text)
    }

    /// Labels said exactly: "Kaydet", "kaydet'e bas", "izin ver", "Tamam'a tıkla".
    static func exactMatches(_ text: String, labels: [String]) -> [Int] {
        let said = spokenName(text)
        guard !said.isEmpty else { return [] }
        var forms = [said]
        for ending in caseEndings where said.hasSuffix(ending) && said.count > ending.count + 1 {
            forms.append(String(said.dropLast(ending.count)).replacingOccurrences(of: "'", with: ""))
        }
        forms = forms.map { $0.replacingOccurrences(of: "'", with: "") }
        return labels.indices.filter { forms.contains(normalized(labels[$0])) }
    }

    /// The name said, in its forms with and without a case ending.
    private static func nameForms(_ text: String) -> [String] {
        let said = spokenName(text)
        guard !said.isEmpty else { return [] }
        var forms = [said]
        for ending in caseEndings where said.hasSuffix(ending) && said.count > ending.count + 1 {
            forms.append(String(said.dropLast(ending.count)))
        }
        return forms.map { $0.replacingOccurrences(of: "'", with: "") }
    }

    /// A word as it sounds, so an English label matches Whisper's Turkish spelling of it:
    /// "Niv"/"Nyu" → "New", "Sent" → "Send", "Kensıl" → "Cancel".
    static func soundKey(_ text: String) -> String {
        var key = normalized(text).replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
        for (from, to) in [("ph", "f"), ("th", "t"), ("ck", "k"), ("x", "ks"), ("w", "v"), ("q", "k"), ("c", "k")] {
            key = key.replacingOccurrences(of: from, with: to)
        }
        let letters: [Character: Character] = ["ı": "i", "e": "i", "y": "i", "ö": "u", "ü": "u", "o": "u", "ş": "s", "ç": "c", "ğ": "g", "j": "c"]
        var out = ""
        for character in key {
            let mapped = letters[character] ?? character
            if out.last != mapped { out.append(mapped) }
        }
        return out
    }

    /// Labels that sound like the name said ("Niv tuşuna bas" → "New"), closest first. Only
    /// short labels, and only the closest ones: the list is what is on screen, nothing more.
    static func soundAlikeMatches(_ text: String, labels: [String]) -> [Int] {
        let keys = nameForms(text).map(soundKey).filter { $0.count >= 3 }
        guard !keys.isEmpty else { return [] }
        var best = Int.max
        var matches: [Int] = []
        for index in labels.indices where normalized(labels[index]).split(separator: " ").count <= 3 {
            let label = soundKey(labels[index])
            guard label.count >= 3 else { continue }
            let distance = keys.map { editDistance($0, label) }.min() ?? Int.max
            guard distance <= (min(label.count, 5) <= 4 ? 1 : 2) else { continue }
            if distance < best { best = distance; matches = [index] } else if distance == best { matches.append(index) }
        }
        return matches
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = current
            }
        }
        return row[b.count]
    }

    /// Turkish names of common English labels, so a model's pick can be checked against them.
    private static let labelTranslations: [String: [String]] = [
        "yeni": ["new"], "gönder": ["send", "submit"], "iptal": ["cancel"], "vazgeç": ["cancel"],
        "kaydet": ["save"], "kapat": ["close"], "çarpı": ["close"], "aç": ["open"], "devam": ["continue", "next"],
        "tamam": ["ok", "done"], "bitti": ["done"], "sil": ["delete", "remove"], "düzenle": ["edit"],
        "paylaş": ["share"], "ara": ["search", "find"], "ayar": ["settings", "preferences"], "geri": ["back"],
        "ileri": ["forward", "next"], "sonraki": ["next"], "önceki": ["previous", "back"], "izin": ["allow"],
        "reddet": ["deny", "decline", "reject"], "kopyala": ["copy"], "yapıştır": ["paste"], "indir": ["download"],
        "yükle": ["upload", "install"], "yenile": ["refresh", "reload"], "onayla": ["confirm", "approve"],
        "kabul": ["accept", "agree"], "giriş": ["sign in", "log in", "login"], "çıkış": ["sign out", "log out", "logout"],
        "durdur": ["stop", "pause"], "oynat": ["play"], "başlat": ["start", "play"], "atla": ["skip"],
        "evet": ["yes"], "hayır": ["no"], "güncelle": ["update"], "ekle": ["add"], "tekrar": ["retry"],
    ]

    /// Whether the model's pick is tied to what was said: a shared word or stem, a sound-alike,
    /// a known translation, or a request by place or order ("sağ üstteki", "ikinci"). Stops a
    /// misheard name ("Nil tuşuna bas") from pressing whatever the model guessed.
    static func isGrounded(_ text: String, label: String) -> Bool {
        let words = normalized(text).replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        if words.contains(where: placeWords.contains) { return true }
        let said = words.filter { !fillers.contains($0) && $0.count >= 2 }
        let labelText = normalized(label)
        let labelWords = labelText.replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        return said.contains { word in
            labelWords.contains { other in
                word == other || (min(word.count, other.count) >= 4 && word.prefix(4) == other.prefix(4))
                    || (word.count >= 3 && other.count >= 3 && editDistance(soundKey(word), soundKey(other)) <= 1)
            } || labelTranslations.contains { turkish, english in
                word.hasPrefix(turkish) && english.contains { labelText.contains($0) }
            }
        }
    }

    private static let placeWords: Set<String> = [
        "sağ", "sağdaki", "sol", "soldaki", "üst", "üstteki", "alt", "alttaki", "ortadaki", "ilk", "ilkine", "ikinci",
        "ikinciye", "üçüncü", "dördüncü", "sonuncu", "sonuncuya", "son", "mavi", "kırmızı", "yeşil", "aşağıdaki",
        "yukarıdaki",
    ]

    /// Whether the model should look at the screen: the words name something there, or talk
    /// about clicking, a place or an order. Plain chat ("bugün hava nasıl") never pays for it.
    static func mayBeAboutScreen(_ text: String, labels: [String]) -> Bool {
        let words = normalized(text).replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 14 else { return false }
        if words.contains(where: screenWords.contains) { return true }
        let labelWords = Set(labels.flatMap { normalized($0).replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init) }
            .filter { $0.count >= 3 })
        return words.contains { word in
            word.count >= 3 && !fillers.contains(word) && labelWords.contains { label in
                label == word || (min(label.count, word.count) >= 4 && (label.hasPrefix(word.prefix(4)) && word.hasPrefix(label.prefix(4))))
            }
        }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased(with: locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    // MARK: - The model's pick

    static func prompt(for text: String, elements: [ScreenElement]) -> String {
        let list = elements.enumerated().map { index, element in
            "\(index + 1). \(element.kind) \"\(element.label)\" (\(element.region)\(element.inDialog ? ", iletişim kutusunda" : ""))"
        }.joined(separator: "\n")
        return """
            Bir Mac'te sesli asistansın. Öndeki pencerede şu öğeler var (numara, tür, ad, konum):
            \(list)

            Kullanıcı şunu söyledi: "\(text)"

            Kullanıcı bu öğelerden birine tıklanmasını, basılmasını, seçilmesini ya da yazı alanına \
            geçilmesini istiyorsa yalnızca o öğenin numarasını yaz. Adı başka dilde olabilir \
            ("izin ver" → "Allow", "kaydet" → "Save"). İstek ekrandaki bir öğeyle ilgili değilse, \
            bir soru ya da sohbetse veya hangisi olduğu belli değilse yalnızca YOK yaz. Açıklama yazma.
            """
    }

    /// The model's answer: an element's index, or nil for "YOK" or anything else.
    static func parsePick(_ answer: String, count: Int) -> Int? {
        guard let match = answer.range(of: #"\d+"#, options: .regularExpression),
              let number = Int(answer[match]), number >= 1, number <= count else { return nil }
        return number - 1
    }

    static func modelPick(_ text: String, elements: [ScreenElement]) async -> Int? {
        let request = LLMRequest(model: LLM.selectedModel, prompt: prompt(for: text, elements: elements),
                                 timeout: 8, temperature: 0, maxTokens: 8, stop: ["\n"])
        let started = Date()
        guard let answer = try? await LLM.default.generate(request) else {
            owLog("[Screen] Model unavailable")
            return nil
        }
        let pick = parsePick(answer, count: elements.count)
        owLog("[Screen] Model answered '\(answer.trimmingCharacters(in: .whitespacesAndNewlines))' in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return pick
    }

    // MARK: - Acting

    /// Labels whose press is hard to undo: Jarvis asks before pressing them.
    static func isRisky(_ label: String) -> Bool {
        let text = " " + normalized(label) + " "
        let risky = [
            " sil", "silin", " delete", "kaldır", " remove", "gönder", " send", "satın", " buy", "purchase", " öde",
            " pay ", "ödeme", "payment", "sipariş", " order", "çıkış", "oturumu kapat", "sign out", "log out", "logout",
            "boşalt", " empty", "kaydetme", "don't save", "dont save", "değişiklikleri at", "discard", "yayınla", "publish",
            " post ", "paylaş", " share", "abonelik", "unsubscribe", "transfer", "onayla", "confirm", " erase", "sıfırla",
            " reset", "biçimlendir", " format", "yükle", " install",
        ]
        return risky.contains { text.contains($0) }
    }

    /// The answer to "… basayım mı?": true / false, nil when it is no answer (a new request).
    static func confirmation(_ text: String) -> Bool? {
        let answer = normalized(text).split(separator: " ").filter { !["jarvis", "lütfen", "efendim"].contains($0) }.joined(separator: " ")
        if ["hayır", "basma", "iptal", "iptal et", "vazgeç", "vazgeçtim", "dur", "yok", "olmaz", "boş ver", "istemiyorum", "gerek yok"].contains(answer) {
            return false
        }
        if ["evet", "evet bas", "bas", "tamam", "olur", "evet olur", "onayla", "tabii", "aynen", "devam et", "yap", "evet yap", "basabilirsin"].contains(answer) {
            return true
        }
        return nil
    }

    /// Presses, selects or focuses the element; false when the app refused.
    @discardableResult
    static func perform(_ target: ScreenElement) -> Bool {
        let node = target.element
        if target.isTextField {
            let focused = AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            owLog("[Screen] Focus '\(target.label)': \(focused)")
            return focused
        }
        if AXUIElementPerformAction(node, kAXPressAction as CFString) == .success {
            owLog("[Screen] Pressed '\(target.label)'")
            return true
        }
        if target.role == "AXRow",
           AXUIElementSetAttributeValue(node, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            owLog("[Screen] Selected row '\(target.label)'")
            return true
        }
        guard let frame = frame(of: node) else { return false }
        owLog("[Screen] Press refused; clicking '\(target.label)'")
        return click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    private static func click(at point: CGPoint) -> Bool {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}
