import Foundation

/// After Jarvis presses something on screen the mic stays open for the next step: "şuna bas",
/// "aşağı kaydır", "Safari'yi aç", "… yaz". A closer ("tamamdır", "harikasın"), "… yaz ve
/// gönder" or `silence` without an action ends it.
enum ScreenMode {
    /// No action for this long closes the mode.
    static let silence: TimeInterval = 30
    /// A recording in the mode may run this long: "… yaz ve gönder" carries a whole message.
    static let maxDuration: TimeInterval = 15

    private static let locale = Locale(identifier: "tr_TR")
    private static let fillers: Set<String> = ["jarvis", "lütfen", "efendim", "o", "zaman"]
    /// The whole utterance only. Bare "tamam" is a button ("Tamam'a bas") and a yes.
    private static let closers: Set<String> = [
        "tamamdır", "tamam bu kadar", "bu kadar", "bu kadarı yeter", "yeter", "harikasın", "harika",
        "süpersin", "eline sağlık", "teşekkürler", "teşekkür ederim", "sağ ol", "sağol", "sağ olasın",
        "işimiz bitti", "tamam bitti", "kapat modu", "ekran modunu kapat", "gerek kalmadı",
    ]

    static func isCloser(_ text: String) -> Bool {
        let words = ScreenActions.normalized(text).split(separator: " ").map(String.init).filter { !fillers.contains($0) }
        return closers.contains(words.joined(separator: " "))
    }

    private static let pressVerbs: Set<String> = ["bas", "basın", "bassana", "tıkla", "tıklayın", "tıklasana"]

    /// "Ayarlar'a bas", "geri butonuna tıklar mısın": the step is said in full, so the mic can
    /// stop without waiting out the silence. Never "… yaz": a message may go on after a pause.
    static func isFinishedPress(_ text: String) -> Bool {
        var words = ScreenActions.normalized(text).replacingOccurrences(of: "'", with: " ")
            .split(separator: " ").map(String.init).filter { $0 != "lütfen" }
        guard typeRequest(text) == nil, let last = words.popLast() else { return false }
        if pressVerbs.contains(last) || ScreenActions.gluedPressName(last) != nil { return true }
        return ["mısın", "mısınız"].contains(last) && ["basar", "tıklar"].contains(words.last ?? "")
    }

    private static let sendRegex = try! NSRegularExpression(
        pattern: #"^(.+?)[\s,]+(?:diye\s+)?(?:yaz\s+ve|yazıp|yaz)\s+(?:gönder|yolla)(?:\s+lütfen)?[\s.!]*$"#,
        options: [.caseInsensitive])

    /// "merhaba yaz ve gönder" → ("merhaba", send). "… yaz" alone types without Return. Nil
    /// for anything else, "Gönder'e bas" included.
    static func typeRequest(_ text: String) -> (text: String, send: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = sendRegex.firstMatch(in: trimmed, range: range), let body = Range(match.range(at: 1), in: trimmed) {
            let said = String(trimmed[body]).trimmingCharacters(in: CharacterSet(charactersIn: " ,:\"'“”"))
            return said.isEmpty ? nil : (said, true)
        }
        if let said = JarvisAddressee.leadingTypeCommand(trimmed) ?? JarvisAddressee.trailingTypeCommand(trimmed) {
            return (said, false)
        }
        return nil
    }
}
