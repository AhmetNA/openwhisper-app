import Foundation

/// "Test modunu başlat": Jarvis reads the next untested TODO.md item aloud, the user tries it
/// and says "geçti" or "kaldı". A pass removes the item from TODO.md (passed items do not stay
/// ticked), a failure keeps it with the date and the reason. Every result also goes to
/// `voice_test_results.log`, so removed items stay traceable.
enum VoiceTestCommand: Equatable, Sendable {
    case start
    case passed
    case failed(note: String?)
    case skip
    case repeatItem
    case stop

    /// Pass, fail, skip and repeat are only words while test mode is on; "geç" alone or
    /// "oldu" in normal talk must not reach TODO.md.
    static func parse(_ text: String, active: Bool) -> VoiceTestCommand? {
        let locale = Locale(identifier: "tr_TR")
        var lower = text.lowercased(with: locale).trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["hey jarvis", "jarvis"] where lower.hasPrefix(lead) {
            lower = String(lower.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        }
        let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))

        let start = [
            "test modunu başlat", "test modunu aç", "test moduna geç", "test moduna gir", "test modu",
            "test modunu başlatır mısın", "testlere başla", "testlere başlayalım", "test yapalım"
        ]
        if start.contains(bare) { return .start }
        let stop = [
            "test modunu kapat", "test modunu bitir", "test modundan çık", "testi bitir",
            "testleri bitir", "testleri bırak", "test bitti"
        ]
        if stop.contains(bare) { return active ? .stop : nil }
        guard active else { return nil }

        if ["bitir", "çık", "yeter", "bu kadar", "bugünlük bu kadar"].contains(bare) { return .stop }
        if ["geçti", "testi geçti", "bu geçti", "oldu", "çalıştı", "çalışıyor", "başarılı", "tamam geçti", "evet geçti"].contains(bare) {
            return .passed
        }
        if ["atla", "bunu atla", "sonraki", "sıradaki", "sonrakine geç", "pas", "pas geç", "şimdi değil"].contains(bare) {
            return .skip
        }
        if ["tekrar", "tekrar oku", "tekrar et", "bir daha oku", "ne diyordu", "madde neydi", "neydi"].contains(bare) {
            return .repeatItem
        }
        for verb in ["kaldı", "testi kaldı", "bu kaldı", "olmadı", "çalışmadı", "başarısız"] {
            if bare == verb { return .failed(note: nil) }
            if bare.hasPrefix(verb + " ") || bare.hasPrefix(verb + ",") {
                var note = String(bare.dropFirst(verb.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,:.-"))
                for joiner in ["çünkü ", "sebebi ", "neden "] where note.hasPrefix(joiner) {
                    note = String(note.dropFirst(joiner.count))
                }
                return .failed(note: note.isEmpty ? nil : note)
            }
        }
        return nil
    }
}

struct VoiceTestItem: Equatable, Sendable {
    /// The TODO.md line exactly as written; found again by content, since other edits move lines.
    let line: String
    let section: String
    /// Item text without markdown, commit hashes, log patterns and links, for the voice.
    let spoken: String
}

/// What test mode says after a command.
enum VoiceTestOutcome: Equatable, Sendable {
    case next(VoiceTestItem, remaining: Int)
    case finished
    case todoMissing
    /// The item was edited or removed elsewhere meanwhile; nothing was written.
    case itemChanged
    case stopped
}

enum VoiceTestTodo {
    /// Development plans, not things to try by hand.
    static let skippedSections = ["Proje bakımı", "Wake Word"]
    static let failMarker = "❌ sesli test"

    /// Top-level `- [ ]` items in file order; ones already failed once come last.
    static func items(in markdown: String) -> [VoiceTestItem] {
        var section = ""
        var fresh: [VoiceTestItem] = [], failedBefore: [VoiceTestItem] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3))
                continue
            }
            guard line.hasPrefix("- [ ] "),
                  !skippedSections.contains(where: { section.hasPrefix($0) }) else { continue }
            let body = String(line.dropFirst(6))
            let spoken = spokenText(body)
            guard !spoken.isEmpty, !spoken.hasPrefix("Bilinen ") else { continue }
            let item = VoiceTestItem(line: line, section: sectionTitle(section), spoken: spoken)
            if line.contains(failMarker) { failedBefore.append(item) } else { fresh.append(item) }
        }
        return fresh + failedBefore
    }

    /// "Video komutları (2026-10-15)" → "Video komutları".
    static func sectionTitle(_ heading: String) -> String {
        var title = heading
        if let paren = title.range(of: " (") { title = String(title[..<paren.lowerBound]) }
        if let dash = title.range(of: " — ") { title = String(title[..<dash.lowerBound]) }
        return title.trimmingCharacters(in: .whitespaces)
    }

    static func spokenText(_ body: String) -> String {
        var text = body
        // Earlier failure notes are for the file, not for the voice.
        if let marker = text.range(of: " — " + failMarker) { text = String(text[..<marker.lowerBound]) }
        if let log = text.range(of: "Log:") { text = String(text[..<log.lowerBound]) }
        let replacements: [(String, String)] = [
            (#"\(\s*`[^`]*`(?:\s*,\s*`[^`]*`)*\s*\)"#, ""),   // (`5d1702b`)
            (#"`[^`]*`"#, ""),
            (#"https?://\S+"#, ""),
            (#"\*\*|__"#, ""),
            (#"[🟠🟡🔴🟢✅]"#, ""),
            (#"\s*→\s*"#, ", sonra "),
            (#"\(\s*\)"#, ""),
            (#"\s+([,.;:])"#, "$1"),
            (#"[,;:\s—-]+$"#, ""),
            (#"\s{2,}"#, " ")
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes the item's line; nil when the line is no longer in the file.
    static func removing(_ item: VoiceTestItem, from markdown: String) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: item.line) else { return nil }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// Keeps the item and appends "— ❌ sesli test 2026-10-16: kaldı (note)"; returns the new
    /// file and the new line, or nil when the line is no longer in the file.
    static func markingFailed(_ item: VoiceTestItem, note: String?, date: Date, in markdown: String) -> (markdown: String, line: String)? {
        var lines = markdown.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: item.line) else { return nil }
        let day = dayString(date)
        var line = item.line + " — \(failMarker) \(day): kaldı"
        if let note, !note.isEmpty { line += " (\(note))" }
        lines[index] = line
        return (lines.joined(separator: "\n"), line)
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
