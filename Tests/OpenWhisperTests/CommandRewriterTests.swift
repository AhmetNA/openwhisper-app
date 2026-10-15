import XCTest
@testable import OpenWhisper

final class CommandRewriterTests: XCTestCase {
    func testLooksLikeCommand() {
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Ortalık çok karanlık, ekranı biraz aç bakalım"))
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Şu müziği bir durdurur musun"))
        XCTAssertTrue(CommandRewriter.looksLikeCommand("Biraz sessizlik lütfen, sesi kısabilir misin?"))
        XCTAssertFalse(CommandRewriter.looksLikeCommand("Kara delikler nasıl oluşur?"))
        XCTAssertFalse(CommandRewriter.looksLikeCommand("Bugün hava çok güzel"))
    }

    func testRewriteOnlyRunsSafeSystemCommands() {
        let apps = ["Safari", "Spotify"]
        XCTAssertEqual(CommandRewriter.safeSystemCommand("Karanlık modu aç", installedApps: apps), .darkMode(on: true))
        XCTAssertNil(CommandRewriter.safeSystemCommand("Safari'yi kapat", installedApps: apps))
        XCTAssertNil(CommandRewriter.safeSystemCommand("Bilgisayarı uyut", installedApps: apps))
        XCTAssertNil(CommandRewriter.safeSystemCommand("YOK", installedApps: apps))
    }
}
