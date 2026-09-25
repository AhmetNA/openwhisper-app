import Foundation

// Golden-set evaluation of Spotify command detection against a REAL local Ollama model —
// not part of the app or the unit tests (those use hand-written model answers). Run it
// after changing SpotifyManager / SpotifyRequestParser or the cleanup model:
//
//   swiftc Tools/SpotifyEval/main.swift Tools/SpotifyEval/Stubs.swift \
//     OpenWhisper/Core/SpotifyManager.swift OpenWhisper/Core/SpotifyController.swift \
//     OpenWhisper/Core/SpotifyWebAPI.swift OpenWhisper/Core/SpotifyRequestParser.swift \
//     OpenWhisper/Core/LLMCleanup.swift OpenWhisper/Core/GlossaryStore.swift \
//     OpenWhisper/Core/SystemVolume.swift OpenWhisper/Core/AudioDucker.swift \
//     OpenWhisper/Core/MisheardWordDetector.swift \
//     -o /tmp/spotify_eval && /tmp/spotify_eval [-v] [model ...]   # "off" = Ollama unavailable
//
// Nothing is sent to Spotify: only the decision is computed.

/// Expected outcome: "dictation", an intent name, or "search <kind> <display text>" (a
/// prefix of the result; "|" separates acceptable alternatives).
let golden: [(text: String, expected: String)] = [
    // Transport / narrow intents
    ("Spotify'ı durdur", "pause"),
    ("müziği durdur", "pause"),
    ("Müziği kapat lütfen", "pause"),
    ("Spotify'da sonraki şarkıya geç", "next"),
    ("sonraki şarkıya geç", "next"),
    ("önceki şarkıya geç", "previous"),
    ("müziği başlat", "play"),
    ("Spotify'da sesi 30 yap", "volume"),
    ("müziğin sesini 50'ye indir", "volume"),
    ("şu an hangi şarkı çalıyor", "current"),
    ("Spotify'da ne çalıyor", "current"),
    ("çalan şarkıyı beğenilerime ekle", "like"),
    // Searches
    ("Spotify'da Tarkan'ın Şımarık şarkısını çal", "search track Tarkan — Şımarık"),
    ("Spotify'da Coldplay Yellow çal", "search track Coldplay — Yellow"),
    ("Sezen Aksu'dan bir şarkı aç", "search artist Sezen Aksu"),
    ("Spotify'da Barış Manço çalsana", "search artist Barış Manço"),
    ("Tarkan'ı çalar mısın Spotify'da", "search artist Tarkan"),
    ("Spotify'da sakin bir şeyler çal", "search playlist sakin"),
    ("Spotify'da spor listesi aç", "search playlist spor"),
    ("Spotify'da Tarkan'ın Karma albümünü aç", "search album Tarkan — Karma"),
    ("müzik çal Manga'nın We Could Be The Same", "search track Manga — We Could Be The Same"),
    ("Spotify'da Bohemian Rhapsody çal", "search track Bohemian Rhapsody"),
    // Must not become a playlist search; a whole-phrase track search is fine.
    ("Spotify'da mor ve ötesi bir derdim var çal", "search track|search freeText"),
    ("Hadise'nin Düm Tek Tek şarkısını çal", "search track Hadise — Düm Tek Tek"),
    ("Spotify'da Duman Bu Akşam çal", "search track Duman — Bu Akşam"),
    ("play Daft Punk on Spotify", "search artist Daft Punk"),
    // Promotion: no "Spotify", no music noun
    ("Hadise düm tek tek çal", "search track Hadise — düm tek tek"),
    ("Coldplay Yellow çal", "search track Coldplay — Yellow"),
    ("Tarkan Şımarık çal", "search track Tarkan — Şımarık"),
    ("Paramore Misery Business çal", "search track Paramore — Misery Business"),
    // Real Whisper transcripts
    ("Spotify da Neighborhood. Çal.", "search"),
    ("Spotify'da hadisedim tek tek çal", "search"),
    ("Spotify'da Coldplay'den Yalınav çal.", "search"),
    ("Sezen Aksu'dan bir şarkı çalıyor.", "dictation"),
    ("Coldplay Yen Lovçal", "dictation"),
    // Dictation
    ("bu projeyi yarın başlatacağız", "dictation"),
    ("toplantıyı kapat dedi ama kapatmadı", "dictation"),
    ("kapıyı kapat", "dictation"),
    ("bilgisayarı kapat", "dictation"),
    ("sonraki adımda testleri çalıştıracağız", "dictation"),
    ("önceki commit'e geri dön", "dictation"),
    ("Spotify'ın API'si hakkında konuşalım", "dictation"),
    ("müzik çalar aldım dün", "dictation"),
    ("şarkı söylemeyi çok seviyorum", "dictation"),
    ("sesini biraz kıs dedim ona", "dictation"),
    ("annem bana şarkı aç dedi", "dictation"),
    ("Spotify'da çalışan bir arkadaşım var", "dictation"),
    ("müzik dinleyelim mi yoksa film mi izleyelim", "dictation"),
    ("bu şarkı çok güzel", "dictation"),
    ("bugün Tarkan konserine gideceğiz", "dictation"),
    ("dosyayı aç ve düzenle", "dictation"),
    ("şarkının sözlerini yaz", "dictation"),
    ("Chrome'u aç", "dictation"),
    ("Netflix aç", "dictation"),
    // Promotion candidates that must stay dictation
    ("kapıyı çal", "dictation"),
    ("zili çal", "dictation"),
    ("biraz gitar çal", "dictation"),
    ("telefonu çal", "dictation"),
    ("komşunun kapısını çal", "dictation"),
    ("onun parasını çal", "dictation"),
    // Added after a held-out run exposed them
    ("biraz saz çal", "dictation"),
    ("bateri çal", "dictation"),
    ("arabayı çal", "dictation"),
    ("şu melodiyi çal", "dictation"),
    ("çocuklar için bir ninni çal", "dictation"),
    ("Duman Senden Daha Güzel çal", "search track Duman — Senden Daha Güzel"),
    ("Adele Hello çal", "search track Adele — Hello"),
    ("Manga Cevapsız Sorular çal", "search track"),
    ("Spotify'ın sesini 20'ye düşür", "volume"),
    ("şimdi çalan şarkı ne", "current"),
    ("bir sonraki şarkıya atla", "next"),
    // Natural phrasing — evaluated as if Spotify were playing on this Mac
    ("müziğin sesi çok kısık ya", "volume_up"),
    ("şarkının sesi biraz az", "volume_up"),
    ("müziğin sesi duyulmuyor", "volume_up"),
    ("müziği biraz aç", "volume_up"),
    ("sesi biraz yükseltir misin müziğin", "volume_up"),
    ("müzik çok yüksek ya", "volume_down"),
    ("şarkının sesini biraz kıs", "volume_down"),
    ("müziğin sesi çok bağırıyor", "volume_down"),
    ("müzik kulağımı patlatıyor", "volume_down"),
    ("müziği sonuna kadar aç", "volume"),
    ("bu şarkıdan sıkıldım", "next"),
    ("bu şarkı olmadı ya", "next"),
    ("bir önceki şarkı daha iyiydi", "previous"),
    ("müziği bir sustur", "pause"),
    ("biraz sakin bir şeyler dinleyelim", "search playlist"),
    // Real Whisper transcripts of volume commands
    ("Sesi baya bir kız.", "volume_down"),
    ("Spotify'da ses baya bir kız.", "volume_down"),
    ("Sesi biraz yükseltelim.", "volume_up"),
    // Natural-looking dictation that must stay text even while music plays
    ("dün konserde şarkının sesi çok kısıktı", "dictation"),
    ("şarkının sözleri çok anlamlı", "dictation"),
    ("bu şarkıyı ilk kez dinliyorum", "dictation"),
    ("müzik zevkimiz çok farklı", "dictation"),
    ("şarkıcının sesi çok güzel", "dictation"),
    ("bu şarkıyı annem çok sever", "dictation"),
    ("müzik dersine geç kaldım", "dictation"),
    ("sesin çok güzelmiş", "dictation"),
]

