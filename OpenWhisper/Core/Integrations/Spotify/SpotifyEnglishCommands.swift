import Foundation

/// Spotify commands in English, used only while the dictation language is English
/// (`CommandLanguage`). English puts the verb first ("pause the music", "play Blinding Lights
/// on Spotify"), so the verb must open the command and the words after it come from a closed
/// list: "I paused the song yesterday" or "stop the music at ten" stay dictation.
extension SpotifyManager {
    private static let englishPoliteWords: Set<String> = ["please", "hey", "jarvis", "now"]
    /// Words that name what plays; one of them (or "Spotify") makes the command a Spotify one.
    private static let englishMusicWords: Set<String> = [
        "music", "song", "songs", "track", "tracks", "album", "playlist", "spotify"
    ]
    /// What may follow a transport verb: "pause the music", "skip this song", "pause Spotify".
    private static let englishTargetWords: Set<String> = englishMusicWords.union([
        "the", "this", "that", "my", "it", "current", "playback", "one", "on", "in"
    ])
    /// A video is `SystemCommandParser`'s: "pause the video" must not pause Spotify.
    private static let englishVideoWords: Set<String> = ["video", "videos", "youtube", "movie", "episode", "clip"]
    private static let englishPlayVerbs: Set<String> = ["play", "open", "put"]

    static func englishIntent(in text: String) -> ExplicitSpotifyIntent? {
        var words = normalize(text)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'s\\b", with: " is", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        while let first = words.first, englishPoliteWords.contains(first) { words.removeFirst() }
        if words.count >= 2, ["can", "could", "would", "will"].contains(words[0]), words[1] == "you" {
            words.removeFirst(2)
        }
        while let last = words.last, englishPoliteWords.contains(last) { words.removeLast() }
        guard let verb = words.first, words.count <= 12,
              englishVideoWords.isDisjoint(with: words) else { return nil }
        let rest = Array(words.dropFirst())
        let all = Set(words)
        let named = !englishMusicWords.isDisjoint(with: all)
        func only(_ allowed: Set<String>, _ list: [String] = rest) -> Bool { list.allSatisfy(allowed.contains) }

        // "What song is this?", "what's playing?" (after "'s" → " is").
        if ["what", "which"].contains(verb), !all.isDisjoint(with: ["song", "track", "playing"]),
           only(["is", "this", "that", "song", "track", "playing", "the", "name", "of", "current", "currently",
                 "right", "now", "called", "on", "spotify"]) {
            return .currentTrack
        }

        if let volume = englishVolume(words) { return volume }

        if ["pause", "stop"].contains(verb), named, only(englishTargetWords) { return .pause }

        if ["resume", "unpause", "continue"].contains(verb),
           named || rest == ["playing"], only(englishTargetWords.union(["playing"])) {
            return .play
        }

        // "next song", "skip this track", "play the next song", "go to the next song".
        let moveWords: Set<String> = ["go", "to", "play", "skip", "next", "previous", "back", "last"]
        if named, only(englishTargetWords.union(moveWords), words) {
            if all.contains("previous") || all.contains("back") || (all.contains("last") && verb != "skip") {
                return .previous
            }
            if all.contains("next") || verb == "skip" { return .next }
        }

        // "like this song", "save this track", "add this song to my liked songs".
        if ["like", "save", "heart"].contains(verb), named, only(englishTargetWords) { return .likeCurrentTrack }
        if verb == "add", named, !all.isDisjoint(with: ["liked", "favorites", "favourites"]),
           only(englishTargetWords.union(["to", "liked", "favorites", "favourites"])) {
            return .likeCurrentTrack
        }

        guard englishPlayVerbs.contains(verb) || ["search", "find"].contains(verb) else { return nil }
        // "play my liked songs", "play my favorites".
        if !all.isDisjoint(with: ["liked", "favorites", "favourites", "favorite", "favourite"]),
           only(englishTargetWords.union(["liked", "favorites", "favourites", "favorite", "favourite", "from"])) {
            return .playLikedSongs
        }
        guard named else { return nil }
        // "play some music", "put on a song": nothing named, so Liked Songs, as in Turkish.
        if only(englishTargetWords.union(["some", "a", "any", "from"])) {
            return englishPlayVerbs.contains(verb) ? .playLikedSongs : nil
        }
        // A bare "play Shape of You" has no music word; it is left to the model in a voice session.
        let request = SpotifyRequestParser.englishRequest(text)
        return request.searchQueries.isEmpty ? nil : .search(request)
    }

