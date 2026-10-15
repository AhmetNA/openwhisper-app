import XCTest
@testable import OpenWhisper

@MainActor
final class UserMemoryTests: XCTestCase {
    func testParsesMemoryCommands() {
        XCTAssertEqual(UserMemoryCommand.parse("Bunu hatırla: annemin doğum günü 3 Mart."), .remember("annemin doğum günü 3 mart"))
        XCTAssertEqual(UserMemoryCommand.parse("Aklında tut, kahveyi şekersiz içiyorum"), .remember("kahveyi şekersiz içiyorum"))
        XCTAssertEqual(UserMemoryCommand.parse("Benim adım ahmet"), .remember(UserMemory.namePrefix + "Ahmet"))
        XCTAssertEqual(UserMemoryCommand.parse("Hakkımda ne biliyorsun?"), .recall)
        XCTAssertEqual(UserMemoryCommand.parse("Şunu unut: annemin doğum günü"), .forget("annemin doğum günü"))
        XCTAssertEqual(UserMemoryCommand.parse("Bunu unut"), .forgetLast)
        XCTAssertEqual(UserMemoryCommand.parse("Hafızanı sil"), .forgetAll)
    }

    func testLeavesRemindersAndOtherTalkAlone() {
        XCTAssertNil(UserMemoryCommand.parse("Bana yarın 9'da toplantıyı hatırlat"))
        XCTAssertNil(UserMemoryCommand.parse("Hatırlatıcı kur"))
        XCTAssertNil(UserMemoryCommand.parse("Adım atmak istiyorum bu konuda bir şey"))
        XCTAssertNil(UserMemoryCommand.parse("Geçen yıl ne olduğunu hatırlıyor musun"))
    }

    func testStoreRemembersForgetsAndPersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let memory = UserMemory(url: url)
        memory.remember("Annemin doğum günü 3 Mart")
        memory.remember(UserMemory.namePrefix + "Ahmet")
        memory.remember(UserMemory.namePrefix + "Ahmet Can")
        XCTAssertEqual(memory.facts.map(\.text), ["Annemin doğum günü 3 Mart", UserMemory.namePrefix + "Ahmet Can"])
        XCTAssertEqual(UserMemory(url: url).facts.count, 2)
        XCTAssertEqual(memory.forget("annemin doğum gününü"), 1)
        XCTAssertEqual(UserMemory(url: url).facts.map(\.text), [UserMemory.namePrefix + "Ahmet Can"])
    }

    func testFactsReachTheChatPrompt() {
        let prompt = JarvisChat.systemPrompt(now: Date(), userFacts: ["Kullanıcının adı Ahmet"])
        XCTAssertTrue(prompt.contains("- Kullanıcının adı Ahmet"))
    }
}
