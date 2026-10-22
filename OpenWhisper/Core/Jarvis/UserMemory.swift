import Foundation

/// What the user asked Jarvis to keep in mind ("bunu hatırla: annemin doğum günü 3 Mart",
/// "benim adım Ahmet"). Saved to `jarvis_memory.json` and handed to every chat, so Jarvis
/// knows the user across days. Unlike reminders nothing rings; it is only knowledge.
@MainActor
final class UserMemory {
    static let shared = UserMemory()

    struct Fact: Codable, Equatable {
        var text: String
        var saved: Date
    }

    /// Oldest first.
    private(set) var facts: [Fact] = []
    private static let maxFacts = 60
    private let url: URL?

    init(url: URL? = UserMemory.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Fact].self, from: data) {
            facts = saved
        }
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenWhisper/jarvis_memory.json")
    }

    /// Lines for the chat's system prompt, newest last, each with the day it was said
    /// ("12 Ekim: kahveyi şekersiz içiyorum"); the name needs no date.
    var promptLines: [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy"
        return facts.suffix(25).map { fact in
            fact.text.hasPrefix(Self.namePrefix) ? fact.text : "\(formatter.string(from: fact.saved)): \(fact.text)"
        }
    }

    func remember(_ text: String, now: Date = Date()) {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !fact.isEmpty else { return }
        // A new name replaces the old one.
        if fact.hasPrefix(Self.namePrefix) { facts.removeAll { $0.text.hasPrefix(Self.namePrefix) } }
        facts.removeAll { $0.text.lowercased() == fact.lowercased() }
        facts.append(Fact(text: fact, saved: now))
        facts = Array(facts.suffix(Self.maxFacts))
        save()
    }

    /// Removes the facts mentioning every word of `topic`; returns how many went.
    @discardableResult
    func forget(_ topic: String) -> Int {
        let locale = Locale(identifier: "tr_TR")
        let words = Self.words(topic)
        guard !words.isEmpty else { return 0 }
        let before = facts.count
        facts.removeAll { fact in
            let text = fact.text.lowercased(with: locale)
            return words.allSatisfy { text.contains($0) }
        }
        if facts.count != before { save() }
        return before - facts.count
    }

    @discardableResult
    func forgetLast() -> Fact? {
        guard let last = facts.popLast() else { return nil }
        save()
        return last
    }

    func forgetAll() {
        facts.removeAll()
        save()
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(facts) { try? data.write(to: url, options: .atomic) }
        owLog("[Memory] \(facts.count) fact(s) saved")
    }

    nonisolated static let namePrefix = "Kullanıcının adı "

    /// Content words of `text`, lowercased, case endings left on ("annemin" still finds
    /// "annemin doğum günü").
    nonisolated static func words(_ text: String) -> [String] {
        let locale = Locale(identifier: "tr_TR")
        let stop: Set<String> = ["bir", "şey", "şeyi", "ile", "ve", "ki", "de", "da", "bu", "şu", "olan", "hakkında", "hakkındaki"]
        return text.lowercased(with: locale)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
            // Drop a trailing accusative so "doğum gününü" still matches "doğum günü".
            .map { word in
                for suffix in ["nı", "ni", "nu", "nü", "yı", "yi", "yu", "yü"] where word.count > 4 && word.hasSuffix(suffix) {
                    return String(word.dropLast(suffix.count))
                }
                return word
            }
    }
}

/// "Bunu hatırla: …", "benim adım …", "hakkımda ne biliyorsun?", "şunu unut: …".
enum UserMemoryCommand: Equatable, Sendable {
    case remember(String)
    case recall
    case forget(String)
    case forgetLast
    case forgetAll

    static func parse(_ text: String) -> UserMemoryCommand? {
        let locale = Locale(identifier: "tr_TR")
        var lower = text.lowercased(with: locale).trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["hey jarvis", "jarvis"] where lower.hasPrefix(lead) {
            lower = String(lower.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        }
        let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: bare, range: NSRange(bare.startIndex..., in: bare)),
                  let range = Range(match.range(at: 1), in: bare) else { return nil }
            let value = String(bare[range]).trimmingCharacters(in: CharacterSet(charactersIn: " :,.-"))
            return value.isEmpty ? nil : value
        }

        let recall = [
            "benim hakkımda ne biliyorsun", "hakkımda ne biliyorsun", "hakkımda neler biliyorsun",
            "benim hakkımda neler biliyorsun", "neler hatırlıyorsun", "ne hatırlıyorsun",
            "benim hakkımda neler hatırlıyorsun", "hafızanda ne var", "hafızanda neler var"
        ]
        if recall.contains(bare) { return .recall }

        if ["hakkımdaki her şeyi unut", "hakkımda bildiğin her şeyi unut", "hafızanı sil", "hafızanı temizle", "hatırladığın her şeyi unut"].contains(bare) {
            return .forgetAll
        }
        if ["bunu unut", "son söylediğimi unut", "onu unut", "son hatırladığını unut"].contains(bare) { return .forgetLast }
        if let topic = capture(#"^(?:bunu|şunu)\s+unut\s*[:,]?\s+(.+)$"#)
            ?? capture(#"^(.+?)\s+(?:bilgisini|konusunu)\s+unut$"#) {
            return .forget(topic)
        }

        if let name = capture(#"^(?:benim\s+)?ad[ıi]m\s+(\p{L}+(?:\s+\p{L}+)?)$"#), name.split(separator: " ").count <= 2 {
            // "Adım Ahmet", not "adım atmak istiyorum".
            let display = name.split(separator: " ").map { $0.prefix(1).uppercased(with: locale) + $0.dropFirst() }.joined(separator: " ")
            return .remember(UserMemory.namePrefix + display)
        }
        if let name = capture(#"^bana\s+(\p{L}+)\s+de$"#) {
            return .remember("Kullanıcı kendisine \"\(name.prefix(1).uppercased(with: locale) + name.dropFirst())\" diye hitap edilmesini istiyor")
        }
        // "Hatırla" exactly, never "hatırlat" (reminders).
        if let fact = capture(#"^(?:bunu|şunu|şöyle)?\s*(?:hatırla|aklında\s+tut|aklında\s+bulunsun|unutma)(?:\s+ki)?\s*[:,]?\s+(.+)$"#)
            ?? capture(#"^(.+?)[,.]?\s+(?:bunu|şunu)\s+(?:hatırla|aklında\s+tut|unutma)$"#) {
            return .remember(fact)
        }
        return nil
    }
}
