import AppKit

/// What a mouse does besides moving: the press of a number, a right or double click, a hover.
enum PointerAction: Equatable {
    case press, rightClick, doubleClick, hover
}

/// A step in screen mode said the way one uses a mouse: "numaraları göster", "beş", "beşe çift
/// tıkla", "Kaydet'e sağ tıkla", "beşi dokuza sürükle", "tıkla". Plain "Kaydet'e
/// bas" is no such step: it stays with `ScreenActions`.
enum PointerCommand: Equatable {
    case open
    case showNumbers
    case showGrid(fullScreen: Bool)
    case hideOverlay
    /// A number on the overlay; no action when only the number was said.
    case number(Int, PointerAction?)
    /// By the name on screen; a press by name is not one of these.
    case name(String, PointerAction)
    /// Where the grid or the pointer is now.
    case here(PointerAction)
    case dragNumbers(Int, Int)
    case dragNames(String, String)
}

enum ScreenPointer {
    // MARK: - What was said

    static func parse(_ text: String, english: Bool = CommandLanguage.isEnglish) -> PointerCommand? {
        let words = ScreenActions.normalized(text).split(separator: " ").map(String.init)
        return english ? parseEnglish(words) : parseTurkish(words)
    }

    /// Whether the step is said in full, so the mic can stop at once. A step's start often parses
    /// too: "beşi … dokuza sürükle", "on … iki", "çok aşağı … kaydır", "click … 12" wait for the
    /// usual end of speech.
    static func isFinished(_ text: String, english: Bool = CommandLanguage.isEnglish) -> Bool {
        guard let command = parse(text, english: english),
              let last = ScreenActions.normalized(text).split(separator: " ").map(String.init).last(where: {
                  !["jarvis", "lütfen", "please"].contains($0)
              }) else { return false }
        let bareDigits = last.allSatisfy(\.isNumber)
        switch command {
        case .open, .showNumbers, .showGrid, .hideOverlay:
            return true
        case .number(_, nil):
            if bareDigits { return true }
            return english ? englishNumbers[last] != nil && englishTens[last] == nil : turkishUnits.contains(last)
        case .number:
            if english { return bareDigits || (englishNumbers[last] != nil && englishTens[last] == nil) }
            return turkishEndsOnVerb(last)
        case .name, .here:
            return !english && turkishEndsOnVerb(last)
        case .dragNumbers:
            return english ? bareDigits || englishTens[last] == nil : turkishEndsOnVerb(last)
        case .dragNames:
            return !english && turkishEndsOnVerb(last)
        }
    }

    private static let turkishUnits: Set<String> = ["bir", "iki", "üç", "uc", "dört", "dort", "beş", "bes", "altı", "alti", "yedi", "sekiz", "dokuz"]

    private static func turkishEndsOnVerb(_ word: String) -> Bool {
        turkishPress.contains(word) || turkishDrag.contains(word) || ["mısın", "mısınız", "misin", "misiniz", "tık", "gel", "git", "götür", "dur", "al", "doğru"].contains(word)
            || ScreenActions.gluedPressName(word, english: false) != nil
    }

    private static let turkishFillers: Set<String> = ["numara", "numaraya", "numarayı", "numaralı", "numarası", "şuna", "buna"]
    private static let turkishHere: Set<String> = ["buraya", "burada", "burayı", "burası", "şuraya", "orada", "oraya"]
    private static let turkishPress: Set<String> = ["bas", "basın", "bassana", "basar", "tıkla", "tıklayın", "tıklasana", "tıklar"]
    private static let turkishDrag: Set<String> = ["sürükle", "sürükleyin", "sürüklesene", "taşı", "taşıyın"]
    private static let turkishPhrases: [(words: [String], action: PointerAction)] = [
        (["çift", "tıkla"], .doubleClick), (["çift", "tık"], .doubleClick), (["çifte", "tıkla"], .doubleClick),
        (["çift", "tıklar"], .doubleClick), (["iki", "kere", "tıkla"], .doubleClick), (["iki", "kez", "tıkla"], .doubleClick),
        (["iki", "defa", "tıkla"], .doubleClick), (["sağ", "tıkla"], .rightClick), (["sağ", "tık"], .rightClick),
        (["sağ", "tıklar"], .rightClick), (["sağa", "tıkla"], .rightClick), (["üstüne", "gel"], .hover), (["üzerine", "gel"], .hover),
        (["üstüne", "git"], .hover), (["üzerine", "git"], .hover), (["üstüne", "götür"], .hover), (["üzerine", "götür"], .hover),
        (["üstünde", "dur"], .hover), (["üzerinde", "dur"], .hover),
    ]
    private static let turkishOpen: Set<String> = ["ekran modu", "ekran modunu aç", "ekran modu aç", "ekran modunu başlat"]
    private static let turkishGridWords: Set<String> = ["ızgara", "ızgarayı", "ızgarası", "izgara", "izgarayı", "izgarası", "grid", "gridi", "kareleri"]
    private static let turkishNumberWords: Set<String> = ["numaraları", "numaralar", "sayıları", "rakamları"]

