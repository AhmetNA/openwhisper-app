import Foundation

/// "YouTube'da ne var?" / "YouTube'da lofi ara": reads the first three videos of the home page
/// or the results aloud with their channels ("Barış Özcan bir video atmış: Koç nereye"), and
/// keeps them so "ikinciyi aç" or "Barış Özcan'ın videosunu aç" opens one. The page is read
/// through `do JavaScript`, never by clicking, so it also works from across the room.
enum YouTubeList {
    struct Video: Equatable, Sendable, Decodable {
        let id: String
        let title: String
        /// The channel's name as the page shows it; nil where the page has none.
        let channel: String?

        init(id: String, title: String, channel: String? = nil) {
            self.id = id
            self.title = title
            self.channel = channel
        }
    }

    /// How many are read at once; "başka" reads the next ones.
    static let pageSize = 3
    /// "İkinciyi aç" still works this long after the list was read, with the wake word.
    static let lifetime: TimeInterval = 10 * 60

    nonisolated static let notFound = "YouTube'da video bulamadım"
    nonisolated static let noList = "Okunmuş bir video listesi yok"
    nonisolated static let outOfRange = "Listede o sırada video yok"
    nonisolated static let noMore = "Başka video yok"
    nonisolated static let jsOff = "Safari'de Apple Events'ten JavaScript'e izin kapalı"
    nonisolated static let failures: Set<String> = [notFound, noList, outOfRange, noMore, jsOff]

    @MainActor private static var videos: [Video] = []
    @MainActor private static var offset = 0
    @MainActor private static var listedAt: Date?

    // MARK: - Actions

