import XCTest
@testable import OpenWhisper

@MainActor
final class CloudDecisionPlannerTests: XCTestCase {
    func context(_ text: String, focus: TextFocusStatus = .notEditable, commandsOnly: Bool = false) -> CloudDecisionPlanner.Context {
        .init(requestID: "session-42", transcript: text, trigger: "jarvisKey", app: "Codex", bundleID: "com.openai.codex",
              focus: focus.rawValue, caret: focus == .editable ? 12 : nil, selectionLength: 0,
              conversationFollowUp: false, commandsOnly: commandsOnly, lastCommand: "music", lastReply: "",
              hasWorkRecap: true, installedApps: ["Safari", "Spotify"], localTime: "2026-10-26T00:00:00+03:00")
    }
    func facts(_ focus: TextFocusStatus = .notEditable) -> VoiceRouter.Facts {
        .init(isVoiceCommand: true, acceptsCommands: true, focus: focus, hasTargetApp: true,
              hasWorkRecap: true, commandContext: { .init(installedApps: ["Safari", "Spotify"]) })
    }
    func json(_ steps: [CloudDecisionPlanner.Step], id: String = "session-42", version: Int = 2) throws -> String {
        String(decoding: try JSONEncoder().encode(CloudDecisionPlanner.Plan(version: version, mode: steps.allSatisfy { $0.kind == .dictation } ? .dictation : .command, requestID: id, steps: steps)), as: UTF8.self)
    }
    func resolve(_ text: String, _ steps: [CloudDecisionPlanner.Step], focus: TextFocusStatus = .notEditable,
                 commandsOnly: Bool = false) throws -> CloudDecisionPlanner.Result {
        try CloudDecisionPlanner.resolve(json(steps), context: context(text, focus: focus, commandsOnly: commandsOnly), facts: facts(focus))
    }