    private static func parseTurkish(_ said: [String]) -> PointerCommand? {
        var words = said.filter { !["jarvis", "hey", "lütfen", "efendim"].contains($0) }
        guard !words.isEmpty, words.count <= 12 else { return nil }
        // Whisper glues a short "beşe bas" into "beşebas".
        if let last = words.last, let name = ScreenActions.gluedPressName(last, english: false) {
            words[words.count - 1] = name
            words.append("bas")
        }
        if let overlay = turkishOverlay(words) { return overlay }
        if ["mısın", "mısınız", "misin", "misiniz"].contains(words.last ?? "") { words.removeLast() }

        var action: PointerAction?
        var drag = false
        var rest = words
        if let phrase = turkishPhrases.first(where: { words.starts(with: $0.words) || words.suffix($0.words.count).elementsEqual($0.words) }) {
            action = phrase.action
            rest = words.starts(with: phrase.words) ? Array(words.dropFirst(phrase.words.count)) : Array(words.dropLast(phrase.words.count))
        } else if let last = words.last, turkishPress.contains(last) {
            action = .press
            rest = Array(words.dropLast())
        } else if let last = words.last, turkishDrag.contains(last) {
            drag = true
            rest = Array(words.dropLast())
        }
        rest = rest.filter { !turkishFillers.contains($0) }
        // "Ona bas" is "press it", "bir tıkla" is "give it a click": ten is "on'a", one is "bire".
        if action != nil, rest == ["bir"] { rest = [] }
        let plain = rest.map { $0.hasPrefix("on'") ? "on" : $0.replacingOccurrences(of: "'", with: "") }

        if drag {
            if let numbers = numbers(in: plain, table: turkishNumbers, tens: turkishTens), numbers.count == 2 {
                return .dragNumbers(numbers[0], numbers[1])
            }
            return turkishNamedDrag(rest)
        }
        if let numbers = numbers(in: plain, table: turkishNumbers, tens: turkishTens), numbers.count == 1 {
            return .number(numbers[0], action)
        }
        // "Beşe git": gel/git take a number only, "geri git" is no hover.
        if action == nil, ["gel", "git", "götür"].contains(plain.last ?? ""),
           let numbers = numbers(in: Array(plain.dropLast()), table: turkishNumbers, tens: turkishTens), numbers.count == 1 {
            return .number(numbers[0], .hover)
        }
        if let action {
            if plain.allSatisfy(turkishHere.contains) { return .here(action) }
            // Plain "Kaydet'e bas" goes the way it always went.
            // A name is a few words; "bu konunun … üstüne gel" is a sentence.
            guard action != .press, rest.count <= 5 else { return nil }
            return .name(nameWithoutEnding(rest), action)
        }
        return nil
    }

    private static func turkishOverlay(_ words: [String]) -> PointerCommand? {
        if turkishOpen.contains(words.joined(separator: " ")) { return .open }
        guard let last = words.last else { return nil }
        let hasVerb = ["göster", "aç", "gizle", "kapat", "kaldır", "göstersene"].contains(last)
        let verbless = hasVerb ? Array(words.dropLast()) : words
        let hiding = ["gizle", "kapat", "kaldır"].contains(last)
        if hasVerb, verbless.count == 1, turkishNumberWords.contains(verbless[0]) {
            return hiding ? .hideOverlay : .showNumbers
        }
        if let grid = verbless.last, turkishGridWords.contains(grid) {
            let before = verbless.dropLast()
            guard before.allSatisfy({ ["ekran", "ekrana", "ekranı", "tüm", "tam", "bütün"].contains($0) }) else { return nil }
            return hiding ? .hideOverlay : .showGrid(fullScreen: !before.isEmpty)
        }
        return nil
    }