    /// Opens `url` in Safari, waits for its videos and reads the first three. `path` is the
    /// page they must come from ("/" or "/results"), so the page that was open before isn't read.
    @MainActor static func read(_ url: URL, path: String, opened: (URL) async -> String) async -> String {
        let status = await opened(url)
        guard !BrowserController.failures.contains(status) else { return status }
        let script = readScript(path: path)
        let deadline = Date().addingTimeInterval(10)
        var found: [Video] = []
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(600))
            let output = await Task.detached { OSAScriptRunner.run(["-e", script], timeout: 4) }.value
            if output == "jsoff" { return jsOff }
            found = decode(output ?? "")
            if found.count >= pageSize + 3 { break }
            // The grid fills in as it loads; three are enough once nothing new came for a while.
            if found.count >= pageSize, Date() > deadline.addingTimeInterval(-6) { break }
        }
        owLog("[YouTube] \(found.count) videos on \(path): \(found.prefix(pageSize).map(\.title))")
        guard !found.isEmpty else { return notFound }
        videos = found
        offset = 0
        listedAt = Date()
        return listing(videos, from: 0)
    }

    /// "Başka": the next three of the same list.
    @MainActor static func more() -> String {
        guard isFresh else { return noList }
        guard offset + pageSize < videos.count else { return noMore }
        offset += pageSize
        listedAt = Date()
        return listing(videos, from: offset)
    }

    /// `number` counts from the top of the whole list (so after "başka", "dördüncü" is the
    /// first of the new three); 0 = the last one read.
    @MainActor static func play(_ number: Int, opened: (URL) async -> String) async -> String {
        guard isFresh else { return noList }
        let index = number == 0 ? min(offset + pageSize, videos.count) - 1 : number - 1
        guard videos.indices.contains(index) else { return outOfRange }
        let video = videos[index]
        let address = "https://www.youtube.com/watch?v=\(video.id)"
        // The tab that shows the list becomes the video; any other tab is left alone.
        let reused = await Task.detached { OSAScriptRunner.run(["-e", replaceTabScript(address)], timeout: 4) }.value
        let done = "Açılıyor: \(shortTitle(video.title))"
        if reused == "ok" {
            owLog("[YouTube] Opened \(address) in the list's tab")
            return done
        }
        guard let url = URL(string: address) else { return "Adres açılamadı" }
        let status = await opened(url)
        return BrowserController.failures.contains(status) ? status : done
    }

    /// "YouTube'u aç" with a video open in Safari: its tab comes to the front as it is, never
    /// reloaded; a paused video plays on from where it was, a playing one is left alone.
    /// nil when no tab has a video, so the home page opens instead.
    static func returnToVideo() async -> String? {
        let result = await Task.detached { OSAScriptRunner.run(["-e", videoTabScript], timeout: 4) }.value
        owLog("[YouTube] Back to the video tab → \(result ?? "script failed")")
        switch result {
        case "playing": return "YouTube'daki videoya geçildi"
        case "started": return "Video kaldığı yerden devam ediyor"
        case "switched": return "YouTube'daki videoya geçildi"
        default: return nil
        }
    }

    static let videoTabScript = """
        if application id "com.apple.Safari" is not running then return "missing"
        tell application id "com.apple.Safari"
            set found to missing value
            set foundWindow to missing value
            try
                if URL of current tab of front window contains "youtube.com/watch" then
                    set found to current tab of front window
                    set foundWindow to front window
                end if
            end try
            if found is missing value then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if URL of t contains "youtube.com/watch" then
                                set found to contents of t
                                set foundWindow to contents of w
                                exit repeat
                            end if
                        end try
                    end repeat
                    if found is not missing value then exit repeat
                end repeat
            end if
            if found is missing value then return "missing"
            set current tab of foundWindow to found
            set index of foundWindow to 1
            activate
            try
                return (do JavaScript "(function(){var v=document.querySelector('video');if(!v)return 'switched';if(v.paused&&!v.ended){v.play();return 'started'}return 'playing'})()" in found) as text
            on error
                return "switched"
            end try
        end tell
        """

    /// Read the live page, including the right-hand recommendations on /watch. Never
    /// choose from the old spoken-list cache: the user may have navigated or scrolled.
    @MainActor static func playTitle(_ title: String) async -> String? {
        let tab = await Task.detached {
            OSAScriptRunner.run(["-e", BrowserController.youTubeTabScript], timeout: 4)
        }.value
        guard tab != "missing" else { return nil }
        guard tab == "found" else { return "Safari'ye ulaşılamadı" }
        let script = readScript(path: nil, visibleOnly: true)
        let output = await Task.detached { OSAScriptRunner.run(["-e", script], timeout: 4) }.value
        if output == "jsoff" { return jsOff }
        guard let video = bestMatch(title, in: decode(output ?? "")) else { return nil }
        let address = "https://www.youtube.com/watch?v=\(video.id)"
        let result = await Task.detached {
            OSAScriptRunner.run(["-e", replaceTabScript(address)], timeout: 4)
        }.value
        guard result == "ok" else { return "Adres açılamadı" }
        owLog("[YouTube] Title match '\(title)' → '\(video.title)'")
        return "Açılıyor: \(shortTitle(video.title))"
    }

    /// Query-word coverage favors partial titles; edit distance tolerates ASR spelling.
    /// Two clearly heard words are enough when Whisper garbled the rest ("Mantra Ertuğrul
    /// Buzokey maçını" → "Mantra | Erzurum, Buz Hokeyi"). Equal scores keep the on-screen
    /// order, rather than selecting randomly.
    static func bestMatch(_ query: String, in candidates: [Video]) -> Video? {
        func tokens(_ text: String) -> [String] {
            // "Orkun'un" → "orkunun", "Soy'dan" → "soydan": one word, as the name is written.
            words(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
                .replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "ı", with: "i"))
                .filter { !["video", "videosu", "videoyu", "videosunu", "olan", "bir", "bu", "şu"].contains($0) }
        }
        func similarity(_ a: String, _ b: String) -> Double {
            if a == b { return 1 }
            guard a.count >= 4, b.count >= 4 else { return 0 }
            // "orkunun" / "özcan'ın": a name with a case ending.
            if a.hasPrefix(b) { return 0.95 }
            let left = Array(a), right = Array(b)
            var row = Array(0...right.count)
            for (i, x) in left.enumerated() {
                var next = [i + 1] + Array(repeating: 0, count: right.count)
                for (j, y) in right.enumerated() {
                    next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))
                }
                row = next
            }
            let score = 1 - Double(row[right.count]) / Double(max(left.count, right.count))
            return score >= 0.65 ? score : 0
        }
        let queryWords = tokens(query)
        guard !queryWords.isEmpty else { return nil }
        var best: Video?
        var bestScore = 0.0
        for video in candidates {
            let single = tokens(video.title + " " + (video.channel ?? ""))
            // "Buz Hokeyi" heard as one word, "buzokey".
            let titleWords = single + zip(single, single.dropFirst()).map { $0 + $1 }
            let scores = queryWords.map { q in titleWords.map { similarity(q, $0) }.max() ?? 0 }
            let coverage = scores.reduce(0, +) / Double(queryWords.count)
            let clear = zip(queryWords, scores).filter { $0.count >= 4 && $1 >= 0.75 }.count
            if coverage > 0.64 || clear >= 2, coverage > bestScore {
                bestScore = coverage
                best = video
            }
        }
        return best
    }

    /// The list read last, while "ikinciyi aç" still refers to it.
    @MainActor static var listed: [Video] { isFresh ? videos : [] }

    /// "Barış Soydan'ı açabilir miyiz", "Orkun'un videosunu aç": the name or title said, when
    /// it is one of `listed`. Anything else ("Safari'yi aç") is left to the other commands.
    static func named(in text: String, listed: [Video]) -> String? {
        let raw = text.lowercased(with: locale)
            .replacingOccurrences(of: #"[.,!?;"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:(?:hey )?jarvis )?(.+?) (?:videosunu |videoyu )?(?:aç|açar mısın|açabilir misin|açabilir miyiz|açalım|oynat|oynatır mısın|izleyelim|izleyebilir miyiz)(?: lütfen)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        let name = String(raw[range])
        return bestMatch(name, in: listed) == nil ? nil : name
    }

    @MainActor private static var isFresh: Bool {
        guard let listedAt, !videos.isEmpty else { return false }
        return Date().timeIntervalSince(listedAt) < lifetime
    }

    // MARK: - Text

    /// "Orkun Işıtmak bir video atmış: Kendi yapay zekamı yaptım. Barış Özcan da bir video
    /// atmış: Koç nereye. Bir de şu var: Lofi radio." The order stays, so "ikinciyi aç" still
    /// counts from the top of the whole list.
    static func listing(_ videos: [Video], from start: Int) -> String {
        videos.indices.dropFirst(start).prefix(pageSize).enumerated().map { place, index in
            var title = shortTitle(videos[index].title)
            if !title.hasSuffix("?") { title += "." }
            let channel = videos[index].channel.map(shortTitle) ?? ""
            // Search results are often one channel; its name is said once.
            let repeated = place > 0 && videos[index - 1].channel.map(shortTitle) == channel
            guard !channel.isEmpty, !repeated else {
                return place == 0 ? "\(firstUnnamed)\(title)" : "Bir de şu var: \(title)"
            }
            return place == 0 ? "\(channel)\(postedMarker)\(title)" : "\(channel) \(also(channel))\(postedMarker)\(title)"
        }.joined(separator: " ")
    }

    private static let postedMarker = " bir video atmış: "
    private static let firstUnnamed = "Şu video var: "

    /// "da" or "de" after a name, by its last vowel.
    private static func also(_ name: String) -> String {
        let last = name.lowercased(with: locale).last { "aeıioöuü".contains($0) }
        return last.map { "eiöü".contains($0) } == true ? "de" : "da"
    }

    /// Whether `status` is a list read by `listing`, said in full rather than acked.
    static func isListing(_ status: String) -> Bool {
        status.hasPrefix(firstUnnamed) || status.contains(postedMarker)
    }

    /// Titles are long and loud: "🔥 SEZEN AKSU - Gidiyorum (Official Video) | 4K #pop" →
    /// "Sezen aksu - Gidiyorum". Emojis go; the tail after "(", "[", "|" or "#" goes; after a
    /// dash only when three words already came before it, so "Artist - Song" stays whole.
    static func shortTitle(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmoji && scalar.value >= 0x2190) && scalar.value != 0xFE0F && scalar.value != 0x200D
        }
        var title = String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        func wordCount(_ text: Substring) -> Int {
            text.split(separator: " ").filter { $0.contains(where: \.isLetter) }.count
        }
        let hard = ["(", "[", "【", "|", "#", " ft.", " feat.", " Ft.", " Feat."]
        if let cut = hard.compactMap({ title.range(of: $0)?.lowerBound })
            .filter({ wordCount(title[..<$0]) >= 1 }).min() {
            title = String(title[..<cut])
        }
        for dash in [" - ", " – ", " — ", " ~ ", " // "] {
            if let range = title.range(of: dash), wordCount(title[..<range.lowerBound]) >= 3 {
                title = String(title[..<range.lowerBound])
                break
            }
        }
        let letters = title.filter(\.isLetter)
        if letters.count > 4, Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.7 {
            // All caps is read letter by letter or shouted.
            let lower = title.lowercased(with: locale)
            title = lower.prefix(1).uppercased(with: locale) + lower.dropFirst()
        }
        let words = title.split(separator: " ")
        if words.count > 8 { title = words.prefix(8).joined(separator: " ") }
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " :,;-–—!.|/"))
    }

    // MARK: - Picking by voice

    private static let locale = Locale(identifier: "tr_TR")

    private static let ordinals: [(stems: [String], number: Int)] = [
        (["ilk", "birinci"], 1), (["ikinci"], 2), (["üçüncü", "ucuncu"], 3), (["dördüncü", "dorduncu"], 4),
        (["beşinci", "besinci"], 5), (["altıncı", "altinci"], 6), (["yedinci"], 7), (["sekizinci"], 8),
        (["dokuzuncu"], 9), (["onuncu"], 10), (["sonuncu"], 0),
    ]
    private static let playVerbs = ["aç", "ac", "açar", "açalım", "oynat", "izle", "başlat", "baslat"]
    /// Words that may stand around the number: "ikinci videoyu aç", "ilk öneriyi açar mısın".
    private static let fillerStems = ["video", "olan", "öneri", "oneri", "sonuç", "sonuc", "youtube"]
    private static let fillers: Set<String> = [
        "onu", "şunu", "bunu", "tane", "jarvis", "hey", "lütfen", "hadi", "tamam", "o", "şu", "bu",
        "mısın", "misin", "musun", "da", "de", "dan", "den", "en",
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased(with: locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func number(of word: String) -> Int? {
        if let digit = Int(word), (1...15).contains(digit) { return digit }
        if word == "son" { return 0 }
        return ordinals.first { $0.stems.contains { word.hasPrefix($0) } }?.number
    }

    private static func isVerb(_ word: String) -> Bool {
        playVerbs.contains(word) || ["oynat", "izle", "başlat", "baslat"].contains { word.hasPrefix($0) }
    }

    /// "İkinciyi aç", "2. videoyu oynat", "sonuncuyu aç" → 2, 2, 0 (0 = the last one read).
    /// Without `verb` a bare "ikincisi" counts too (right after the list was read). Anything
    /// else in the sentence ("ikinci sekmeyi aç") makes it some other command.
    static func pick(in text: String, requireVerb: Bool) -> Int? {
        let words = words(text)
        var number: Int?
        var hasVerb = false
        for word in words {
            if let value = self.number(of: word) {
                guard number == nil else { return nil }
                number = value
            } else if isVerb(word) {
                hasVerb = true
            } else if !fillers.contains(word), !fillerStems.contains(where: { word.hasPrefix($0) }) {
                return nil
            }
        }
        guard let number, hasVerb || !requireVerb else { return nil }
        return number
    }

    /// A bare "aç" / "onu aç" right after the list: the first one.
    static func isBarePlay(_ text: String) -> Bool {
        let words = words(text).filter { !fillers.contains($0) }
        return !words.isEmpty && words.allSatisfy(isVerb)
    }

    /// "Başka", "diğerlerini oku", "sonraki üç": the next three.
    static func isMore(_ text: String) -> Bool {
        let words = words(text).filter { !fillers.contains($0) }
        let triggers = ["başka", "baska", "diğer", "diger", "sonraki", "devam", "daha"]
        let allowed = triggers + ["fazla", "oku", "söyle", "soyle", "göster", "goster", "var", "mı", "mi",
                                  "üç", "3", "öneri", "oneri", "video", "sonuç", "sonuc", "ver", "et"]
        guard words.count <= 5, words.contains(where: { word in triggers.contains { word.hasPrefix($0) } }) else { return false }
        return words.allSatisfy { word in allowed.contains { word.hasPrefix($0) } }
    }

    // MARK: - Safari

    static func decode(_ output: String) -> [Video] {
        guard let data = output.data(using: .utf8),
              let raw = try? JSONDecoder().decode([Video].self, from: data) else { return [] }
        return raw.compactMap { video in
            let title = video.title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            // A thumbnail's "12:34" badge is no title.
            guard title.contains(where: \.isLetter) else { return nil }
            let channel = video.channel?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return Video(id: video.id, title: title, channel: channel?.isEmpty == false ? channel : nil)
        }
    }

    /// The `/watch` links of the page in order, one per video, as JSON. Ads, Shorts, side
    /// shelves and the miniplayer are skipped; a link around a thumbnail carries no title.
    /// No double quotes or backslashes: it goes inside `do JavaScript "…"`.
    static func readJavaScript(path: String?, visibleOnly: Bool = false) -> String {
        let pageGuard = path.map { "if(location.pathname!=='\($0)')return '[]';" } ?? ""
        let visibility = visibleOnly ? "var r=a.getBoundingClientRect();if(r.width<=0||r.height<=0||r.bottom<=0||r.top>=innerHeight||r.right<=0||r.left>=innerWidth)continue;" : ""
        return """
        (function(){if(location.hostname!=='youtube.com'&&!location.hostname.endsWith('.youtube.com'))return '[]';\(pageGuard)var out=[],seen={};\
        var as=document.querySelectorAll('a[href*=watch]');\
        for(var i=0;i<as.length&&out.length<\(visibleOnly ? 100 : 15);i++){var a=as[i];\(visibility)\
        if(a.closest('ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer,ytd-promoted-video-renderer,\
        ytd-reel-shelf-renderer,ytd-rich-shelf-renderer,ytd-shelf-renderer,ytd-horizontal-card-list-renderer,\
        ytd-miniplayer,ytd-guide-renderer'))continue;\
        if(a.querySelector('img,yt-image,yt-thumbnail-view-model'))continue;\
        var u;try{u=new URL(a.href)}catch(e){continue}\
        if(u.pathname!=='/watch'||u.searchParams.get('start_radio'))continue;\
        var id=u.searchParams.get('v');if(!id||seen[id])continue;\
        var t=(a.getAttribute('title')||a.textContent||'').trim();if(!t)continue;\
        var c='',box=a.closest('ytd-rich-item-renderer,ytd-video-renderer,ytd-compact-video-renderer,ytd-grid-video-renderer,yt-lockup-view-model');\
        if(box){var cs=box.querySelectorAll('a');for(var j=0;j<cs.length&&!c;j++){\
        var h=cs[j].getAttribute('href')||'';if(h.indexOf('/@')===0||h.indexOf('/channel/')===0)c=(cs[j].textContent||'').trim()}}\
        seen[id]=1;out.push({id:id,title:t,channel:c})}\
        return JSON.stringify(out)})()
        """
    }

    /// Error 8 = "Allow JavaScript from Apple Events" is off.
    static func readScript(path: String?, visibleOnly: Bool = false) -> String {
        """
        tell application id "com.apple.Safari"
            try
                return (do JavaScript "\(readJavaScript(path: path, visibleOnly: visibleOnly))" in current tab of front window) as text
            on error errText number errNum
                if errNum is 8 then return "jsoff"
                return "[]"
            end try
        end tell
        """
    }

    static func replaceTabScript(_ address: String) -> String {
        """
        tell application id "com.apple.Safari"
            if (count of windows) > 0 then
                set t to current tab of front window
                if URL of t contains "youtube.com" then
                    set URL of t to "\(address)"
                    return "ok"
                end if
            end if
        end tell
        return "open"
        """
    }
}