    func testIndirectVolumeBecomesNativeCommand() throws {
        guard case .routes(let routes) = try resolve("ses çok yüksek", [.init(kind: .command, source: "ses çok yüksek", text: "sesi kıs")]),
              case .command = routes[0].route else { return XCTFail("Expected a native command") }
    }
    func testTwoRequestsBecomeTwoOrderedCommands() throws {
        guard case .routes(let routes) = try resolve("ses çok yüksek ve Bluetooth'u kapat", [
            .init(kind: .command, source: "ses çok yüksek", text: "sesi kıs"),
            .init(kind: .command, source: "Bluetooth'u kapat", text: "Bluetooth'u kapat")]),
              case .commands(let steps) = routes[0].route else { return XCTFail("Expected a native chain") }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].text, "ses çok yüksek")
        XCTAssertEqual(steps[1].command, .system(.bluetooth(on: false)))
    }
    func testDictationBodyContainingCommandsStaysLiteral() throws {
        let text = "Buraya yaz: Wi-Fi'yi aç ve Bluetooth'u kapat"
        let body = "Wi-Fi'yi aç ve Bluetooth'u kapat"
        guard case .routes(let routes) = try resolve(text, [.init(kind: .dictation, source: text, text: body)], focus: .editable),
              case .typed(let actual) = routes[0].route else { return XCTFail("Expected literal dictation") }
        XCTAssertEqual(actual, body)
    }
    func testExplicitQuestionInEditableFieldIsChat() throws {
        guard case .routes(let routes) = try resolve("Jarvis neden böyle oldu?", [
            .init(kind: .chat, source: "Jarvis neden böyle oldu?", text: "Jarvis neden böyle oldu?")], focus: .editable),
              case .chat = routes[0].route else { return XCTFail("Expected chat") }
    }
    func testUnsupportedSecondStepRejectsEntirePlan() {
        XCTAssertThrowsError(try resolve("sesi kıs ve dosyaları sil", [
            .init(kind: .command, source: "sesi kıs", text: "sesi kıs"),
            .init(kind: .command, source: "dosyaları sil", text: "rm -rf ~")]))
    }
    func testUnknownJSONFieldsRejected() throws {
        let answer = #"{"version":1,"requestID":"session-42","steps":[{"kind":"cancel","source":"iptal","text":""}],"shell":"ls"}"#
        XCTAssertThrowsError(try CloudDecisionPlanner.resolve(answer, context: context("iptal"), facts: facts()))
    }
    func testWrongVersionAndSessionRejected() throws {
        let steps: [CloudDecisionPlanner.Step] = [.init(kind: .cancel, source: "iptal", text: "")]
        for answer in [try json(steps, id: "old-session"), try json(steps, version: 1)] {
            XCTAssertThrowsError(try CloudDecisionPlanner.resolve(answer, context: context("iptal"), facts: facts()))
        }
    }
    func testInventedAndReorderedSourcesRejected() {
        XCTAssertThrowsError(try resolve("sesi kıs ve Bluetooth'u kapat", [
            .init(kind: .command, source: "Bluetooth'u kapat", text: "Bluetooth'u kapat"),
            .init(kind: .command, source: "sesi kıs", text: "sesi kıs")]))
        XCTAssertThrowsError(try resolve("merhaba", [.init(kind: .command, source: "sesi kıs", text: "sesi kıs")]))
    }
    func testOmittedUserRequestRejected() {
        XCTAssertThrowsError(try resolve("sesi kıs ve Bluetooth'u kapat", [
            .init(kind: .command, source: "sesi kıs", text: "sesi kıs")]))
    }
    func testNoSafeCaretDoesNotGrantDictation() {
        for focus in [TextFocusStatus.unknown, .notEditable] {
            XCTAssertThrowsError(try resolve("akşam geliyorum", [.init(kind: .dictation, source: "akşam geliyorum", text: "akşam geliyorum")], focus: focus))
        }
    }
    func testCloudCannotInventDictationBody() {
        XCTAssertThrowsError(try resolve("yarın geliyorum", [
            .init(kind: .dictation, source: "yarın geliyorum", text: "bugün geliyorum")], focus: .editable))
    }
    func testCloudRephraseCannotGrantSendOrLock() {
        for command in ["gönder", "ekranı kilitle", "Mac'i uyut", "tüm mailleri okundu işaretle"] {
            XCTAssertThrowsError(try resolve("bir şey yap", [.init(kind: .command, source: "bir şey yap", text: command)]))
        }
    }
    func testGreetingAndWorkResume() throws {
        guard case .routes(let routes) = try resolve("günaydın", [.init(kind: .greeting, source: "günaydın", text: "goodMorning")]),
              case .greeting(.goodMorning) = routes[0].route else { return XCTFail("Expected greeting") }
        guard case .routes(let routes) = try resolve("oraya tekrar dönelim", [.init(kind: .workResume, source: "oraya tekrar dönelim", text: "resume")]),
              case .workResume(.resume) = routes[0].route else { return XCTFail("Expected work resume") }
    }
    func testCancelAndClarifyHaveNoActions() throws {
        guard case .cancel = try resolve("boş ver", [.init(kind: .cancel, source: "boş ver", text: "")]) else { return XCTFail() }
        guard case .clarify = try resolve("onu aç", [.init(kind: .clarify, source: "onu aç", text: "Hangi uygulamayı açayım?")]) else { return XCTFail() }
        XCTAssertThrowsError(try resolve("sesi kıs ve onu aç", [
            .init(kind: .command, source: "sesi kıs", text: "sesi kıs"),
            .init(kind: .clarify, source: "onu aç", text: "Neyi?")]))
    }
    func testFollowUpCannotBecomeDictationOrChat() {
        for kind in [CloudDecisionPlanner.Step.Kind.dictation, .chat] {
            XCTAssertThrowsError(try resolve("şarkı sözleri", [.init(kind: kind, source: "şarkı sözleri", text: "şarkı sözleri")], focus: .editable, commandsOnly: true))
        }
    }
    func testNavigationAndDictationCannotInvalidateCapturedCaret() {
        XCTAssertThrowsError(try resolve("Safari'yi aç ve merhaba yaz", [
            .init(kind: .command, source: "Safari'yi aç", text: "Safari'yi aç"),
            .init(kind: .dictation, source: "merhaba yaz", text: "merhaba")], focus: .editable))
    }
    func testTruncatedRefusedOrEmptyCompletionsRejected() {
        for reason in ["length", "content_filter", "tool_calls"] {
            let data = Data("{\"choices\":[{\"finish_reason\":\"\(reason)\",\"message\":{\"content\":\"{}\"}}]}".utf8)
            XCTAssertThrowsError(try CloudReasoningClient.content(data))
        }
        XCTAssertThrowsError(try CloudReasoningClient.content(Data(#"{"choices":[{"finish_reason":"stop","message":{"refusal":"no","content":"{}"}}]}"#.utf8)))
    }
    func testNegativeCommandCannotExecuteEvenIfModelLabelsItCommand() {
        XCTAssertThrowsError(try resolve("Bluetooth'u kapatma", [
            .init(kind: .command, source: "Bluetooth'u kapatma", text: "Bluetooth'u kapat")]))
        XCTAssertThrowsError(try resolve("sesi kısma", [.init(kind: .command, source: "sesi kısma", text: "sesi kıs")]))
    }
    func testNegativeClauseIsIgnoredAndPositiveClauseStillRuns() throws {
        guard case .routes(let routes) = try resolve("Bluetooth'u kapatma, sadece sesi kıs", [
            .init(kind: .ignore, source: "Bluetooth'u kapatma", text: ""),
            .init(kind: .command, source: "sadece sesi kıs", text: "sesi kıs")]),
              case .command = routes[0].route else { return XCTFail() }
        XCTAssertEqual(routes.count, 1)
    }
    func testCloudCannotInventExactVolumeLevel() {
        XCTAssertThrowsError(try resolve("ses çok yüksek", [.init(kind: .command, source: "ses çok yüksek", text: "sesi yüzde 70 yap")]))
    }
    func testApprovedLiveCloudPlanCorpus() throws {
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: "cloud-routing-v2", withExtension: "json", subdirectory: "Fixtures"))
        let path = ProcessInfo.processInfo.environment["JARVIS_CLOUD_PLAN_FIXTURES"] ?? bundled.path
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for item in cases {
            let label = item["label"] as! String
            let raw = item["context"] as! [String: Any]
            let text = raw["transcript"] as! String
            let focus: TextFocusStatus = raw["focus"] as? String == "editable" ? .editable : .notEditable
            let answer = item["answer"] as! String
            let decoded = try JSONDecoder().decode(CloudDecisionPlanner.Plan.self, from: Data(answer.utf8))
            XCTAssertEqual(decoded.mode.rawValue, item["mode"] as? String, label)
            if let body = item["body"] as? String {
                XCTAssertEqual(decoded.steps.first?.text, body, label)
                XCTAssertEqual(decoded.steps.first?.send, item["send"] as? Bool, label)
            }
            let resolved = try CloudDecisionPlanner.resolve(answer,
                context: context(text, focus: focus, commandsOnly: raw["commandsOnly"] as! Bool), facts: facts(focus))
            switch (label, resolved) {
            case ("multi", .routes(let routes)):
                guard case .commands(let steps) = routes[0].route else { return XCTFail(label) }
                XCTAssertEqual(steps.count, 2)
                XCTAssertEqual(steps[1].command, .system(.bluetooth(on: true)))
            case ("calendar", .routes(let routes)):
                guard case .command(.system(.calendarEvent)) = routes[0].route else { return XCTFail(label) }
            case ("music", .routes(let routes)):
                guard case .command(.spotify) = routes[0].route else { return XCTFail(label) }
            case ("greeting", .routes(let routes)):
                guard case .greeting(.goodMorning) = routes[0].route else { return XCTFail(label) }
            case ("chat", .routes(let routes)):
                guard case .chat = routes[0].route else { return XCTFail(label) }
            case ("existing_send", .routes(let routes)):
                guard case .sendExistingMessage = routes[0].route else { return XCTFail(label) }
            case ("volume", .routes(let routes)), ("negation", .routes(let routes)):
                guard case .command(let command) = routes[0].route else { return XCTFail(label) }
                XCTAssertEqual(command, CommandRewriter.safeCommand("sesi kıs", context: facts(focus).commandContext()))
            case ("cancel", .cancel), ("ambiguous", .clarify): break
            case (_, .routes(let routes)) where item["mode"] as? String == "dictation":
                if item["send"] as? Bool == true {
                    guard case .agent(let delivery) = routes[0].route else { return XCTFail(label) }
                    XCTAssertTrue(delivery.send)
                    XCTAssertEqual(delivery.body, item["body"] as? String)
                } else {
                    guard case .typed(let body) = routes[0].route else { return XCTFail(label) }
                    XCTAssertEqual(body, item["body"] as? String)
                }
            default: XCTFail(label)
            }
        }
    }

    func testDictationSendFlagMapsToPasteAndSend() throws {
        let text = "Bu fonksiyonu düzelt ve testleri çalıştır sonra gönder"
        let body = "Bu fonksiyonu düzelt ve testleri çalıştır"
        guard case .routes(let routes) = try resolve(text, [.init(kind: .dictation, source: text, text: body, send: true)], focus: .editable),
              case .agent(let delivery) = routes[0].route else { return XCTFail() }
        XCTAssertEqual(delivery.body, body)
        XCTAssertTrue(delivery.send)
        XCTAssertNil(delivery.target)
    }
    func testImplicitCodingRequestStaysDictation() throws {
        let text = "Bu fonksiyonu düzelt ve testleri çalıştır"
        guard case .routes(let routes) = try resolve(text, [.init(kind: .dictation, source: text, text: text)], focus: .editable),
              case .typed(let body) = routes[0].route else { return XCTFail() }
        XCTAssertEqual(body, text)
    }
    func testSendRequiresExplicitDirectiveOutsideBody() {
        for (source, body) in [("merhaba", "merhaba"), ("Buraya yaz: gönder", "gönder"),
                               ("Merhaba ama gönderme", "Merhaba"),
                               ("Gönder butonunu düzelt", "Gönder butonunu düzelt"),
                               ("Buraya yaz: merhaba gönder", "merhaba gönder")] {
            XCTAssertThrowsError(try resolve(source, [.init(kind: .dictation, source: source, text: body, send: true)], focus: .editable), source)
        }
    }
    func testBinaryModeCannotMixCommandAndDictation() throws {
        let steps: [CloudDecisionPlanner.Step] = [.init(kind: .dictation, source: "merhaba", text: "merhaba")]
        let invalid = CloudDecisionPlanner.Plan(version: 2, mode: .command, requestID: "session-42", steps: steps)
        XCTAssertThrowsError(try CloudDecisionPlanner.resolve(String(decoding: JSONEncoder().encode(invalid), as: UTF8.self), context: context("merhaba", focus: .editable), facts: facts(.editable)))
    }
    func testStandaloneSendUsesExistingDraft() throws {
        guard case .routes(let routes) = try resolve("gönder", [.init(kind: .request, source: "gönder", text: "gönder")], focus: .editable),
              case .sendExistingMessage = routes[0].route else { return XCTFail() }
    }
    func testExplicitWriteFromTypedPanelUsesCapturedEditableTarget() throws {
        let source = "Buraya yaz: merhaba"
        var captured = context(source)
        captured.targetFocus = "editable"
        let answer = try json([.init(kind: .dictation, source: source, text: "merhaba")])
        guard case .routes(let routes) = try CloudDecisionPlanner.resolve(answer, context: captured, facts: facts()),
              case .typed("merhaba") = routes[0].route else { return XCTFail() }
        let implicit = try json([.init(kind: .dictation, source: "merhaba", text: "merhaba")])
        captured = context("merhaba")
        captured.targetFocus = "editable"
        XCTAssertThrowsError(try CloudDecisionPlanner.resolve(implicit, context: captured, facts: facts()))
    }
    func testNamedDictationRetainsExplicitTarget() throws {
        let source = "Codex'e gönder: merhaba"
        guard case .routes(let routes) = try resolve(source, [.init(kind: .dictation, source: source, text: "merhaba", send: true)]),
              case .agent(let agent) = routes[0].route else { return XCTFail() }
        XCTAssertEqual(agent.target, .codex)
        XCTAssertEqual(agent.body, "merhaba")
        XCTAssertTrue(agent.send)
    }

    func testStructuredCloudBodyIsNotStreamed() {
        let body = CloudReasoningClient.body(.init(model: "test", messages: [], timeout: 25, temperature: 0, maxTokens: 1800),
                                             schema: CloudDecisionPlanner.schema, thinkingOff: false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
    }
}
