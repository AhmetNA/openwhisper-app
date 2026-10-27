import XCTest
@testable import OpenWhisper

/// The rule-only Spotify commands (`SpotifyExtendedCommands.swift`): what each phrase means,
/// what stays dictation, and that the models can't override them.
final class SpotifyExtendedCommandTests: XCTestCase {
    private typealias Intent = SpotifyManager.ExplicitSpotifyIntent

    private func intent(_ text: String) -> Intent? {
        SpotifyManager.explicitIntent(in: text)
    }

    func testPlaybackModes() {
        let cases: [(String, Intent)] = [
            ("Karışık çal", .setShuffle(true)),
            ("Karışık çalmayı aç", .setShuffle(true)),
            ("Spotify'da karışık çalmayı kapat", .setShuffle(false)),  // used to pause
            ("Sırayla çal", .setShuffle(false)),
            ("Bu şarkıyı tekrarla", .setRepeat(.track)),
            ("Listeyi tekrarla", .setRepeat(.context)),
            ("Tekrarı kapat", .setRepeat(.off)),
            ("Spotify'da tekrarı kapat", .setRepeat(.off)),  // used to pause
            ("Spotify'da tekrar kapat lütfen", .setRepeat(.off)),  // as Whisper wrote it
        ]
        for (text, expected) in cases { XCTAssertEqual(intent(text), expected, text) }
    }

    func testSeekNeedsTheSongOrSpotifyNamed() {
        let cases: [(String, Intent)] = [
            ("Şarkıyı 30 saniye ileri sar", .seek(.by(30))),
            ("Spotify'da otuz saniye geri sar", .seek(.by(-30))),
            ("Şarkıyı bir dakika ileri sar", .seek(.by(60))),
            ("Şarkıyı başa sar", .seek(.to(0))),
            ("Şarkının ikinci dakikasına git", .seek(.to(120))),
            ("Şarkının 2. dakikasına git", .seek(.to(120))),
            ("Şarkıyı 1:30'a sar", .seek(.to(90))),
        ]
        for (text, expected) in cases { XCTAssertEqual(intent(text), expected, text) }
        // Bare forms belong to the video command.
        XCTAssertNil(intent("30 saniye ileri sar"))
        XCTAssertNil(intent("Başa sar"))
    }

    func testLibraryAndDevices() {
        let cases: [(String, Intent)] = [
            ("Bunu beğenilenlerden çıkar", .unlikeCurrentTrack),
            ("Çalan şarkıyı beğenilenlerden çıkar", .unlikeCurrentTrack),
            ("Spotify'ın kendi sesini 40 yap", .setSpotifyVolume(40)),
            ("Spor çalma listemi aç", .playOwnPlaylist("spor")),
            ("Spor listemi çal", .playOwnPlaylist("spor")),
            ("Çalan şarkıyı Spor listesine ekle", .addCurrentTrackToPlaylist("spor")),  // used to like it
            ("Çalan şarkıyı beğenilenler listesine ekle", .likeCurrentTrack),
            ("Beğenilen şarkılar listemi aç", .playLikedSongs),
            ("Kaydettiğim albümlerden birini aç", .playSavedAlbum),
            ("Takip ettiğim sanatçılardan birini çal", .playFollowedArtist),
            ("Son dinlediğim şarkıyı aç", .playRecentTrack),
            ("En son çaldığım şarkıyı tekrar aç", .playRecentTrack),
            ("Müziği telefona geçir", .transferPlayback(.phone)),
            ("Spotify'ı hoparlöre aktar", .transferPlayback(.speaker)),
            ("Müziği bilgisayara al", .transferPlayback(.computer)),
            ("Şımarık şarkısını sıraya ekle", .queue(.freeText("şımarık"))),
        ]
        for (text, expected) in cases { XCTAssertEqual(intent(text), expected, text) }
        // The system volume stays the default.
        XCTAssertEqual(intent("Spotify'ın sesini 40 yap"), .setVolume(40))
        XCTAssertEqual(intent("Tarkan'ın en popüler şarkısını aç"),
                       .search(SpotifySearchRequest(kind: .artist, title: "", artist: "tarkan", freeText: "tarkan")))
    }

    func testQuestionsAndSleepTimer() {
        let cases: [(String, Intent)] = [
            ("Müzik nerede çalıyor?", .question(.device)),
            ("Spotify hangi cihazda çalıyor", .question(.device)),
            ("Bu şarkı hangi albümden?", .question(.album)),
            ("Şarkının bitmesine kaç dakika kaldı?", .question(.timeLeft)),
            ("Sıradaki şarkı ne?", .question(.nextUp)),
            ("30 dakika sonra müziği kapat", .sleepTimer(1800)),  // used to pause at once
            ("Müziği yarım saat sonra kapat", .sleepTimer(1800)),
            ("Uyku zamanlayıcısını 20 dakikaya kur", .sleepTimer(1200)),
            ("Uyku zamanlayıcısı kur 20 dakika", .sleepTimer(1200)),
            ("Uyku zamanlayıcısını iptal et", .cancelSleepTimer),
        ]
        for (text, expected) in cases { XCTAssertEqual(intent(text), expected, text) }
        XCTAssertNil(TimerCommandParser.parse("uyku zamanlayıcısını iptal et"))
    }

