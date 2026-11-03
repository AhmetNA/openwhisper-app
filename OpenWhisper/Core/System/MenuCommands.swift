import AppKit
import ApplicationServices

/// The front app's menu bar: "dışa aktar", "yeni pencere", "PDF olarak kaydet" work by their name,
/// without knowing which menu they are in or opening it.
enum MenuCommands {
    /// The menu items of `app`, in menu order. The Apple menu is left out: Restart and Shut Down
    /// are never one misheard word away. Disabled items stay: a closed menu's state is stale until
    /// it opens, and the app refuses the press if it means it.
    static func items(of app: NSRunningApplication) -> [ScreenElement] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let bar = value as! AXUIElement
        let deadline = Date().addingTimeInterval(0.8)
        var found: [ScreenElement] = []
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < 6, found.count < 600, Date() < deadline else { return }
            for child in ScreenReader.children(node) {
                let info = ScreenReader.node(child)
                if info.role == "AXMenu" {
                    walk(child, depth: depth + 1)
                } else if info.role == "AXMenuItem" {
                    let submenu = ScreenReader.children(child).filter { ScreenReader.node($0).role == "AXMenu" }
                    if submenu.isEmpty {
                        if let title = ScreenReader.string(child, kAXTitleAttribute), !title.isEmpty {
                            found.append(ScreenElement(element: child, role: "AXMenuItem", label: String(title.prefix(80)),
                                                       region: "menü çubuğu", inDialog: false))
                        }
                    } else {
                        submenu.forEach { walk($0, depth: depth + 1) }
                    }
                }
            }
        }
        for menu in ScreenReader.children(bar).dropFirst() { walk(menu, depth: 0) }
        owLog("[Menu] \(found.count) items in \(app.localizedName ?? "?")")
        return found
    }

    /// The item whose name was said, first in menu order. "Kapat" in File before one in Window.
    static func exactMatch(_ text: String, in items: [ScreenElement]) -> ScreenElement? {
        ScreenActions.exactMatches(text, labels: items.map(\.label)).first.map { items[$0] }
    }

    /// "Yeni pencere": few words, so looking through the menus can't cost a sentence its answer.
    static func isShort(_ text: String) -> Bool {
        ScreenActions.normalized(text).split(separator: " ").count <= 3
    }

    /// Another wording or language ("yeni pencere" → "New Window"): the model chooses, only among
    /// the items tied to what was said.
    static func modelMatch(_ text: String, in items: [ScreenElement]) async -> ScreenElement? {
        let candidates = Array(items.filter { ScreenActions.isGrounded(text, label: $0.label) }.prefix(40))
        guard !candidates.isEmpty, let pick = await ScreenActions.modelPick(text, elements: candidates) else { return nil }
        return candidates[pick]
    }
}

/// What the keyboard does in any app, by its name.
enum EditKeys {
    struct Key: Equatable {
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    static let copy = Key(code: 8, flags: .maskCommand)
    static let paste = Key(code: 9, flags: .maskCommand)
    static let cut = Key(code: 7, flags: .maskCommand)
    static let undo = Key(code: 6, flags: .maskCommand)
    static let redo = Key(code: 6, flags: [.maskCommand, .maskShift])
    static let selectAll = Key(code: 0, flags: .maskCommand)
    static let escape = Key(code: 53, flags: [])
    static let nextField = Key(code: 48, flags: [])
    static let previousField = Key(code: 48, flags: .maskShift)
    static let enter = Key(code: 36, flags: [])

    private static let turkish: [String: Key] = [
        "kopyala": copy, "bunu kopyala": copy, "seçileni kopyala": copy, "metni kopyala": copy,
        "yapıştır": paste, "buraya yapıştır": paste, "bunu yapıştır": paste,
        "kes": cut, "bunu kes": cut, "seçileni kes": cut,
        "geri al": undo, "bunu geri al": undo,
        "yinele": redo, "yeniden yap": redo, "ileri al": redo,
        "tümünü seç": selectAll, "hepsini seç": selectAll, "tümünü seçer misin": selectAll, "hepsini seçer misin": selectAll,
        "vazgeç": escape, "iptal et": escape, "escape": escape, "esc": escape, "eskep": escape,
        "sonraki alan": nextField, "bir sonraki alan": nextField, "sonraki kutu": nextField, "sonraki alana geç": nextField,
        "önceki alan": previousField, "bir önceki alan": previousField, "önceki kutu": previousField, "önceki alana geç": previousField,
        "enter": enter, "entera bas": enter, "entere bas": enter, "enter tuşuna bas": enter, "entıra bas": enter,
    ]
    private static let english: [String: Key] = [
        "copy": copy, "copy this": copy, "copy that": copy, "paste": paste, "paste here": paste, "paste it": paste,
        "cut": cut, "cut this": cut, "cut that": cut, "undo": undo, "undo that": undo, "redo": redo,
        "select all": selectAll, "escape": escape, "cancel": escape, "next field": nextField, "previous field": previousField,
        "enter": enter, "press enter": enter, "hit enter": enter,
    ]

    /// The whole utterance only: "metni kopyala ve Ali'ye gönder" is no key press.
    static func parse(_ text: String, english isEnglish: Bool = CommandLanguage.isEnglish) -> Key? {
        let words = ScreenActions.normalized(text).replacingOccurrences(of: "'", with: "").split(separator: " ")
            .filter { !["jarvis", "hey", "lütfen", "efendim", "please"].contains($0) }
        return (isEnglish ? english : turkish)[words.joined(separator: " ")]
    }

    static func press(_ key: Key) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: false) else { return }
        down.flags = key.flags
        up.flags = key.flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    static func done(_ key: Key) -> String {
        switch key {
        case copy: L("Kopyalandı", "Copied")
        case paste: L("Yapıştırıldı", "Pasted")
        case cut: L("Kesildi", "Cut")
        case undo: L("Geri alındı", "Undone")
        case selectAll: L("Tümü seçildi", "All selected")
        default: "✓"
        }
    }
}