    /// "set the volume to 40", "volume 30", "turn it up", "increase the volume", "turn the music down a bit".
    private static func englishVolume(_ words: [String]) -> ExplicitSpotifyIntent? {
        let all = Set(words)
        if all.contains("volume"), let value = words.compactMap(Int.init).first, (0...100).contains(value),
           words.allSatisfy({ Int($0) != nil || ["set", "turn", "change", "put", "make", "the", "volume", "to", "at",
                                                   "percent", "music", "spotify", "it"].contains($0) }) {
            return .setVolume(value)
        }
        let allowed: Set<String> = ["turn", "it", "the", "music", "volume", "song", "spotify", "up", "down", "a",
                                    "bit", "little", "lot", "louder", "quieter", "softer", "make", "more",
                                    "increase", "raise", "decrease", "lower", "reduce"]
        guard words.allSatisfy(allowed.contains),
              all.contains("volume") || all.contains("turn") || all.contains("make") else { return nil }
        let up = !all.isDisjoint(with: ["up", "louder", "increase", "raise"])
        let down = !all.isDisjoint(with: ["down", "quieter", "softer", "decrease", "lower", "reduce"])
        guard up != down else { return nil }
        let step = all.contains("lot") ? 30 : !all.isDisjoint(with: ["bit", "little"]) ? 10 : 20
        return .adjustVolume(up ? step : -step)
    }
}

extension SpotifyRequestParser {
    /// "play Shape of You by Ed Sheeran on Spotify" → track "shape of you" by "ed sheeran".
    /// Filler is only cut around the name, never inside it ("Stuck in the Middle").
    static func englishRequest(_ text: String) -> SpotifySearchRequest {
        var words = text
            .lowercased(with: CommandLanguage.locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\b(on|in|from|using|with) spotify\\b", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\bspotify\\b", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"")) }
            .filter { !$0.isEmpty }
        let isPlaylist = words.contains("playlist")
        let isAlbum = !isPlaylist && words.contains("album")
        var isTrack = false
        let leading: Set<String> = ["please", "can", "could", "you", "play", "open", "put", "on", "search", "find",
                                    "for", "me", "the", "a", "an", "some", "my", "song", "track", "album",
                                    "playlist", "called", "named", "titled"]
        while let first = words.first, leading.contains(first) {
            if ["song", "track"].contains(first) { isTrack = true }
            words.removeFirst()
        }
        while let last = words.last, ["please", "song", "track", "album", "playlist", "now"].contains(last) {
            words.removeLast()
        }
        let parts = words.split(separator: "by", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts[0].joined(separator: " ")
        let artist = parts.count > 1 ? parts[1].joined(separator: " ") : ""
        // The whole name, "by" included: "Stand by Me" is no artist "me", and the free text is
        // always the last query tried.
        let freeText = words.joined(separator: " ")
        if isPlaylist, !title.isEmpty { return SpotifySearchRequest(kind: .playlist, title: title, artist: "", freeText: freeText) }
        if isAlbum, !title.isEmpty { return SpotifySearchRequest(kind: .album, title: title, artist: artist, freeText: freeText) }
        if !artist.isEmpty, !title.isEmpty { return SpotifySearchRequest(kind: .track, title: title, artist: artist, freeText: freeText) }
        if isTrack, !title.isEmpty { return SpotifySearchRequest(kind: .track, title: title, artist: "", freeText: freeText) }
        return .freeText(freeText)
    }
}
