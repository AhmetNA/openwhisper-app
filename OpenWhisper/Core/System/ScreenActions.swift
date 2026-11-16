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

    private static let pressableContainers: Set<String> = ["AXGroup", "AXImage", "AXStaticText", "AXCell", "AXUnknown"]

    /// What can be acted on in `app`'s front window, top to bottom; at most `limit`.
    static func elements(of app: NSRunningApplication, limit: Int = 150) -> [ScreenElement] {
        // An open menu is all that can be acted on until it closes.
        let menuItems = openMenuItems(of: app)
        if !menuItems.isEmpty { return menuItems }
        guard let window = ScreenReader.focusedWindow(of: app), let windowFrame = frame(of: window) else { return [] }
        let windowIsDialog = ["AXDialog", "AXSystemDialog"].contains(ScreenReader.string(window, kAXSubroleAttribute) ?? "")
        let deadline = Date().addingTimeInterval(1.5)
        var found: [ScreenElement] = []
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int, inDialog: Bool) {
            guard found.count < limit, visited < 5000, depth < 50, Date() < deadline else { return }
            visited += 1
            let info = ScreenReader.node(node)
            let role = info.role
            let inDialog = inDialog || role == "AXSheet"
            let control = actionableRoles.contains(role)
            // Electron puts a whole window's content under one press-able AXGroup (Claude: 16
            // nodes read, "New" never seen, its children's texts pressed as one "button"). Such a
            // container counts only by its own name, and the walk always goes inside it. Only
            // the roles that do this are asked for their actions: one more call per node.
            let pressOnly = !control && pressableContainers.contains(role) && hasPress(node)
            if control || pressOnly,
               info.enabled, let elementFrame = info.frame, elementFrame.width > 1, elementFrame.height > 1,
               windowFrame.intersects(elementFrame), let label = control ? label(of: node, role: role) : ownLabel(of: node) {
                found.append(ScreenElement(element: node, role: role, label: label,
                                           region: region(of: elementFrame, in: windowFrame), inDialog: inDialog))
                // A row's label already holds its texts; its buttons still count.
                if control && role != "AXRow" && role != "AXLink" { return }
            }
            for child in info.children { walk(child, depth: depth + 1, inDialog: inDialog) }
        }
        walk(window, depth: 0, inDialog: windowIsDialog)
        // An Electron app asked for its tree a moment ago may still be building it.
        if visited < 30, ScreenReader.buildsTreeOnRequest(app) {
            Thread.sleep(forTimeInterval: 0.4)
            found = []
            visited = 0
            walk(window, depth: 0, inDialog: windowIsDialog)
        }
        owLog("[Screen] \(found.count) elements in \(app.localizedName ?? "?") (\(visited) nodes)")
        return found
    }

    /// The items of an open menu (a right click's): it hangs off the app or the focused
    /// element, not the front window.
    static func openMenuItems(of app: NSRunningApplication) -> [ScreenElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var parents = [root]
        if let window = ScreenReader.focusedWindow(of: app) { parents.append(window) }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            parents.append(focused as! AXUIElement)
        }
        for parent in parents {
            for child in ScreenReader.children(parent) where ScreenReader.node(child).role == "AXMenu" {
                let items = ScreenReader.children(child).compactMap { item -> ScreenElement? in
                    let info = ScreenReader.node(item)
                    guard info.role == "AXMenuItem", info.enabled, let frame = info.frame, frame.height > 1,
                          let label = ownLabel(of: item) else { return nil }
                    return ScreenElement(element: item, role: info.role, label: label, region: "orta", inDialog: true)
                }
                if !items.isEmpty { return items }
            }
        }
        return []
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
    private static var fillers: Set<String> { CommandLanguage.isEnglish ? englishFillers : turkishFillers }
    private static var screenWords: Set<String> { CommandLanguage.isEnglish ? englishScreenWords : turkishScreenWords }
    /// "press the Send button", "click on Submit", "can you tap OK".
    private static let englishFillers: Set<String> = [
        "jarvis", "hey", "please", "can", "could", "you", "the", "a", "on", "this", "that",
        "press", "click", "tap", "hit", "button", "link", "tab", "option", "icon", "menu",
    ]
    private static let englishScreenWords: Set<String> = [
        "click", "press", "tap", "hit", "select", "check", "button", "link", "menu", "tab", "checkbox", "icon",
        "top", "bottom", "first", "second", "third", "last", "blue", "red", "green", "on screen",
    ]
    private static let turkishFillers: Set<String> = [
        "jarvis", "hey", "lütfen", "şuna", "şunu", "buna", "bunu", "şu", "bu", "bir", "hadi",
        "butonuna", "butona", "butonu", "buton", "düğmesine", "düğmeye", "düğmesi", "düğme", "tuşuna", "tuşu",
        "linkine", "linke", "bağlantısına", "bağlantıya", "seçeneğine", "seçeneği", "sekmesine", "sekmesi",
        "tıkla", "tıklar", "tıklayın", "tıklayabilir", "tıklasana", "bas", "basar", "basabilir", "basın", "bassana",
        "mısın", "misin", "musun", "müsün", "mısınız", "misiniz",
    ]
    /// Words that say "the screen" without naming anything on it.
    private static let turkishScreenWords: Set<String> = [
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
        var words = normalized(text).split(separator: " ").map(String.init)
        if let last = words.last, let name = gluedPressName(last) { words[words.count - 1] = name }
        return words.filter { !fillers.contains($0) }.joined(separator: " ")
    }

    /// Whisper glues a short "Nova'ya bas" into one word ("Novayabas", "Novanabas"): the name
    /// before the "bas". Nil for any other word.
    static func gluedPressName(_ word: String, english: Bool = CommandLanguage.isEnglish) -> String? {
        let word = word.replacingOccurrences(of: "'", with: "")
        guard !english, word.count > 5, word.hasSuffix("bas"), !fillers.contains(word) else { return nil }
        return String(word.dropLast(3))
    }

    /// "… tıkla", "… butonuna bas": clicking said outright, the only way in from a text field.
    static func saysClick(_ text: String) -> Bool {
        let words = normalized(text).replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        if CommandLanguage.isEnglish {
            return words.contains { ["click", "tap", "button"].contains($0) } || ["press", "hit"].contains(words.first ?? "")
        }
        return words.contains { $0.hasPrefix("tıkla") || $0.hasPrefix("butonu") || $0.hasPrefix("butona") || $0.hasPrefix("düğme") }
            || words.last.map { ["bas", "basar", "basın", "bassana"].contains($0) || gluedPressName($0) != nil } ?? false
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
        "bildirim": ["notification"], "artı": ["new", "add", "plus"],
        "dışa": ["export"], "içe": ["import"], "yazdır": ["print"], "bul": ["find", "search"], "pencere": ["window"],
        "sekme": ["tab"], "görünüm": ["view"], "adlandır": ["rename"], "küçült": ["minimize", "zoom out"], "büyüt": ["zoom in"],
        "kes": ["cut"], "yinele": ["redo"], "tümü": ["all"], "hepsi": ["all"], "belge": ["document"], "dosya": ["file"], "klasör": ["folder"],
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

    // MARK: - Text on the screenshot

    /// The OCR line that holds the name said, and the part of it to click: every said word
    /// (case endings aside: "yönetimine" is "Yönetimi") or at least two of three, the tightest
    /// line first. Nil when nothing fits or two different places fit equally.
    static func textMatch(_ said: String, lines: [String]) -> (line: Int, range: Range<String.Index>)? {
        // "Ayarlar'a": the name is before the apostrophe.
        let saidWords = spokenName(said).split(separator: " ").compactMap { $0.split(separator: "'").first.map(String.init) }
        guard !saidWords.isEmpty else { return nil }
        func fits(_ said: String, _ seen: String) -> Bool {
            if said == seen { return true }
            if min(said.count, seen.count) >= 4, said.prefix(4) == seen.prefix(4) { return true }
            let (a, b) = (soundKey(said), soundKey(seen))
            return min(a.count, b.count) >= 5 && a.prefix(5) == b.prefix(5)
        }
        var best: (line: Int, range: Range<String.Index>, matched: Int, extra: Int)?
        var tied: Int?
        for (index, line) in lines.enumerated() {
            var words: [(word: String, range: Range<String.Index>)] = []
            line.enumerateSubstrings(in: line.startIndex..., options: .byWords) { word, range, _, _ in
                if let word { words.append((normalized(word).replacingOccurrences(of: "'", with: ""), range)) }
            }
            var hits: [Range<String.Index>] = []
            for word in saidWords {
                if let hit = words.first(where: { fits(word, $0.word) }) { hits.append(hit.range) }
            }
            guard hits.count * 3 >= saidWords.count * 2,
                  let lower = hits.map(\.lowerBound).min(), let upper = hits.map(\.upperBound).max() else { continue }
            let candidate = (line: index, range: lower..<upper, matched: hits.count, extra: words.count - hits.count)
            if let current = best {
                if (candidate.matched, -candidate.extra) > (current.matched, -current.extra) {
                    best = candidate
                    tied = nil
                } else if (candidate.matched, -candidate.extra) == (current.matched, -current.extra) {
                    tied = index
                }
            } else {
                best = candidate
            }
        }
        guard let best, tied == nil else {
            if let best, let tied {
                owLog("[Screen] '\(said)' fits more than one text on the screenshot ('\(lines[best.line])', '\(lines[tied])'); none clicked")
            }
            return nil
        }
        return (best.line, best.range)
    }

    /// Not in the accessibility tree: find the name on a screenshot of `app`'s window. The
    /// label read and the point to click.
    static func findText(_ said: String, in app: NSRunningApplication) async -> (label: String, point: CGPoint)? {
        let texts = await ScreenReader.ocrTexts(of: app)
        guard let match = textMatch(said, lines: texts.map(\.text)),
              let frame = texts[match.line].frame(of: match.range) else { return nil }
        let label = String(texts[match.line].text[match.range])
        owLog("[Screen] '\(said)' found on the screenshot as '\(label)'")
        return (label, CGPoint(x: frame.midX, y: frame.midY))
    }

    /// "Arama kısmı": the text field so named gets the keyboard focus: from the accessibility
    /// tree (a search field for "arama"), else its name or placeholder clicked on the screenshot.
    static func focusField(named name: String, in app: NSRunningApplication) async -> Bool {
        let fields = elements(of: app).filter(\.isTextField)
        let search = ScreenMode.isSearchField(name)
        let named = fields.filter { isGrounded(name, label: $0.label) || (search && $0.role == "AXSearchField") }
        if let field = named.count == 1 ? named[0] : (search ? named.first { $0.role == "AXSearchField" } : nil),
           perform(field) {
            return true
        }
        var hit = await findText(name, in: app)
        if hit == nil, search { hit = await findText("Search", in: app) }
        if let hit {
            owLog("[Screen] Field '\(name)' clicked on the screenshot")
            return click(at: hit.point)
        }
        owLog("[Screen] No field named '\(name)' (\(fields.count) text fields)")
        return false
    }

    /// Icon-sized controls in `app`'s front window, named or not: what `IconClassifier` looks at.
    static func iconCandidates(of app: NSRunningApplication) -> [ScreenElement] {
        guard let window = ScreenReader.focusedWindow(of: app), let windowFrame = frame(of: window) else { return [] }
        var found: [ScreenElement] = []
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int) {
            guard found.count < 150, visited < 5000, depth < 50 else { return }
            visited += 1
            let info = ScreenReader.node(node)
            let role = info.role
            if let box = info.frame, (8...64).contains(box.width), (8...64).contains(box.height),
               (0.5...2).contains(box.width / box.height), windowFrame.intersects(box), info.enabled,
               ["AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton"].contains(role) || (role == "AXImage" && hasPress(node)) {
                found.append(ScreenElement(element: node, role: role, label: ownLabel(of: node) ?? "", region: region(of: box, in: windowFrame), inDialog: false))
            }
            for child in info.children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }

    /// "Mikrofona bas": the button that looks like the icon named, by the icon model. Nil when
    /// the words name no icon or no button looks like it.
    static func iconPick(_ said: String, in app: NSRunningApplication) async -> ScreenElement? {
        guard let iconClass = IconClassifier.iconClass(for: said) else { return nil }
        let started = Date()
        let candidates = iconCandidates(of: app)
        guard !candidates.isEmpty, let (image, windowFrame, _) = await ScreenReader.captureFrontWindow(of: app) else {
            owLog("[Icons] No buttons to look at for \(iconClass)")
            return nil
        }
        let frames = candidates.map { frame(of: $0.element) ?? .zero }
        let best = IconClassifier.best(iconClass, among: frames, in: image, windowFrame: windowFrame)
        owLog(String(format: "[Icons] %@ among %d buttons: %@ in %d ms", iconClass, candidates.count,
                     best.map { String(format: "'%@' %.2f", candidates[$0.index].label, $0.confidence) } ?? "none",
                     Int(Date().timeIntervalSince(started) * 1000)))
        return best.map { candidates[$0.index] }
    }

    // MARK: - Icons, by a vision model

    /// The center of the box a vision model answered, on a 0–1000 scale of the image. Qwen-VL
    /// writes `bbox_2d` as [x1, y1, x2, y2]; Gemma writes `box_2d` as [y1, x1, y2, x2]
    /// (`yFirst`). Nil for "NONE".
    static func parseVisionPoint(_ answer: String, yFirst: Bool = false) -> CGPoint? {
        // Whole tokens only: the "2" of "bbox_2d" is no coordinate.
        let numbers = answer.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") })
            .compactMap { Double($0) }
        let point: CGPoint
        if numbers.count >= 4 {
            let (a, b) = ((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2)
            point = yFirst ? CGPoint(x: b, y: a) : CGPoint(x: a, y: b)
        } else {
            return nil
        }
        guard (0...1000).contains(point.x), (0...1000).contains(point.y) else { return nil }
        return point
    }

    /// Something without text (a close X, a gear, three dots): the screenshot goes to a vision
    /// model, the cloud's when the cloud is selected, else the local one. The point to click.
    static func visionPick(_ said: String, in app: NSRunningApplication) async -> CGPoint? {
        guard let (image, frame, _) = await ScreenReader.captureFrontWindow(of: app),
              let jpeg = jpegBase64(image, maxWidth: 1280) else { return nil }
        // Each model in the box format it was trained on (tried 1 Nov 2026: Gemma answered a
        // plain "x,y" with the same top-left corner for every icon).
        func prompt(_ format: String) -> String {
            """
            This is a screenshot of a Mac app window. The user said, in Turkish: "\(said)". Detect the element \
            they want to click; it may be an icon without text (a close X, a gear, three dots, a plus, a back \
            arrow). Output only its bounding box as JSON: \(format), normalized to 0-1000. If it is not there, \
            output NONE.
            """
        }
        let started = Date()
        // Each answer keeps the box format its model was asked for.
        struct Answer: Sendable { let text: String; let yFirst: Bool; let backend: String }
        let localPrompt = prompt(#"{"box_2d": [y1, x1, y2, x2]}"#)
        let local: @Sendable () async throws -> Answer? = {
            let text = try await LLM.default.generate(LLMRequest(model: LLM.selectedModel, prompt: localPrompt, timeout: 15,
                                                                 temperature: 0, maxTokens: 40, images: [jpeg]))
            return Answer(text: text, yFirst: true, backend: LLM.selectedModel)
        }
        let answer: Answer?
        if ChatBackend.selected == .cloud, let (client, _) = CloudLLM.client() {
            // A vision model from the server's list when there is one; the chat model may see no images.
            let model = ScreenQuestion.cloudVisionModel
            let content: [[String: Any]] = [
                ["type": "text", "text": prompt(#"{"bbox_2d": [x1, y1, x2, y2]}"#)],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg)"]],
            ]
            nonisolated(unsafe) let messages: [[String: Any]] = [["role": "user", "content": content]]
            // A slow or failing cloud hands over to the local model (`ChatFallback.commandDeadline`).
            answer = try? await ChatFallback.firstUsable(tag: "Screen", cloud: {
                let text = try await client.complete(model: model, messages: messages, timeout: 10, maxTokens: 40)
                return Answer(text: text, yFirst: false, backend: model)
            }, local: local)
        } else {
            answer = try? await local()
        }
        let backend = answer?.backend ?? "none"
        let yFirst = answer?.yFirst ?? false
        let reply = answer?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        owLog("[Screen] Vision model (\(backend)) answered '\(reply.prefix(80))' in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        guard let point = parseVisionPoint(reply, yFirst: yFirst) else { return nil }
        return CGPoint(x: frame.minX + point.x / 1000 * frame.width, y: frame.minY + point.y / 1000 * frame.height)
    }

    static func jpegBase64(_ image: CGImage, maxWidth: Int) -> String? {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }
        return data.base64EncodedString()
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
        // Whisper writes a spoken "artı" as "+": "+ butonuna bas".
        text.lowercased(with: locale)
            .replacingOccurrences(of: "+", with: " artı ")
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
        let started = Date()
        // Cloud selected: the local model takes over when the cloud fails or is slow.
        let reply: String?
        if ChatBackend.selected == .cloud {
            reply = await cloudPick(prompt(for: text, elements: elements))
        } else {
            let request = LLMRequest(model: LLM.selectedModel, prompt: prompt(for: text, elements: elements),
                                     timeout: 8, temperature: 0, maxTokens: 8, stop: ["\n"])
            reply = try? await LLM.default.generate(request)
        }
        guard let answer = reply else {
            owLog("[Screen] Model unavailable")
            return nil
        }
        let pick = parsePick(answer, count: elements.count)
        owLog("[Screen] Model (\(ChatBackend.selected == .cloud ? "cloud" : LLM.selectedModel)) answered '\(answer.trimmingCharacters(in: .whitespacesAndNewlines))' in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return pick
    }

    private static func cloudPick(_ prompt: String) async -> String? {
        guard let client = FallbackChat.command("Screen") else { return nil }
        let request = LLMChatRequest(model: client.cloudModel, messages: [["role": "user", "content": prompt]],
                                     timeout: 8, temperature: 0, maxTokens: 8)
        do {
            var answer = ""
            for try await piece in client.streamChat(request) {
                answer += piece
                guard answer.count < 200 else { break }
            }
            return answer
        } catch {
            owLog("[Screen] Cloud failed: \(ChatFallback.describe(error))")
            return nil
        }
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
            " reset", "biçimlendir", " format", "yükle", " install", " quit", "çöp", " trash",
        ]
        return risky.contains { text.contains($0) }
    }

    /// The answer to "… basayım mı?": true / false, nil when it is no answer (a new request).
    static func confirmation(_ text: String) -> Bool? {
        if CommandLanguage.isEnglish { return EnglishAnswers.decision(text) }
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
        // A closed menu's item has no place on screen to click.
        guard let frame = frame(of: node), frame.width > 1, frame.height > 1 else { return false }
        owLog("[Screen] Press refused; clicking '\(target.label)'")
        return click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    static func click(at point: CGPoint) -> Bool {
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
