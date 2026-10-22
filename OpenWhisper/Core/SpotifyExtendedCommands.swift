import Foundation

/// What "bu şarkıyı tekrarla" / "listeyi tekrarla" / "tekrarı kapat" set.
enum SpotifyRepeatMode: String, Equatable, Sendable {
    case track, context, off
}

/// "30 saniye ileri sar" (by), "şarkıyı başa sar" / "2. dakikaya git" (to), in seconds.
enum SpotifySeek: Equatable, Sendable {
    case by(Int)
    case to(Int)
}

/// Where "müziği telefona geçir" sends playback, matched against Spotify Connect device types.
enum SpotifyDeviceKind: String, Equatable, Sendable {
    case phone, speaker, computer, tv, tablet

    /// Spotify's `type` values for this kind.
    var connectTypes: Set<String> {
        switch self {
        case .phone: return ["smartphone"]
        case .speaker: return ["speaker", "castaudio", "avr", "stb", "audiodongle"]
        case .computer: return ["computer"]
        case .tv: return ["tv", "castvideo"]
        case .tablet: return ["tablet"]
        }
    }

    var spokenName: String {
        switch self {
        case .phone: return "telefon"
        case .speaker: return "hoparlör"
        case .computer: return "bilgisayar"
        case .tv: return "televizyon"
        case .tablet: return "tablet"
        }
    }
}

/// Questions about what plays, answered aloud.
enum SpotifyQuestion: Equatable, Sendable {
    case album, timeLeft, nextUp, device
}

/// Commands the rules below decide alone: each phrase is matched whole (anchored), so a
/// sentence that merely contains the words stays dictation. The models never see these
/// intents (`isRuleOnly`), because SetFit and the LLM only know the older labels and read
/// "karışık çal" as a search for "karışık".
extension SpotifyManager {
    // MARK: Building blocks (on `normalize`d text)

    private static let spotifyWord = #"spotify(?:'?\p{L}*)?"#
    private static let lead = #"^(?:(?:hadi|lütfen|jarvis)\s+)*(?:"# + spotifyWord + #"\s+)?"#
    private static let tail = #"(?:\s+(?:lütfen|hemen|şimdi|artık))*$"#
    private static let playVerb = #"(?:aç|çal|başlat|oynat|dinlet)"#
    private static let songObject = #"(?:(?:bu|çalan|şu anki|şuanki)\s+)?(?:şarkıyı|parçayı)"#
    private static let caseSuffix = #"(?:'?(?:yı|yi|yu|yü|nı|ni|nu|nü|ı|i|u|ü))?"#
    private static let ordinals: [String: Int] = [
        "birinci": 1, "ikinci": 2, "üçüncü": 3, "dördüncü": 4, "beşinci": 5,
        "altıncı": 6, "yedinci": 7, "sekizinci": 8, "dokuzuncu": 9, "onuncu": 10
    ]

