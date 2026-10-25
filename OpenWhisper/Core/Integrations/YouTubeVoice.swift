import AppKit
import Foundation

/// Screen-relative commands read the foreground page afresh; cached recommendations never
/// decide which title is opened after the user scrolls or navigates manually.
enum YouTubeVoice {
    static func normalized(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Confirmed short Whisper mishearings of “YouTube açsana / YouTube'a bakalım”.
    /// Only the voice router uses this: quoted text and keyboard dictation stay literal.
    static func recoveredVoiceRequest(_ text: String) -> BrowserAction? {
        let raw = normalized(WakeWordVerifier.strippingLeadingWakeWord(text))
        let observed: Set<String> = ["yutu vat salam", "yutu ve selenye", "youtube a bakan"]
        if observed.contains(raw) { return .youtubeHome }
        // Accept phonetic site spellings only with an unambiguous, complete opening request.
        let pattern = #"^(?:yutu|yutub|yutup|yutyub|you tube)(?: a| u)? (?:ac|acsana|acalim|bakalim|acar misin)$"#
        return raw.range(of: pattern, options: .regularExpression) != nil ? .youtubeHome : nil
    }

    static func explicit(_ text: String) -> BrowserAction? {
        let raw = normalized(text)
        let homes = ["youtube ac", "youtube a don", "youtube a geri don", "youtube anasayfaya don",
                     "youtube ana sayfasina don", "youtube ana sayfasina git", "youtube anasayfasini ac",
                     "youtube da ne izleyebilirim", "youtube da ne izlesem", "youtube dan video oner",
                     "youtube onerilerini goster", "youtube da bir seyler izleyelim", "youtube a bakalim", "youtube acsana", "youtube u acar misin", "youtube a girsene",
                     "youtube dan bir seyler ac", "youtube onerilerini oku bakalim", "youtube da neyler var",
                     "youtube da guncel videolar neler var", "youtube da hangi videolar var"]
        if homes.contains(raw) { return .youtubeHome }
        // Asking what is on YouTube is an instruction to read recommendations, including
        // the past-tense wording used in conversation, not a capability question.
        let recommendations = #"^(?:youtube|you tube|yutub|yutup) (?:da|dan) (?:ne|neler|neyler)(?: var| vardi| oldugunu)(?: bir)?(?: ara| arat| bak| soyle| oku| goster)?(?: bakalim| lutfen)?$"#
        if raw.range(of: recommendations, options: .regularExpression) != nil { return .youtubeHome }
        if ["youtube daki videolari oku", "youtube da ekranda ne var", "youtube daki basliklari oku"].contains(raw) {
            return .youtubeVisible
        }
        return nil
    }

    /// A chat-generated YouTube question must retain an executable action before asking
    /// for a yes. Only this read-only integration is accepted, never arbitrary model text.
    struct PendingRequest {
        private var action: BrowserAction?
        private var createdAt = Date.distantPast

        mutating func remember(user: String, reply: String, now: Date = Date()) {
            action = nil
            guard normalized(user).contains("youtube"), reply.contains("?") else { return }
            let question = normalized(reply)
            let pattern = #"^(?:sir |patron |efendim )?youtube (?:da|dan) (.+?) aramasi yapip sonuclari okumami mi istiyorsunuz$"#
            if let range = question.range(of: pattern, options: .regularExpression) {
                let matched = String(question[range])
                let query = matched.replacingOccurrences(of: #"^(?:sir |patron |efendim )?youtube (?:da|dan) "#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: " aramasi yapip sonuclari okumami mi istiyorsunuz", with: "")
                // The query must come from the user's words, not from a model invention.
                if !query.isEmpty, normalized(user).contains(query) { action = .search(.youtube, query) }
            } else if question.contains("istiyor"),
                      question.contains("neler var") || question.contains("ne oldugunu") || question.contains("ilk uc") {
                action = .youtubeHome
            }
            createdAt = now
        }

        mutating func take(for answer: String, now: Date = Date()) -> BrowserAction? {
            defer { action = nil }
            guard now.timeIntervalSince(createdAt) <= 120 else { return nil }
            let yes: Set<String> = ["evet", "evet ben istedim", "evet bunu yapmani istiyorum",
                                    "evet bunu yapman istiyor", "evet yap", "tamam", "yap", "aynen", "olur"]
            return yes.contains(YouTubeVoice.normalized(answer)) ? action : nil
        }
    }

    static func navigation(_ text: String) -> VoiceCommand? {
        let raw = normalized(text)
        if ["anasayfaya don", "ana sayfaya don", "ana sayfaya geri don", "anasayfaya git", "ana sayfayi ac", "onerilere don"].contains(raw) {
            return .system(.browser(.youtubeHome))
        }
        if ["ekranda ne var", "videolari oku", "basliklari oku", "onerileri oku", "neler var", "bunlari oku"].contains(raw) {
            return .system(.browser(.youtubeVisible))
        }
        if ["sonraki", "sonrakine gec", "sonrakini ac", "diger videoyu ac"].contains(raw) { return .system(.video(.next)) }
        if ["onceki", "oncekine don", "oncekine gec", "oncekini ac", "onceki videoya don"].contains(raw) { return .system(.video(.previous)) }
        return nil
    }

    static func titleQuery(_ text: String) -> String {
        // Extract the topic only from a complete affirmative video-opening request.
        let request = normalized(WakeWordVerifier.strippingLeadingWakeWord(text))
        let topicPattern = #"^(?:iste |su |bu |ekrandaki )?(.+?)(?: ile|la|le)? ilgili(?: olan)? (?:bir )?video(?: var| var ya|yu|su|sunu)?(?: onu)? (?:ac|acar misin|acabilir misin|oynat)(?: lutfen)?$"#
        if let regex = try? NSRegularExpression(pattern: topicPattern),
           let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
           let range = Range(match.range(at: 1), in: request) {
            return String(request[range])
        }
        var value = WakeWordVerifier.strippingLeadingWakeWord(text)
            .lowercased(with: Locale(identifier: "tr_TR"))
        for pattern in [#"^(?:lütfen |şu |bu |ekrandaki )"#, #"\s+(?:açabilir misin|açar mısın|aç|oynat|başlat|izle)(?: lütfen)?[.!?]*$"#,
                        #"\s+(?:adlı|isimli|başlıklı)(?: videoyu| video)?$"#, #"\s+videosunu$"#,
                        #"['’](?:yı|yi|yu|yü|ı|i|u|ü)$"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return normalized(value)
    }

    /// Full title wins; partial words must identify exactly one card. Never guess ties.
    static func matches(_ query: String, in videos: [YouTubeList.Video]) -> [YouTubeList.Video] {
        let query = titleQuery(query)
        guard !query.isEmpty else { return [] }
        let exact = videos.filter { normalized($0.title) == query }
        if !exact.isEmpty { return exact }
        let words = query.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return [] }
        return videos.filter { video in
            let titleWords = Set(normalized(video.title).split(separator: " ").map(String.init))
            return words.allSatisfy(titleWords.contains)
        }
    }

    // Only visible title links, excluding advertisements, Shorts and hidden cards.
    static let visibleJavaScript = """
    (function(){if(location.hostname!=='www.youtube.com'&&location.hostname!=='youtube.com')return 'outside';\
    var out=[],seen={};document.querySelectorAll('a[href*=watch]').forEach(function(a){\
    if(a.closest('ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer,ytd-promoted-video-renderer,ytd-reel-shelf-renderer,ytd-miniplayer'))return;\
    var r=a.getBoundingClientRect();if(r.width<=0||r.height<=0||r.bottom<=0||r.top>=innerHeight||r.right<=0||r.left>=innerWidth)return;\
    var u=new URL(a.href);if(u.pathname!=='/watch')return;var id=u.searchParams.get('v');\
    var t=(a.getAttribute('title')||a.textContent||'').trim();\
    if(!id||seen[id]||!t||a.querySelector('img,yt-image,yt-thumbnail-view-model'))return;\
    seen[id]=1;out.push({id:id,title:t})});return JSON.stringify(out)})()
    """

    static var visibleScript: String {
        """
        tell application id "com.apple.Safari"
            if (count of windows) = 0 then return "outside"
            try
                return (do JavaScript "\(visibleJavaScript)" in current tab of front window) as text
            on error errText number errNum
                if errNum is 8 then return "jsoff"
                return "outside"
            end try
        end tell
        """
    }

    @MainActor static func snapshot() async -> String {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BrowserController.bundleID else { return "outside" }
        let script = visibleScript
        return await Task.detached { OSAScriptRunner.run(["-e", script], timeout: 4) ?? "outside" }.value
    }

    @MainActor static func contextual(_ text: String) async -> VoiceCommand? {
        let output = await snapshot()
        guard output != "outside", output != "jsoff" else { return nil }
        if let command = navigation(WakeWordVerifier.strippingLeadingWakeWord(text)) { return command }
        if !matches(text, in: YouTubeList.decode(output)).isEmpty { return .system(.browser(.youtubeTitle(text))) }
        return nil
    }

    @MainActor static func readVisible() async -> String {
        let output = await snapshot()
        if output == "jsoff" { return YouTubeList.jsOff }
        let videos = YouTubeList.decode(output)
        guard !videos.isEmpty else { return YouTubeList.notFound }
        return YouTubeList.remember(videos)
    }

    @MainActor static func openTitle(_ query: String) async -> String {
        let output = await snapshot()
        if output == "jsoff" { return YouTubeList.jsOff }
        let candidates = matches(query, in: YouTubeList.decode(output))
        guard candidates.count == 1, let video = candidates.first else {
            return candidates.isEmpty ? YouTubeList.notFound : "Birden fazla video uyuyor; başlığı biraz daha uzun söyle."
        }
        let address = "https://www.youtube.com/watch?v=\(video.id)"
        let script = YouTubeList.replaceTabScript(address)
        let result = await Task.detached { OSAScriptRunner.run(["-e", script], timeout: 4) }.value
        return result == "ok" ? "Açılıyor: \(YouTubeList.shortTitle(video.title))" : YouTubeList.notFound
    }
}
