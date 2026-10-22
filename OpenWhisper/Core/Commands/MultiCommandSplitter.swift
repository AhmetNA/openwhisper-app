import Foundation

/// Several commands in one breath: "sesi kıs ve Bluetooth'u kapat", "Wi-Fi'yi aç, sonra
/// 10 dakikalık alarm kur", "şarkıyı durdur. Ardından ekranı kilitle". Pure, so it is unit-tested.
///
/// The transcript is cut at every place a new command could start (sentence and clause
/// punctuation, "ve", "sonra", "ardından", "bir de", …), then the pieces are grouped back so
/// that every group is a command on its own. Over-cutting is harmless: "10 dakika sonra beni
/// uyar" is cut at "sonra" and grouped back, because "10 dakika" alone is no command. When no
/// grouping into two or more commands exists, `plan` returns nil and the transcript takes the
/// usual single-command route.
enum MultiCommandSplitter {
    struct Step<Command> {
        /// The words of this command, as heard (connectors at its edges dropped).
        let text: String
        let command: Command
    }

    /// More pieces than this is talk, not a list of commands; it also caps the search.
    static let maxPieces = 8

    private static let locale = Locale(identifier: "tr_TR")

    /// Words between two commands. Longest first, so "ve sonra da" is one connector.
    private static let connectors = [
        "ve sonra da", "ve sonra", "ve ardından", "ve daha sonra", "daha sonra", "sonra da",
        "ardından da", "ardından", "ondan sonra", "bir de", "ayrıca", "ve de", "ve", "sonra",
        "hem de", "hem",
    ]
    /// "10 dakika sonra", "iki saat sonra": this "sonra" belongs to the time, not a new command.
    private static let timeUnits: Set<String> = [
        "saniye", "dakika", "dk", "saat", "gün", "hafta", "ay", "yıl", "biraz", "az",
    ]

    /// The cut transcript: pieces in order, each a range of `text`. Groups of neighbouring
    /// pieces are read from `text` itself, so "1,5 saat" survives a cut at its comma.
    static func pieces(of text: String) -> [Range<String.Index>] {
        var cuts: [(start: String.Index, end: String.Index)] = []

        // Punctuation that ends a clause; a comma between digits is a decimal one.
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if ".!?;,".contains(char) {
                let next = text.index(after: index)
                let decimal = char == "," || char == "."
                    ? index > text.startIndex && text[text.index(before: index)].isNumber
                        && next < text.endIndex && text[next].isNumber
                    : false
                if !decimal { cuts.append((index, next)) }
            }
            index = text.index(after: index)
        }

        // Connector words, matched on word boundaries, case-insensitively.
        let lower = text.lowercased(with: locale)
        guard lower.count == text.count else { return [text.startIndex..<text.endIndex] }
        let words = wordRanges(in: lower)
        var w = 0
        while w < words.count {
            var matched = 0
            for connector in connectors {
                let parts = connector.split(separator: " ").map(String.init)
                guard w + parts.count <= words.count,
                      zip(parts, words[w..<w + parts.count]).allSatisfy({ $0 == String(lower[$1]) })
                else { continue }
                if parts.last == "sonra", parts.count == 1 || connector == "daha sonra" {
                    // "10 dakika sonra" / "biraz sonra": part of a time, not a connector.
                    if w > 0, timeUnits.contains(String(lower[words[w - 1]])) { break }
                }
                matched = parts.count
                break
            }
            if matched > 0 {
                let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: words[w].lowerBound))
                let end = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: words[w + matched - 1].upperBound))
                cuts.append((start, end))
                w += matched
            } else {
                w += 1
            }
        }

        cuts.sort { $0.start < $1.start }
        var ranges: [Range<String.Index>] = []
        var from = text.startIndex
        for cut in cuts where cut.start >= from {
            ranges.append(from..<cut.start)
            from = cut.end
        }
        ranges.append(from..<text.endIndex)
        return ranges.filter { !text[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The commands in `text`, in the order said, or nil when it isn't two or more of them.
    /// `parse` reads one candidate group; the grouping with the most commands wins.
    ///
    /// Turkish says the verb once, at the end: "hem Wi-Fi hem Bluetooth'u aç", "Wi-Fi'yi ve
    /// Bluetooth'u kapat". A group that is no command on its own may borrow the last words of
    /// the final piece, when that piece is a command itself; `sharingVerb` reads the result,
    /// so a caller can keep free-text commands ("Tarkan ve Sezen Aksu çal") out of it.
    static func plan<Command>(_ text: String, parse: (String) -> Command?,
                              sharingVerb: (String) -> Command? = { _ in nil }) -> [Step<Command>]? {
        let ranges = pieces(of: text)
        guard ranges.count >= 2, ranges.count <= maxPieces else { return nil }
        let n = ranges.count

        var parsed: [[Step<Command>?]] = Array(repeating: Array(repeating: nil, count: n), count: n)
        for i in 0..<n {
            for j in i..<n {
                let group = clean(String(text[ranges[i].lowerBound..<ranges[j].upperBound]))
                guard !group.isEmpty, let command = parse(group) else { continue }
                parsed[i][j] = Step(text: group, command: command)
            }
        }

        let last = clean(String(text[ranges[n - 1]]))
        let lastWords = last.split(separator: " ")
        if lastWords.count >= 2, parse(last) != nil {
            for i in 0..<(n - 1) {
                for j in i..<(n - 1) where parsed[i][j] == nil {
                    let group = clean(String(text[ranges[i].lowerBound..<ranges[j].upperBound]))
                    guard !group.isEmpty else { continue }
                    // Shortest verb first: "aç", then "açar mısın"; never the whole piece.
                    for k in 1..<lastWords.count {
                        let borrowed = group + " " + lastWords.suffix(k).joined(separator: " ")
                        if let command = sharingVerb(borrowed) {
                            parsed[i][j] = Step(text: borrowed, command: command)
                            break
                        }
                    }
                }
            }
        }

        // best[i]: the most commands pieces i..<n split into, nil when they can't be.
        var best: [[Step<Command>]?] = Array(repeating: nil, count: n + 1)
        best[n] = []
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in i..<n {
                guard let step = parsed[i][j], let rest = best[j + 1] else { continue }
                if rest.count + 1 > (best[i]?.count ?? 0) { best[i] = [step] + rest }
            }
        }
        guard let steps = best[0], steps.count >= 2 else { return nil }
        return steps
    }

    /// A group without the punctuation and connectors left at its edges.
    static func clean(_ group: String) -> String {
        var text = group.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased(with: locale)
            for connector in connectors where lower.hasPrefix(connector + " ") {
                text = String(text.dropFirst(connector.count + 1)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return text
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWordChar = text[index].isLetter || text[index].isNumber || text[index] == "'" || text[index] == "’"
            if isWordChar, start == nil { start = index }
            if !isWordChar, let s = start { ranges.append(s..<index); start = nil }
            index = text.index(after: index)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }
}