    /// "Dosyayı klasöre sürükle": what is dragged ends in -i or -den, what comes after is where to.
    private static func turkishNamedDrag(_ rest: [String]) -> PointerCommand? {
        guard rest.count >= 2 else { return nil }
        let split = rest.dropLast().lastIndex { word in
            let word = word.split(separator: "'").last.map(String.init) ?? word
            return ["i", "ı", "u", "ü", "den", "dan", "ten", "tan"].contains { word.hasSuffix($0) }
        }
        guard let split else { return nil }
        return .dragNames(nameWithoutEnding(Array(rest[...split])), nameWithoutEnding(Array(rest[(split + 1)...])))
    }

    /// The apostrophe's ending goes: "Kaydet'in" is "Kaydet".
    private static func nameWithoutEnding(_ words: [String]) -> String {
        var words = words
        if let last = words.last, let cut = last.split(separator: "'").first { words[words.count - 1] = String(cut) }
        return words.joined(separator: " ")
    }

    private static let englishFillers: Set<String> = ["jarvis", "hey", "please", "number", "the", "on", "at", "can", "could", "you"]
    private static let englishPhrases: [(words: [String], action: PointerAction)] = [
        (["double", "click"], .doubleClick), (["right", "click"], .rightClick), (["hover", "over"], .hover),
        (["hover"], .hover), (["move", "to"], .hover), (["click"], .press), (["press"], .press), (["tap"], .press),
    ]

    private static func parseEnglish(_ said: [String]) -> PointerCommand? {
        let words = said.filter { !englishFillers.contains($0) }
        guard !words.isEmpty, words.count <= 12 else { return nil }
        switch words.joined(separator: " ") {
        case "screen mode", "open screen mode", "start screen mode": return .open
        case "show numbers", "show number": return .showNumbers
        case "show grid", "show window grid", "grid": return .showGrid(fullScreen: false)
        case "show screen grid", "show full screen grid": return .showGrid(fullScreen: true)
        case "hide numbers", "hide grid", "hide overlay": return .hideOverlay
        default: break
        }
        if words.first == "drag", let to = words.firstIndex(of: "to"), to > 1, to < words.count - 1 {
            let from = Array(words[1..<to]), target = Array(words[(to + 1)...])
            if let first = numbers(in: from, table: englishNumbers, tens: englishTens), first.count == 1,
               let second = numbers(in: target, table: englishNumbers, tens: englishTens), second.count == 1 {
                return .dragNumbers(first[0], second[0])
            }
            return .dragNames(from.joined(separator: " "), target.joined(separator: " "))
        }
        if let phrase = englishPhrases.first(where: { words.starts(with: $0.words) }) {
            let rest = Array(words.dropFirst(phrase.words.count))
            if rest.isEmpty || rest == ["here"] || rest == ["it"] { return .here(phrase.action) }
            if let numbers = numbers(in: rest, table: englishNumbers, tens: englishTens), numbers.count == 1 {
                return .number(numbers[0], phrase.action)
            }
            guard phrase.action != .press else { return nil }
            return .name(rest.joined(separator: " "), phrase.action)
        }
        if let numbers = numbers(in: words, table: englishNumbers, tens: englishTens), numbers.count == 1 {
            return .number(numbers[0], nil)
        }
        return nil
    }

    // MARK: - Numbers

    private static func forms(_ table: [(Int, [String])]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (value, words) in table { for word in words { map[word] = value } }
        return map
    }

