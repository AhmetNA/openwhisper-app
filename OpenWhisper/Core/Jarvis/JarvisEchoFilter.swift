import Foundation

/// The mic left open after a command hears Jarvis's own reply first. Whisper writes it back
/// changed ("Saat 22:52, 27 Ekim Salı, patron." → "Saat 22. 25. 27 Ekim salı."), so the reply
/// is matched word by word in order, with numbers and a few misheard words allowed.
enum JarvisEchoFilter {
    /// `transcript` without the part that repeats `reply` at its start; empty when it is only
    /// the reply. Whisper may cut a short reply ("Tamamdır" → "Tamam").
    static func removingEcho(of reply: String?, from transcript: String) -> String {
        guard let reply else { return transcript }
        let replyWords = words(reply)
        let tokens = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !replyWords.isEmpty, !tokens.isEmpty else { return transcript }
        let spoken = tokens.map { words($0).first ?? "" }

        var next = 0
        var matched = 0
        var misses = 0
        var echoEnd = 0
        for (index, word) in spoken.enumerated() {
            guard !word.isEmpty else { continue }
            if let found = (next..<min(next + 3, replyWords.count)).first(where: { same(replyWords[$0], word) }) {
                next = found + 1
                matched += 1
                misses = 0
                if matched >= min(2, replyWords.count), Double(matched) / Double(index + 1) >= 0.6 { echoEnd = index + 1 }
            } else {
                misses += 1
                if misses >= 2 { break }
            }
        }
        guard echoEnd > 0 else { return transcript }
        return tokens.dropFirst(echoEnd).joined(separator: " ")
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4, !a.first!.isNumber, !b.first!.isNumber else { return false }
        return a.prefix(4) == b.prefix(4) || editDistance(a, b) <= 1
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
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
}
