import Foundation

/// Fixes names Whisper keeps mangling in Turkish speech ("Sputfayda", "Pöt fayda" for
/// "Spotify'da") in one place, before routing, so a mangled name no longer turns a Spotify
/// command into dictation.
///
/// One line per name in `fileURL`: `Spotify [spotifay] = sputfayda, pöt fayda`. The listed
/// variants always match; a single-word name with a spoken form in brackets also catches new
/// variants that sound close to it, so the list does not have to grow one mishearing at a time.
/// A Turkish suffix is kept: "Sputfayda" → "Spotify'da".
///
/// Lines under an `@Claude` header apply only while that app is in front (`AppFocus`), so
/// "cloud" becomes Claude in Claude and stays "cloud" everywhere else.
enum SoundAlikeCorrector {
    struct Entry: Equatable {
        let canonical: String
        /// How it sounds in Turkish, for the fuzzy match; nil = listed variants only.
        let spoken: String?
        let variants: [String]
        /// The app this line belongs to (its `@Name` header); nil = every app.
        var app: String? = nil
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper/ses-benzerleri.txt")
    }

    static let defaultFile = """
        # Sesi benzeyen yanlış yazımları topluca düzeltir (Jarvis komutlarından önce uygulanır).
        # Her satır: Doğru yazım [Türkçe okunuşu] = bozuk hali, bozuk hali, ...
        # Köşeli parantezli okunuş verilirse listede olmayan benzer bozulmalar da düzelir.
        # Türkçe ekler korunur: "Sputfayda" → "Spotify'da". Değişiklik bir sonraki kayıtta geçerli olur.
        # "@Uygulama" başlığının altındaki satırlar yalnızca o uygulama öndeyken uygulanır.

        Spotify [spotifay] = supotufy, spatfa, sputfay, pöt fay, pot fay, kutfai, kutfay, spotfader, spotfay, spot fay, spatfay
        WhatsApp [vatsap] = vatsap, vatsab, whatsap, vots app
        YouTube [yutub] = yutub, yutup, you tube
        Bluetooth [blutut] = blutut, bulutut, blu tut

        @Claude
        Claude [klod] = cloud, klod, klot, clod, clode, claud, klaud
        Claude Code = cloudcode, cloud code, klod kod
        Claude.md = cloudmd, cloud md, cloud.md
        """

