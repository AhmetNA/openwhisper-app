import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The user-chosen key that starts a Jarvis session exactly like saying "Hey Jarvis"
/// (Smart Turn auto-stop, own-voice stop gate, spoken replies). Pressing it again while that
/// session is recording finishes it.
///
/// Two shapes:
/// - an ordinary key, optionally with ⌘⌥⌃⇧ (F5, F13, ⌥J …) — fires on keyDown, swallowed;
/// - a lone modifier key (right ⌥, right ⌘ …) — fires when it is tapped and released with no
///   other key in between, so using it in a normal shortcut never starts Jarvis.
struct JarvisHotkey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Raw `CGEventFlags` restricted to `relevantModifiers`; always 0 for a modifier key.
    var modifiers: UInt64
    var isModifierKey: Bool
    /// Shown in Settings; captured at record time so it follows the user's keyboard layout.
    var label: String

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    static let defaultsKey = "jarvisHotkey"

    static func load() -> JarvisHotkey? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(JarvisHotkey.self, from: data)
    }

    static func save(_ hotkey: JarvisHotkey?) {
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// Whether a keyDown with these flags is this hotkey. Fn is ignored: Mac keyboards set it on
    /// every F-key and arrow press.
    func matchesKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard !isModifierKey, keyCode == Int64(self.keyCode) else { return false }
        return flags.intersection(Self.relevantModifiers).rawValue == modifiers
    }

    // MARK: - Key classification

    static let fnKeyCode: UInt16 = UInt16(kVK_Function)

    /// Lone modifier keys that can be bound; Fn stays the dictation key and Caps Lock toggles state.
    static let modifierKeyNames: [UInt16: String] = [
        UInt16(kVK_RightOption): "Sağ ⌥ Option",
        UInt16(kVK_Option): "Sol ⌥ Option",
        UInt16(kVK_RightCommand): "Sağ ⌘ Command",
        UInt16(kVK_Command): "Sol ⌘ Command",
        UInt16(kVK_RightControl): "Sağ ⌃ Control",
        UInt16(kVK_Control): "Sol ⌃ Control",
        UInt16(kVK_RightShift): "Sağ ⇧ Shift",
        UInt16(kVK_Shift): "Sol ⇧ Shift",
    ]

    /// The CGEventFlags bit a lone modifier key sets while it is down.
    static func flag(forModifierKey keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Command, kVK_RightCommand: .maskCommand
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Shift, kVK_RightShift: .maskShift
        default: nil
        }
    }

    static let specialKeyNames: [UInt16: String] = {
        var names: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            kVK_Space: "Space", kVK_Return: "Enter", kVK_ANSI_KeypadEnter: "Enter", kVK_Tab: "Tab",
            kVK_Delete: "Delete", kVK_ForwardDelete: "⌦", kVK_Escape: "Esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_Help: "Help",
        ]
        names[kVK_ANSI_KeypadClear] = "Clear"
        return Dictionary(uniqueKeysWithValues: names.map { (UInt16($0.key), $0.value) })
    }()

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func modifierSymbols(_ flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s
    }

    struct SystemKeyPress: Equatable {
        let nxKeyType: Int
        let sequence: Int
    }

    /// Why a key that only produced a system-defined event (no keyDown) can't be bound.
    static func systemKeyMessage(nxKeyType: Int) -> String {
        let what: String = switch nxKeyType {
        case 0, 1, 7: "ses tuşu"
        case 2, 3: "parlaklık tuşu"
        case 16, 17, 18, 19, 20: "medya tuşu"
        case 21, 22, 23: "klavye ışığı tuşu"
        default: "özel macOS tuşu"
        }
        return "Bu tuş macOS'te \(what) olarak çalışıyor, uygulamalara normal tuş olarak gelmiyor. "
            + "fn'i basılı tutup bu tuşa basın ya da Sistem Ayarları › Klavye › Klavye Kestirmeleri… › "
            + "İşlev Tuşları'nda “F1, F2 vb. tuşları standart işlev tuşları olarak kullan”ı açın."
    }

    enum CaptureResult: Equatable {
        case accepted(JarvisHotkey)
        case rejected(String)
    }

    /// Validates a key pressed in the Settings recorder. `characters` is the layout's character
    /// for the key without modifiers, used for the label of ordinary keys.
    static func capture(keyCode: UInt16, flags: CGEventFlags, characters: String?) -> CaptureResult {
        if keyCode == fnKeyCode {
            return .rejected("Fn zaten dikte tuşu — başka bir tuş seçin.")
        }
        let mods = flags.intersection(relevantModifiers)
        if [UInt16(kVK_Space), UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)].contains(keyCode), mods.isEmpty {
            return .rejected("Space ve Enter kaydı bitirmek için kullanılıyor — başka bir tuş seçin.")
        }
        // A bare typing key would be swallowed everywhere and break normal typing. Codes above
        // 127 aren't typing keys (Apple's Dictation/Spotlight/Focus keys, when they arrive).
        if mods.isEmpty && !functionKeyCodes.contains(Int(keyCode)) && keyCode <= 127
            && ![UInt16(kVK_Help), UInt16(kVK_ANSI_KeypadClear)].contains(keyCode) {
            return .rejected("Bu tuş yazarken kullanılıyor — F tuşu, sağ Option gibi tek bir tuş ya da ⌥ ile bir kombinasyon seçin.")
        }
        let name = specialKeyNames[keyCode]
            ?? characters.map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
            ?? (keyCode > 127 ? "Özel tuş \(keyCode)" : "Tuş \(keyCode)")
        return .accepted(JarvisHotkey(
            keyCode: keyCode, modifiers: mods.rawValue, isModifierKey: false,
            label: modifierSymbols(mods) + name
        ))
    }

    /// A modifier key tapped on its own in the Settings recorder.
    static func captureModifier(keyCode: UInt16) -> CaptureResult {
        guard let name = modifierKeyNames[keyCode] else {
            return .rejected("Bu tuş atanamıyor — başka bir tuş seçin.")
        }
        return .accepted(JarvisHotkey(keyCode: keyCode, modifiers: 0, isModifierKey: true, label: name))
    }
}