    /// Every case a number is said in: "beşe bas", "beşi taşı", "beşin üstüne", "beşten dokuza".
    private static let turkishNumbers = forms([
        (1, ["bir", "bire", "biri", "birin", "birden"]),
        (2, ["iki", "ikiye", "ikiyi", "ikinin", "ikiden"]),
        (3, ["üç", "uc", "üçe", "üçü", "üçün", "üçten"]),
        (4, ["dört", "dort", "dörde", "dördü", "dördün", "dörtten"]),
        (5, ["beş", "bes", "beşe", "beşi", "beşin", "beşten"]),
        (6, ["altı", "alti", "altıya", "altıyı", "altının", "altıdan"]),
        (7, ["yedi", "yediye", "yediyi", "yedinin", "yediden"]),
        (8, ["sekiz", "sekize", "sekizi", "sekizin", "sekizden"]),
        (9, ["dokuz", "dokuza", "dokuzu", "dokuzun", "dokuzdan"]),
        (10, ["on"]),
        (20, ["yirmi", "yirmiye", "yirmiyi", "yirminin", "yirmiden"]),
        (30, ["otuz", "otuza", "otuzu", "otuzun", "otuzdan"]),
        (40, ["kırk", "kırka", "kırkı", "kırkın", "kırktan"]),
        (50, ["elli", "elliye", "elliyi", "ellinin", "elliden"]),
        (60, ["altmış", "altmışa", "altmışı", "altmışın", "altmıştan"]),
        (70, ["yetmiş", "yetmişe", "yetmişi", "yetmişin", "yetmişten"]),
        (80, ["seksen", "seksene", "sekseni", "seksenin", "seksenden"]),
        (90, ["doksan", "doksana", "doksanı", "doksanın", "doksandan"]),
    ])
    /// A ten followed by a unit is one number: "on iki".
    private static let turkishTens: [String: Int] = ["on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60, "yetmiş": 70, "seksen": 80, "doksan": 90]

    private static let englishNumbers = forms([
        (1, ["one"]), (2, ["two"]), (3, ["three"]), (4, ["four"]), (5, ["five"]), (6, ["six"]), (7, ["seven"]), (8, ["eight"]),
        (9, ["nine"]), (10, ["ten"]), (11, ["eleven"]), (12, ["twelve"]), (13, ["thirteen"]), (14, ["fourteen"]), (15, ["fifteen"]),
        (16, ["sixteen"]), (17, ["seventeen"]), (18, ["eighteen"]), (19, ["nineteen"]), (20, ["twenty"]), (30, ["thirty"]),
        (40, ["forty"]), (50, ["fifty"]), (60, ["sixty"]), (70, ["seventy"]), (80, ["eighty"]), (90, ["ninety"]),
    ])
    private static let englishTens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// The numbers the words are, nil when any word is something else. "5e", "12ye" and "on iki"
    /// are one number each.
    private static func numbers(in words: [String], table: [String: Int], tens: [String: Int]) -> [Int]? {
        guard !words.isEmpty else { return nil }
        var found: [Int] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let digits = word.range(of: #"^\d{1,3}"#, options: .regularExpression) {
                let ending = word[digits.upperBound...]
                guard ending.count <= 3, ending.allSatisfy(\.isLetter), let value = Int(word[digits]) else { return nil }
                found.append(value)
                index += 1
                continue
            }
            if let ten = tens[word], index + 1 < words.count, let unit = table[words[index + 1]], unit < 10 {
                found.append(ten + unit)
                index += 2
                continue
            }
            guard let value = table[word] else { return nil }
            found.append(value)
            index += 1
        }
        return found
    }

    // MARK: - The grid

    static let gridColumns = 4
    static let gridRows = 3

    /// Cell `number` of the grid over `rect`, counted left to right, top to bottom from 1.
    static func gridCell(_ number: Int, in rect: CGRect) -> CGRect? {
        guard (1...gridColumns * gridRows).contains(number) else { return nil }
        let width = rect.width / CGFloat(gridColumns), height = rect.height / CGFloat(gridRows)
        let column = (number - 1) % gridColumns, row = (number - 1) / gridColumns
        return CGRect(x: rect.minX + CGFloat(column) * width, y: rect.minY + CGFloat(row) * height, width: width, height: height)
    }

    /// A cell this small is as far as the grid goes: its number clicks instead of dividing it.
    static func isLastGridLevel(_ rect: CGRect) -> Bool {
        rect.width / CGFloat(gridColumns) < 12 || rect.height / CGFloat(gridRows) < 12
    }

    // MARK: - The mouse

    /// Where the pointer is, in the coordinates of accessibility and of mouse events.
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: clicks)
        event.post(tap: .cghidEventTap)
    }

    static func move(to point: CGPoint) {
        post(.mouseMoved, at: point)
    }

    /// Moves first: web pages open what a click lands on only after the pointer entered it.
    static func click(at point: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        move(to: point)
        usleep(40_000)
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for click in 1...Int64(max(count, 1)) {
            post(down, at: point, button: button, clicks: click)
            usleep(20_000)
            post(up, at: point, button: button, clicks: click)
            usleep(20_000)
        }
    }

    /// Press, the way there in small steps (a press and release alone is no drag), release.
    static func drag(from start: CGPoint, to end: CGPoint) async {
        await Task.detached(priority: .userInitiated) {
            move(to: start)
            usleep(60_000)
            post(.leftMouseDown, at: start)
            usleep(120_000)
            let steps = 30
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
                usleep(12_000)
            }
            usleep(120_000)
            post(.leftMouseUp, at: end)
        }.value
    }
}