    /// Read once per recording; the file is tiny.
    static func loadEntries() -> [Entry] {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? defaultFile.write(to: url, atomically: true, encoding: .utf8)
        }
        return parse((try? String(contentsOf: url, encoding: .utf8)) ?? defaultFile)
    }

    static func parse(_ contents: String) -> [Entry] {
        var app: String?
        return contents.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@") {
                let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
                app = name.isEmpty ? nil : name
                return nil
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            var head = line[..<eq].trimmingCharacters(in: .whitespaces)
            var spoken: String?
            if let open = head.firstIndex(of: "["), let close = head.firstIndex(of: "]"), open < close {
                spoken = String(head[head.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                head = head[..<open].trimmingCharacters(in: .whitespaces)
            }
            let variants = line[line.index(after: eq)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !head.isEmpty else { return nil }
            return Entry(canonical: head, spoken: spoken?.isEmpty == false ? spoken : nil, variants: variants, app: app)
        }
    }

    /// Returns the corrected text and the (heard, written) pairs that changed. Two-word
    /// `keeping` names ("Google Cloud") are left whole, also with a suffix ("Google Cloud'da").
    static func correct(_ text: String, entries: [Entry], keeping: [String] = []) -> (String, [(String, String)]) {
        guard !entries.isEmpty else { return (text, []) }
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var applied: [(String, String)] = []
        var index = 0
        let kept = keeping.compactMap { name -> (String, String)? in
            let parts = name.split(separator: " ").map { fold(String($0)) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        while index < words.count {
            if index + 1 < words.count {
                let first = fold(words[index]), second = fold(words[index + 1])
                if kept.contains(where: { first == $0.0 && second.hasPrefix($0.1) }) {
                    output += [words[index], words[index + 1]]
                    index += 2
                    continue
                }
            }
            // Two words first: Whisper often splits the name ("pöt fayda"). Not when the first
            // word already ends the name ("Cloud'a sor", "Spotify, aç") or already is it
            // ("Spotify 5" lost the 5).
            if index + 1 < words.count, !words[index].contains(where: { $0 == "'" || $0 == "’" || ($0.isPunctuation) }),
               !entries.contains(where: { fold($0.canonical) == fold(words[index]) }),
               let fixed = replacement(for: words[index] + words[index + 1], entries: entries) {
                applied.append((words[index] + " " + words[index + 1], fixed))
                output.append(fixed)
                index += 2
                continue
            }
            if let fixed = replacement(for: words[index], entries: entries) {
                applied.append((words[index], fixed))
                output.append(fixed)
            } else {
                output.append(words[index])
            }
            index += 1
        }
        return (output.joined(separator: " "), applied)
    }

    /// "Sputfayda," → "Spotify'da,", or nil when the word is not a variant.
    private static func replacement(for word: String, entries: [Entry]) -> String? {
        let trailing = String(word.reversed().prefix { $0.isPunctuation && $0 != "'" && $0 != "’" }.reversed())
        let core = String(word.dropLast(trailing.count))
        guard !core.isEmpty else { return nil }
        // An apostrophe already marks the suffix ("Spotifay'da").
        let parts = core.split(whereSeparator: { $0 == "'" || $0 == "’" }).map(String.init)
        let root = fold(parts.first ?? core)
        let apostropheSuffix = parts.count > 1 ? parts[1] : nil

        for entry in entries where fold(entry.canonical) != root {
            if let suffix = apostropheSuffix {
                if matches(root, entry) { return entry.canonical + "'" + suffix + trailing }
                continue
            }
            // Suffix first, longest first: the whole word "sputfayda" also sounds close enough,
            // and matching it would drop the "'da".
            for suffix in CorrectionEngine.turkishSuffixes where root.hasSuffix(fold(suffix)) && root.count > suffix.count + 3 {
                let stem = String(root.dropLast(fold(suffix).count))
                if matches(stem, entry) {
                    let originalSuffix = String(core.suffix(suffix.count))
                    return entry.canonical + "'" + originalSuffix + trailing
                }
            }
            if matches(root, entry) { return entry.canonical + trailing }
        }
        return nil
    }

    private static func matches(_ candidate: String, _ entry: Entry) -> Bool {
        if entry.variants.contains(where: { fold($0).replacingOccurrences(of: " ", with: "") == candidate }) { return true }
        // Fuzzy only for one-word names with a spoken form, and only for words long enough
        // that a near miss can't be an everyday Turkish word.
        guard let spoken = entry.spoken, !entry.canonical.contains(" "), candidate.count >= 5 else { return false }
        let target = fold(spoken).replacingOccurrences(of: " ", with: "")
        // A short spoken form is only one letter away from everyday words: "bulut(ta)"
        // → Bluetooth'ta and "varsa" → WhatsApp (Oct 2026). Below 7 letters, one edit at most.
        // At 40% a long one was too loose as well: "sayfay(ı)" is three edits from "spotifay"
        // and "Bu sayfayı özetle" became "Bu Spotify'ı özetle" (Oct 2026).
        let allowed = target.count < 7 ? 1 : Int(Double(target.count) * 0.3)
        return WakeWordVerifier.editDistance(candidate, target) <= allowed
    }

    /// Lowercased, Turkish letters folded to plain ASCII; "y" reads as "i" ("fay" ≈ "fai").
    static func fold(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased(with: Locale(identifier: "tr_TR")) {
            switch ch {
            case "ş": out.append("s")
            case "ç": out.append("c")
            case "ğ": break
            case "ı", "y", "î": out.append("i")
            case "ö": out.append("o")
            case "ü", "û": out.append("u")
            case "â": out.append("a")
            default: if ch.isLetter || ch.isNumber || ch == " " { out.append(ch) }
            }
        }
        return out
    }
}
