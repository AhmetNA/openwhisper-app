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
    static func plan<Command>(_ text: String, parse: (String) -> Command?) -> [Step<Command>]? {
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

/// One command of a multi-command transcript, read by the same parsers, in the same order, as
/// the single-command route: timer, system, then Spotify. Spotify counts only on the rule gate
/// (no model guess), so a song title with "ve" in it isn't cut into two requests.
enum MultiCommandStep: Equatable {
    case timer(TimerCommandParser.Command)
    case system(SystemCommand)
    /// The Spotify request as `SpotifyManager.handleCommand` should read it.
    case spotify(String)

    static func parse(_ text: String, ringing: Bool, active: Bool,
                      installedApps: [String], shortcuts: () -> [String]) -> MultiCommandStep? {
        if let timer = TimerCommandParser.parse(text, ringing: ringing, active: active) { return .timer(timer) }
        let mentionsShortcut = text.range(of: SystemCommandParser.shortcutMention, options: [.regularExpression, .caseInsensitive]) != nil
        if let system = SystemCommandParser.parse(text, installedApps: installedApps, shortcuts: mentionsShortcut ? shortcuts() : []) {
            // Developer mode opens apps and starts music: only ever on its own.
            return system == .developerMode ? nil : .system(system)
        }
        let spotify = SpotifyManager.commandModeText(
            SpotifyManager.repairPlayVerbMishearing(SpotifyManager.repairVolumeMishearing(text)))
        return SpotifyManager.explicitIntent(in: spotify) != nil ? .spotify(spotify) : nil
    }

    /// Sleep and lock stop the Mac listening, so nothing can run after them.
    var endsSession: Bool {
        guard case .system(let command) = self else { return false }
        return ([.sleep, .displaySleep, .lockScreen] as [SystemCommand]).contains(command)
    }

    /// The commands in `text`, or nil for the single-command route: fewer than two, or one
    /// that ends the session before the last.
    static func plan(_ text: String, ringing: Bool, active: Bool,
                     installedApps: [String], shortcuts: () -> [String]) -> [MultiCommandSplitter.Step<MultiCommandStep>]? {
        var shortcutNames: [String]?
        let steps = MultiCommandSplitter.plan(WakeWordVerifier.strippingLeadingWakeWord(text)) { group in
            parse(group, ringing: ringing, active: active, installedApps: installedApps) {
                if shortcutNames == nil { shortcutNames = shortcuts() }
                return shortcutNames ?? []
            }
        }
        guard let steps, !steps.dropLast().contains(where: { $0.command.endsSession }) else { return nil }
        return steps
    }
}
