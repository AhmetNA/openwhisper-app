import XCTest
@testable import OpenWhisper

final class CommandRewriterTests: XCTestCase {
    func testAppDecisionAcceptsOnlyInstalledAppsAndOpeningActions() {
        let apps = ["Safari", "Visual Studio Code"]
        XCTAssertEqual(CommandRewriter.decodedAppCommand(#"{"action":"open","app":"Safari"}"#, installedApps: apps), .openApp("Safari"))
        XCTAssertEqual(CommandRewriter.decodedAppCommand(#"{"action":"switch","app":"Visual Studio Code"}"#, installedApps: apps), .switchToApp("Visual Studio Code"))
        for answer in [#"{"action":"none","app":"Safari"}"#, #"{"action":"open","app":"Unknown"}"#,
                       #"{"action":"quit","app":"Safari"}"#, #"{"action":"open","app":"safari"}"#,
                       "Safari'yi aç", "{}"] {
            XCTAssertNil(CommandRewriter.decodedAppCommand(answer, installedApps: apps))
        }
    }

    func testMisheardAppRequestSendsInstalledNamesAndUsesStructuredDecision() async {
        let fake = AppDecisionClient()
        fake.answer = .success(#"{"action":"open","app":"Safari"}"#)
        let command = await CommandRewriter.appCommand("Sıfırıyaç", installedApps: ["Safari", "Custom Editor"], model: "test", client: fake)
        XCTAssertEqual(command, .openApp("Safari"))
        XCTAssertTrue(fake.requests[0].prompt.contains("Custom Editor"))
        XCTAssertTrue(fake.requests[0].prompt.contains("Sıfırıyaç"))
        XCTAssertNotNil(fake.requests[0].schema)
        fake.answer = .success(#"{"action":"none","app":""}"#)
        let noCommand = await CommandRewriter.appCommand("Safari nedir", installedApps: ["Safari"], model: "test", client: fake)
        XCTAssertNil(noCommand)
        fake.answer = .failure(LLMError.malformed)
        let unavailable = await CommandRewriter.appCommand("Sıfırıyaç", installedApps: ["Safari"], model: "test", client: fake)
        XCTAssertNil(unavailable)
    }

    @MainActor
    func testLiveMisheardAppCommands() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_OLLAMA"] == "1" else {
            throw XCTSkip("Set LIVE_OLLAMA=1 to verify the local model")
        }
        let apps = SystemController.installedApps()
        for (text, expected) in [
            ("Sıfırıyaç", SystemCommand.openApp("Safari")),
            ("Saferi yaç", .openApp("Safari")),
            ("Safari’ye geç", .switchToApp("Safari"))
        ] {
            let command = await CommandRewriter.appCommand(text, installedApps: apps, model: LLM.selectedModel)
            XCTAssertEqual(command, expected, text)
        }
        for text in ["Safari nedir", "Safari'yi açma", "Safari'yi aç yaz", "Bugün hava çok güzel"] {
            let command = await CommandRewriter.appCommand(text, installedApps: apps, model: LLM.selectedModel)
            XCTAssertNil(command, text)
        }
    }

    func testMusicNeverBecomesAnApplicationLaunch() async {
        let fake = AppDecisionClient()
        fake.answer = .success(#"{"action":"open","app":"Music"}"#)
        for text in ["Şu anda müzik başlatabilir misin?", "Şarkı aç", "Spotify çal"] {
            let command = await CommandRewriter.appCommand(text, installedApps: ["Music", "Spotify"], model: "test", client: fake)
            XCTAssertNil(command)
        }
        XCTAssertTrue(fake.requests.isEmpty)
        XCTAssertNil(CommandRewriter.decodedAppCommand(#"{"action":"open","app":"Music"}"#, installedApps: ["Music"]))
        XCTAssertFalse(SystemController.installedApps().contains("Music"))
        XCTAssertFalse(SystemController.isVoiceApp("Apple Music"))
    }

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

private final class AppDecisionClient: LLMClient, @unchecked Sendable {
    var answer: Result<String, Error> = .success("")
    var models: [String] = []
    private(set) var requests: [LLMRequest] = []
    private(set) var chats: [LLMChatRequest] = []

    func generate(_ request: LLMRequest) async throws -> String {
        requests.append(request)
        return try answer.get()
    }

    func chat(_ request: LLMChatRequest) async throws -> String {
        chats.append(request)
        return try answer.get()
    }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        chats.append(request)
        let answer = self.answer
        return AsyncThrowingStream { continuation in
            switch answer {
            case .success(let text): continuation.yield(text); continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    func installedModels(timeout: TimeInterval) async throws -> [String] { models }
    func load(model: String, timeout: TimeInterval) async throws {}
    func unload(model: String, timeout: TimeInterval) async throws {}
}