    func testOrdinarySpeechStaysDictation() {
        for text in [
            "bu konuyu sıraya ekle", "toplantıyı başa saralım", "karışık bir gündü", "bu çok karışık",
            "bunu tekrarla", "listeyi tekrar gözden geçir", "telefona geç", "kaç dakika kaldı",
            "hangi albüm daha iyi", "dosyayı başa sar", "aramayı telefona aktar", "bunu listeye ekle",
            "karışık çal diye bir şey demedim", "alışveriş listemi aç",
        ] {
            XCTAssertNil(intent(text), text)
        }
        XCTAssertNil(SpotifyManager.runtimeCandidate("bu konuyu sıraya ekle"))
    }

    /// Phrases that are commands only if something holds right now (`confirm`).
    func testRuntimeCandidates() {
        XCTAssertEqual(SpotifyManager.runtimeCandidate("Coldplay Yellow sıraya ekle"), .queue(.freeText("coldplay yellow")))
        XCTAssertEqual(SpotifyManager.runtimeCandidate("Spor listemi aç"), .ownPlaylist("spor"))
        XCTAssertEqual(SpotifyManager.runtimeCandidate("Listelerimden Spor'u aç"), .ownPlaylist("spor"))
        XCTAssertEqual(SpotifyManager.runtimeCandidate("Bunu Spor listeme ekle"), .addToPlaylist("spor"))
    }

    func testModelsCannotOverrideRuleOnlyIntents() {
        let search = SpotifyRequestParser.OllamaParse(intent: .search, kind: .track, title: "karışık", artist: "")
        let none = SpotifyRequestParser.OllamaParse(intent: .none)
        for parse in [search, none] {
            XCTAssertEqual(SpotifyManager.decide(rules: intent("Karışık çal"), parse: parse, text: "Karışık çal"), .setShuffle(true))
            XCTAssertEqual(SpotifyManager.decide(rules: intent("Sıradaki şarkı ne"), parse: parse, text: "Sıradaki şarkı ne"),
                           .question(.nextUp))
        }
    }

    func testAnswersAndMediaResume() {
        XCTAssertEqual(SpotifyController.spokenDuration(90), "1 dakika 30 saniye")
        XCTAssertEqual(SpotifyController.spokenDuration(1800), "30 dakika")
        XCTAssertEqual(SpotifyController.spokenDuration(5), "5 saniye")
        XCTAssertTrue(SpotifyManager.resumesPausedMedia(afterCommand: "Sıradaki şarkı ne"))
        XCTAssertTrue(SpotifyManager.resumesPausedMedia(afterCommand: "Karışık çal"))
        XCTAssertFalse(SpotifyManager.resumesPausedMedia(afterCommand: "Müziği telefona geçir"))
        XCTAssertFalse(SpotifyManager.resumesPausedMedia(afterCommand: "Son dinlediğim şarkıyı aç"))
        XCTAssertTrue(SpotifyManager.speaksResult(afterCommand: "Sıradaki şarkı ne"))
        XCTAssertFalse(SpotifyManager.speaksResult(afterCommand: "Karışık çal"))
        XCTAssertTrue(SpotifyManager.speaksFailure(afterCommand: "Karışık çal"))
        // Pause now reports the verified player state, including a failure to stop it.
        XCTAssertTrue(SpotifyManager.speaksFailure(afterCommand: "Müziği durdur"))
    }

    func testPlaylistNamesMatchWholeWords() {
        func list(_ names: String...) -> [SpotifyWebAPI.Playlist] {
            names.map { SpotifyWebAPI.Playlist(id: $0, uri: "spotify:playlist:\($0)", name: $0, ownerID: "u", collaborative: false) }
        }
        XCTAssertEqual(SpotifyController.matchPlaylist(named: "spor", in: list("Esports Anthems", "Spor"))?.name, "Spor")
        XCTAssertNil(SpotifyController.matchPlaylist(named: "spor", in: list("Esports Anthems")))
        XCTAssertEqual(SpotifyController.matchPlaylist(named: "spor", in: list("Spor 2024", "Yolculuk"))?.name, "Spor 2024")
        XCTAssertNil(SpotifyController.matchPlaylist(named: "spor", in: list("Spor 2024", "Sabah Spor")))
        XCTAssertNil(SpotifyController.matchPlaylist(named: "alışveriş", in: list("İş", "a")))
        XCTAssertEqual(SpotifyController.matchPlaylist(named: "çalışma", in: list("Calisma"))?.name, "Calisma")
    }
}
