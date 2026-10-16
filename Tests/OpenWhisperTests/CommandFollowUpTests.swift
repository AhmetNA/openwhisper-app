import XCTest
@testable import OpenWhisper

/// What a bare answer in the window after a command means ("müzik başlat" → "sonrakine geç").
@MainActor
final class CommandFollowUpTests: XCTestCase {
    func testSkipPhrasesAfterMusicGoToTheNextSong() {
        for text in ["Sonrakine geç.", "sonrakine geç", "sonraki", "bunu beğenmedim", "Beğenmedim, başkasını aç",
                     "geç", "atla", "değiştir", "başka bir şarkı çal", "diğerine geç", "Jarvis sonrakine geç"] {
            XCTAssertEqual(CommandFollowUp.resolve(text, after: .music), .spotify("sonraki şarkıya geç"), text)
        }
    }

    func testOtherFixesAfterMusic() {
        XCTAssertEqual(CommandFollowUp.resolve("öncekine dön", after: .music), nil, "dön is not in the vocabulary")
        XCTAssertEqual(CommandFollowUp.resolve("öncekine geç", after: .music), .spotify("önceki şarkıya geç"))
        XCTAssertEqual(CommandFollowUp.resolve("durdur", after: .music), .spotify("şarkıyı durdur"))
        XCTAssertEqual(CommandFollowUp.resolve("devam et", after: .music), .spotify("şarkıya devam et"))
    }

    func testTheResolvedTextsAreSpotifyCommandsOnTheirOwn() {
        for text in ["sonraki şarkıya geç", "önceki şarkıya geç", "şarkıyı durdur", "şarkıya devam et"] {
            XCTAssertNotNil(SpotifyManager.explicitIntent(in: text), text)
        }
    }

    func testVideoDomain() {
        XCTAssertEqual(CommandFollowUp.resolve("sonrakine geç", after: .video), .system(.video(.next)))
        XCTAssertEqual(CommandFollowUp.resolve("durdur", after: .video), .system(.video(.pause)))
        XCTAssertNil(CommandFollowUp.resolve("öncekine geç", after: .video))
    }

    func testSentencesOfTheirOwnAreNoFix() {
        for text in ["Safari'yi kapat", "sonra Ahmet'e geçen haftayı anlatırım", "tamam", "teşekkürler",
                     "Bluetooth'u kapat", "bu şarkı çok güzel", "Tarkan çal", ""] {
            XCTAssertNil(CommandFollowUp.resolve(text, after: .music), text)
        }
    }

    /// The rules run first in the window; a fix they took for some other command would win.
    func testNoRuleClaimsTheBareFixes() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .unknown,
                                      hasTargetApp: true, targetBundleID: nil)
        for text in ["sonrakine geç", "bunu beğenmedim", "geç", "atla", "değiştir", "başkasını aç", "durdur"] {
            switch VoiceRouter.route(text, facts: facts) {
            case .command(let command): XCTFail("'\(text)' → \(command)")
            case .commands(let steps): XCTFail("'\(text)' → \(steps.map(\.command))")
            default: break
            }
        }
    }

    func testJarvissOwnReplyIsDroppedFromTheStart() {
        XCTAssertEqual(CommandFollowUp.removingEcho(of: "Tamamdır.", from: "Tamamdır. Sonrakine geç."), "Sonrakine geç.")
        XCTAssertEqual(CommandFollowUp.removingEcho(of: "Tamamdır.", from: "Tamam, sonrakine geç"), "sonrakine geç")
        XCTAssertEqual(CommandFollowUp.removingEcho(of: "Oldu.", from: "Oldu"), "")
        XCTAssertEqual(CommandFollowUp.removingEcho(of: "Oldu.", from: "sonrakine geç"), "sonrakine geç")
        XCTAssertEqual(CommandFollowUp.removingEcho(of: nil, from: "Tamam geç"), "Tamam geç")
    }

    func testDomainOfARunCommand() {
        XCTAssertEqual(CommandFollowUp.domain(of: .spotify("Tarkan çal")), .music)
        XCTAssertEqual(CommandFollowUp.domain(of: .system(.video(.play))), .video)
        XCTAssertNil(CommandFollowUp.domain(of: .system(.lockScreen)))
    }
}
