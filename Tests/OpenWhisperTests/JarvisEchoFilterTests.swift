import XCTest
@testable import OpenWhisper

final class JarvisEchoFilterTests: XCTestCase {
    /// 27 Oct 2026: the external mic heard the reply, and "Saat" alone was taken for the echo.
    func testReplyWithNumbersMisheardIsDropped() {
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Saat 22:52, 27 Ekim Salı, patron.",
                                                     from: "Saat 22. 25. 27 Ekim salı."), "")
    }

    /// A reply that sounds like a command must not run as one.
    func testCommandShapedReplyIsDropped() {
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Müzik durduruldu.", from: "Müzik durduruldu."), "")
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Müzik durduruldu.", from: "Müzik durduruldu. Sonrakine geç."),
                       "Sonrakine geç.")
    }

    func testUserSpeechIsKept() {
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Müzik durduruldu.", from: "Hayır, sonrakine geç"), "Hayır, sonrakine geç")
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Hangi şarkıyı çalayım?", from: "Tarkan çal"), "Tarkan çal")
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: nil, from: "Tamam geç"), "Tamam geç")
    }

    /// The cases the earlier letters-only filter covered.
    func testShortRepliesStillDrop() {
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Tamamdır.", from: "Tamamdır. Sonrakine geç."), "Sonrakine geç.")
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Tamamdır.", from: "Tamam, sonrakine geç"), "sonrakine geç")
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Oldu.", from: "Oldu"), "")
        XCTAssertEqual(JarvisEchoFilter.removingEcho(of: "Oldu.", from: "sonrakine geç"), "sonrakine geç")
    }
}