    private static func match(_ pattern: String, _ text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(result.numberOfRanges, 1)).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { match(lead + $0 + tail, text) != nil }
    }

    // MARK: Rules

    /// The rule-only intents, or nil. `normalized` is `normalize(text)`. A playlist named
    /// like Liked Songs means the user's own collection.
    static func extendedIntent(_ normalized: String) -> ExplicitSpotifyIntent? {
        switch extendedRuleIntent(normalized) {
        case .playOwnPlaylist(let name)? where SpotifyRequestParser.namesLikedSongs(name):
            return .playLikedSongs
        case .addCurrentTrackToPlaylist(let name)? where SpotifyRequestParser.namesLikedSongs(name):
            return .likeCurrentTrack
        case let intent:
            return intent
        }
    }

    private static func extendedRuleIntent(_ normalized: String) -> ExplicitSpotifyIntent? {
        let t = normalized

        if let sleep = sleepTimer(t) { return sleep }

        if matches(t, [
            #"(?:(?:müziği|şarkıları|listeyi)\s+)?karışık\s+(?:çal|çalmayı\s+(?:aç|başlat)|çalma\s+modunu\s+aç|moda\s+(?:al|geç))"#,
            #"(?:müziği|şarkıları|listeyi)\s+karıştır"#,
            #"shuffle'?ı?\s+aç"#
        ]) { return .setShuffle(true) }
        if matches(t, [
            #"(?:karışık\s+çalmayı|karışık\s+çalma\s+modunu|karıştırmayı|shuffle'?ı?)\s+(?:kapat|durdur|bırak)"#,
            #"(?:(?:müziği|şarkıları|listeyi)\s+)?sırayla\s+çal"#
        ]) { return .setShuffle(false) }

        if matches(t, [
            songObject + #"\s+(?:tekrarla|tekrar\s+tekrar\s+çal|döngüye\s+al|sürekli\s+çal)"#,
            #"(?:tekrarı|tekrar\s+modunu)\s+şarkıya\s+(?:al|ayarla)"#
        ]) { return .setRepeat(.track) }
        if matches(t, [
            #"(?:(?:bu)\s+)?(?:listeyi|albümü|çalma\s+listesini|hepsini)\s+(?:tekrarla|tekrar\s+tekrar\s+çal|döngüye\s+al|sürekli\s+çal)"#
        ]) { return .setRepeat(.context) }
        if matches(t, [
            #"(?:tekrarı|tekrarlamayı|tekrar\s+modunu|tekrarlama\s+modunu|döngüyü)\s+(?:kapat|durdur|bırak)"#,
            #"(?:şarkıyı\s+)?tekrarlamayı\s+(?:bırak|durdur|kes)"#
        ]) { return .setRepeat(.off) }
        // Whisper drops the accusative: "Spotify'da tekrarı kapat" → "… tekrar kapat", which
        // the pause rule took. Only with Spotify named: "tekrar kapat" alone is "close again".
        if match("^" + spotifyWord + #"\s+tekrar\s+(?:modunu\s+)?kapat"# + tail, t) != nil { return .setRepeat(.off) }

        if let seek = seek(t) { return .seek(seek) }

        if matches(t, [
            #"(?:(?:bunu|"# + songObject + #")\s+)?(?:beğenilen\s+şarkılardan|beğenilenlerden|beğenilenlerimden|beğendiklerimden|beğenilerimden|favorilerimden|favorilerden)\s+(?:çıkar|kaldır|sil)"#,
            #"(?:(?:bunu|"# + songObject + #")\s+)?beğenmekten\s+vazgeç"#,
            #"(?:(?:bu|çalan)\s+)?(?:şarkının\s+)?beğenisini\s+(?:kaldır|geri\s+al)"#
        ]) { return .unlikeCurrentTrack }

        if let volume = match(#"^(?:spotify'ın|spotifyın|spotify'nin|spotify)\s+(?:kendi\s+sesini|kendi\s+ses\s+seviyesini|uygulama\s+sesini|içindeki\s+sesi)\s+(?:yüzde\s+|%\s*)?(\d{1,3})(?:'?(?:e|a|ye|ya))?\s+(?:yap|ayarla|getir|indir|çıkar|düşür|yükselt)"# + tail, t)?
            .first.flatMap({ $0 }).flatMap(Int.init), (0...100).contains(volume) {
            return .setSpotifyVolume(volume)
        }

        // "Spor çalma listemi aç", "Spor listemi çal": the user's own playlist. A bare "X
        // listemi aç" may be any list, so `runtimeCandidate` checks the playlist exists.
        if let name = match(lead + #"(.+?)\s+(?:çalma\s+listemi|playlistimi)\s+"# + playVerb + tail, t)?.first ?? nil
            ?? (match(lead + #"(.+?)\s+listemi\s+(?:çal|oynat|dinlet)"# + tail, t)?.first ?? nil)
            ?? (match(lead + #"(?:çalma\s+listelerimden|playlistlerimden)\s+(.+?)"# + caseSuffix + #"\s+"# + playVerb + tail, t)?.first ?? nil),
           let cleaned = playlistName(name) {
            return .playOwnPlaylist(cleaned)
        }
        if let name = match(lead + songObject + #"\s+(.+?)\s+(?:çalma\s+)?(?:listeme|listesine|playlistime|playlistine)\s+(?:de\s+)?ekle"# + tail, t)?.first ?? nil,
           let cleaned = playlistName(name) {
            return .addCurrentTrackToPlaylist(cleaned)
        }

        if matches(t, [
            #"(?:kaydettiğim|kayıtlı|kütüphanemdeki|kaydedilmiş|beğendiğim)\s+albüm(?:lerimden|lerden)\s+(?:birini|bir\s+tanesini|rastgele\s+birini|bir\s+şey|bir\s+şeyler)\s+"# + playVerb,
            #"albümlerimden\s+(?:birini|bir\s+tanesini|rastgele\s+birini)\s+"# + playVerb,
            #"(?:kaydettiğim|kayıtlı|kütüphanemdeki)\s+bir\s+albüm(?:ü)?\s+"# + playVerb
        ]) { return .playSavedAlbum }
        if matches(t, [
            #"(?:takip\s+ettiğim|takip\s+edilen|takipteki)\s+sanatçı(?:lardan|larımdan)\s+(?:birini|bir\s+tanesini|birinden|rastgele\s+birini|bir\s+şey|bir\s+şeyler)\s+"# + playVerb,
            #"takip\s+ettiğim\s+bir\s+sanatçı(?:yı)?\s+"# + playVerb
        ]) { return .playFollowedArtist }
        if matches(t, [
            #"(?:en\s+)?son\s+(?:dinlediğim|çaldığım|açtığım|dinlediğimiz|çalınan)\s+(?:şarkıyı|parçayı|şeyi)\s+(?:(?:tekrar|yine|bir\s+daha)\s+)?"# + playVerb,
            #"(?:az\s+önce|demin|biraz\s+önce)\s+(?:dinlediğim|çaldığım|çalan)\s+(?:şarkıyı|parçayı)\s+(?:(?:tekrar|yine|bir\s+daha)\s+)?"# + playVerb
        ]) { return .playRecentTrack }

        if let device = transferTarget(t) { return .transferPlayback(device) }

        if let question = question(t) { return .question(question) }

        // Spotify removed "an artist's top tracks" for apps like this one in February 2026;
        // the artist context starts with their popular songs anyway.
        if let artist = match(lead + #"(.+?)'?(?:ın|in|un|ün|nın|nin|nun|nün)\s+en\s+(?:popüler|sevilen|çok\s+dinlenen|iyi|meşhur|ünlü|bilinen)\s+(?:şarkısını|şarkılarını|parçasını|parçalarını|şarkılarından\s+birini)\s+"# + playVerb + tail, t)?.first ?? nil {
            let name = artist.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.split(separator: " ").count <= 4 {
                return .search(SpotifySearchRequest(kind: .artist, title: "", artist: name, freeText: name))
            }
        }

        if matches(t, [#"(?:spotify'ın\s+)?(?:uyku|müzik)\s+zamanlayıcısı(?:nı)?\s+(?:iptal\s+et|kapat|sil|durdur|kaldır)"#,
                       #"müziği\s+kapatmayı\s+(?:iptal\s+et|unut|vazgeç)"#,
                       #"müzik\s+kapanmasın"#]) {
            return .cancelSleepTimer
        }
        return nil
    }

    /// "Spor" from "spor", "spor adlı", "'spor' isimli".
    private static func playlistName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for suffix in [" adlı", " isimli", " isminde", " adındaki"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ").union(.whitespaces))
        let words = name.split(separator: " ")
        guard !words.isEmpty, words.count <= 4,
              !["bu", "şu", "o", "benim", "bunu", "bir"].contains(name) else { return nil }
        return name
    }

    private static func seek(_ t: String) -> SpotifySeek? {
        let object = #"(?:"# + songObject + #"|müziği|şarkıda|spotify'ı|spotifyı)"#
        // "şarkıyı 30 saniye ileri sar". Without "şarkı"/"Spotify" it is the video command's.
        if let groups = match(lead + object + #"\s+(.+?)\s+(ileri|geri)\s+(?:sar|al|atla|git)"# + tail, t)
            ?? match(#"^"# + spotifyWord + #"\s+(.+?)\s+(ileri|geri)\s+(?:sar|al|atla|git)"# + tail, t),
           let amount = groups[0], let direction = groups[1],
           let duration = SpokenDuration.first(in: amount), duration.seconds > 0,
           amount[duration.range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            return .by(direction == "ileri" ? duration.seconds : -duration.seconds)
        }
        if matches(t, [songObject + #"\s+(?:en\s+)?(?:başa|baştan)\s+(?:sar|al|başlat|çal)"#,
                       #"(?:şarkıyı|parçayı)\s+baştan\s+(?:başlat|çal)"#]) {
            return .to(0)
        }
        // "şarkının ikinci dakikasına git", "şarkıyı 2. dakikaya al", "şarkıyı 1:30'a sar"
        let anchor = #"(?:şarkının|parçanın|şarkıyı|parçayı)"#
        if let groups = match(lead + anchor + #"\s+(\d{1,2}|\p{L}+)(?:\.|'?(?:inci|ıncı|uncu|üncü|nci|ncı|ncu|ncü))?\s+dakika(?:sına|ya)\s+(?:git|geç|sar|al|atla)"# + tail, t),
           let raw = groups[0], let minute = Int(raw) ?? ordinals[raw], minute < 60 {
            return .to(minute * 60)
        }
        if let groups = match(lead + anchor + #"\s+(\d{1,2}):(\d{2})(?:'?(?:a|e|ya|ye))?\s+(?:git|geç|sar|al|atla)"# + tail, t),
           let m = groups[0].flatMap(Int.init), let s = groups[1].flatMap(Int.init), s < 60 {
            return .to(m * 60 + s)
        }
        return nil
    }

    private static func transferTarget(_ t: String) -> SpotifyDeviceKind? {
        let object = #"(?:müziği|şarkıyı|çalanı|çalan\s+şarkıyı|spotify'ı|spotifyı|spotify)"#
        let targets = #"(telefon|iphone|hoparlör|bilgisayar|mac|televizyon|tv|tablet|ipad)\p{L}*"#
        guard let groups = match(lead + object + #"\s+(?:bu\s+)?"# + targets + #"(?:'?\p{L}*)?\s+(?:geçir|aktar|taşı|al|ver|gönder)"# + tail, t)
                ?? match(lead + object + #"\s+"# + targets + #"(?:'?\p{L}*)?\s+(?:çal|çalsın|devam\s+et)"# + tail, t),
              let stem = groups[0] else { return nil }
        switch stem {
        case "telefon", "iphone": return .phone
        case "hoparlör": return .speaker
        case "bilgisayar", "mac": return .computer
        case "televizyon", "tv": return .tv
        case "tablet", "ipad": return .tablet
        default: return nil
        }
    }

    private static func question(_ t: String) -> SpotifyQuestion? {
        if matches(t, [#"(?:müzik|müziği|şarkı|spotify)\s+(?:şu\s+an\s+)?(?:nerede|hangi\s+cihazda|hangi\s+cihazdan|nereden)\s+çalıyor"#,
                       #"(?:spotify|müzik)\s+hangi\s+cihazda"#]) {
            return .device
        }
        if matches(t, [#"(?:(?:bu|çalan)\s+)?(?:şarkı|parça)\s+hangi\s+albüm(?:den|de|e\s+ait)(?:\s+(?:çıkmış|çıktı|acaba))?"#,
                       #"(?:(?:bu|çalan)\s+)?(?:şarkının|parçanın)\s+albümü\s+(?:ne|nedir|hangisi)"#]) {
            return .album
        }
        if matches(t, [#"(?:(?:bu|çalan)\s+)?(?:şarkının|şarkı|parçanın|parça)\s+(?:bitmesine|sonuna|bitimine)\s+(?:kaç\s+dakika|kaç\s+saniye|ne\s+kadar)(?:\s+(?:süre|zaman))?\s+kaldı"#,
                       #"(?:(?:bu|çalan)\s+)?(?:şarkı|parça)\s+(?:ne\s+zaman|kaç\s+dakikada|kaç\s+saniyede)\s+bitiyor"#]) {
            return .timeLeft
        }
        if matches(t, [#"(?:sıradaki|bundan\s+sonraki|bir\s+sonraki|sonraki)\s+(?:şarkı|parça)\s+(?:ne|nedir|hangisi|ne\s+olacak)"#,
                       #"sırada\s+hangi\s+(?:şarkı|parça)\s+var"#]) {
            return .nextUp
        }
        if match(#"^"# + spotifyWord + #"\s+sırada\s+ne\s+var"# + tail, t) != nil { return .nextUp }
        return nil
    }

    /// "30 dakika sonra müziği kapat", "yarım saat sonra Spotify'ı durdur", "uyku
    /// zamanlayıcısını 20 dakikaya kur". Before the pause rule, which used to stop the
    /// music right away.
    private static func sleepTimer(_ t: String) -> ExplicitSpotifyIntent? {
        let object = #"(?:müziği|şarkıyı|spotify'ı|spotifyı|müzik|spotify)"#
        let stop = #"(?:kapat|durdur|duraklat|sustur|kapansın|dursun)"#
        let spans = [
            match(lead + #"(.+?)\s+sonra\s+"# + object + #"\s+"# + stop + tail, t)?.first ?? nil,
            match(lead + object + #"\s+(.+?)\s+sonra\s+"# + stop + tail, t)?.first ?? nil,
            match(#"^(.*uyku\s+zamanlayıcısı.*)\s+(?:kur|ayarla|başlat)"# + tail, t)?.first ?? nil,
            match(#"^(?:müzik\s+için\s+)?uyku\s+zamanlayıcısı(?:nı)?\s+(?:kur|ayarla|başlat)\s+(.+)$"#, t)?.first ?? nil
        ]
        for span in spans {
            guard let span, let duration = SpokenDuration.first(in: span), duration.seconds >= 10,
                  duration.seconds <= 6 * 3600 else { continue }
            return .sleepTimer(duration.seconds)
        }
        return nil
    }

    // MARK: Checked at run time

    /// A phrase that is a command only if something holds right now: "Şımarık'ı sıraya
    /// ekle" while Spotify plays here, "Spor listemi aç" when the user has a "Spor" playlist.
    enum RuntimeCandidate: Equatable {
        case queue(SpotifySearchRequest)
        case ownPlaylist(String)
        case addToPlaylist(String)
    }

    static func runtimeCandidate(_ text: String) -> RuntimeCandidate? {
        let t = normalize(text)
        guard mentionVetoAllows(t) else { return nil }
        if let query = queueQuery(t) {
            return .queue(SpotifyRequestParser.requestFromRules("\(query) çal"))
        }
        if let name = match(lead + #"(.+?)\s+listemi\s+aç"# + tail, t)?.first ?? nil
            ?? (match(lead + #"listelerimden\s+(.+?)"# + caseSuffix + #"\s+(?:aç|çal|başlat)"# + tail, t)?.first ?? nil),
           let cleaned = playlistName(name) {
            return .ownPlaylist(cleaned)
        }
        if let name = match(lead + #"bunu\s+(.+?)\s+(?:çalma\s+)?(?:listeme|listesine|playlistime)\s+(?:de\s+)?ekle"# + tail, t)?.first ?? nil,
           let cleaned = playlistName(name) {
            return .addToPlaylist(cleaned)
        }
        return nil
    }

    /// "Tarkan'dan Şımarık'ı sıraya ekle" → "tarkan'dan şımarık'ı".
    private static func queueQuery(_ t: String) -> String? {
        guard let query = match(lead + #"(.+?)\s+(?:sıraya|kuyruğa|çalma\s+sırasına)\s+(?:da\s+)?(?:ekle|al|koy)"# + tail, t)?.first ?? nil else { return nil }
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 6, !["bunu", "bu", "şunu", "onu"].contains(words[0]) else { return nil }
        return query
    }

    /// A queue phrase that names music or Spotify itself is a command by its words alone.
    static func queueIntentFromRules(_ t: String) -> ExplicitSpotifyIntent? {
        guard let query = queueQuery(t) else { return nil }
        let musicNouns = ["şarkı", "parça", "albüm", "spotify"]
        guard t.split(separator: " ").contains(where: { word in musicNouns.contains { word.hasPrefix($0) } }) else { return nil }
        let request = SpotifyRequestParser.requestFromRules("\(query) çal")
        return request.searchQueries.isEmpty ? nil : .queue(request)
    }
}