func describe(_ intent: SpotifyManager.ExplicitSpotifyIntent?) -> String {
    guard let intent else { return "dictation" }
    switch intent {
    case .pause: return "pause"
    case .play: return "play"
    case .next: return "next"
    case .previous: return "previous"
    case .setVolume: return "volume"
    case .adjustVolume(let delta): return delta > 0 ? "volume_up \(delta)" : "volume_down \(delta)"
    case .currentTrack: return "current"
    case .likeCurrentTrack: return "like"
    case .search(let request): return "search \(request.kind) \(request.displayText)"
    }
}

func fold(_ s: String) -> String {
    s.lowercased(with: Locale(identifier: "tr_TR")).folding(options: .diacriticInsensitive, locale: nil)
}

let modelArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
let models = modelArgs.isEmpty ? [SpotifyManager.selectedOllamaModel] : Array(modelArgs)
for model in models {
    print("=== \(model) ===")
    var passed = 0, dictationOK = 0, dictationTotal = 0, ollamaCalls = 0
    var latencies: [Double] = []
    for (transcript, expected) in golden {
        let text = SpotifyManager.repairVolumeMishearing(transcript)
        let rules = SpotifyManager.explicitIntent(in: text)
        var parse: SpotifyRequestParser.OllamaParse?
        var latency: Double?
        let natural = rules == nil && SpotifyManager.isNaturalCandidate(text)
        if model != "off", rules != nil || natural || SpotifyManager.isPromotionCandidate(text) {
            let start = Date()
            parse = await SpotifyRequestParser.queryOllama(transcript: text, model: model)
            latency = Date().timeIntervalSince(start)
            latencies.append(latency!)
            ollamaCalls += 1
        }
        let got = describe(SpotifyManager.decide(rules: rules, parse: parse, text: text, spotifyPlaying: natural))
        let ok = expected.split(separator: "|").contains { fold(got).hasPrefix(fold(String($0))) }
        if ok { passed += 1 }
        if expected == "dictation" { dictationTotal += 1; if ok { dictationOK += 1 } }
        if !ok || CommandLine.arguments.contains("-v") {
            let timing = latency.map { String(format: " (%.2fs)", $0) } ?? ""
            let llm = parse.map { " | llm: \($0.intent) \($0.kind.map { "\($0)" } ?? "-") \"\($0.title)\" / \"\($0.artist)\"" }
                ?? (latency != nil ? " | llm: no answer" : "")
            let llmLine = llm + timing
            print("\(ok ? "✓" : "✗") \(text)\n    got: \(got)   expected: \(expected)\(llmLine)")
        }
    }
    latencies.sort()
    print("passed \(passed)/\(golden.count) · dictation kept \(dictationOK)/\(dictationTotal) · Ollama calls \(ollamaCalls)"
          + (latencies.isEmpty ? "" : String(format: " · latency median %.2fs max %.2fs", latencies[latencies.count / 2], latencies.last!)))
    print()
}
