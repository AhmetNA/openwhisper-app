import Foundation

/// The language commands are spoken in: Settings › "Yazıya dökme dili" (`AppState.language`).
/// Only English switches anything; every other choice, auto-detect included, keeps Turkish.
enum CommandLanguage {
    static var isEnglish: Bool { UserDefaults.standard.string(forKey: "language") == "en" }

    /// For lowercasing a transcript: Turkish rules make "Imagine" "ımagine", which no English
    /// search finds.
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "tr_TR") }
}
