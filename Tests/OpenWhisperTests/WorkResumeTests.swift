import XCTest
@testable import OpenWhisper

final class WorkResumeTests: XCTestCase {
    func testNaturalReturnsToTheRecappedWork() {
        for text in ["Tamam kaldığımız yerden devam edelim", "Aa orası doğru hatırladım devam edelim",
                     "Oraya tekrar dönelim", "Oraya tekrar bakalım", "Hey Jarvis, oraya bir daha bakalım.",
                     "Peki o zaman o sohbete dönelim", "Kaldığımız yere geri dönelim",
                     "O projeye devam edelim", "Oraya bakabilir miyiz?", "Devam"] {
            XCTAssertEqual(WorkResume.action(text), .resume, text)
        }
    }

    func testDoesNotTurnOtherRequestsOrDictationIntoNavigation() {
        for text in ["Buraya yaz kaldığımız yerden devam edelim", "Devam edelim bunu yaz",
                     "Oraya dönelim ve Ali'ye mesaj gönder", "Bu sohbete dönmek istemiyorum",
                     "Devam edelim mi bilmiyorum", "Müziğe devam et", "Videoya devam et",
                     "Oraya dönelim dediğimde ne oluyor", "Tamam", "Evet", "Hatırladım",
                     "İptal butonunu düzelt", "Sonraki projeye geç", "Devam etme"] {
            XCTAssertNil(WorkResume.action(text), text)
        }
    }

    func testRepeatAndCancel() {
        for text in ["Tekrar anlat", "Özeti bir daha söyle", "Tamam yeniden özetle"] {
            XCTAssertEqual(WorkResume.action(text), .repeatSummary, text)
        }
        for text in ["Boş ver", "Tamam iptal", "Devam etmeyelim", "Gerek yok", "Hayır"] {
            XCTAssertEqual(WorkResume.action(text), .cancel, text)
        }
    }

    func testDestinationIsPinnedEvenWhenAnotherChatBecomesNewerOrTitleChanges() {
        let now = Date()
        let work = GreetingBriefing.Work(project: "Jarvis", title: "Eski başlık", excerpt: "", activity: now,
                                        agent: .codex, sessionID: "recapped")
        let context = WorkResume.Context(work: work, summary: "Özet", createdAt: now)
        let candidates = [
            CloudSessionNavigation.Candidate(id: "newer", title: "Başka sohbet", activity: now.timeIntervalSince1970 + 10, excerpt: ""),
            CloudSessionNavigation.Candidate(id: "recapped", title: "Yeni başlık", activity: now.timeIntervalSince1970, excerpt: "")
        ]
        XCTAssertEqual(WorkResume.destination(context, candidates: candidates, now: now)?.id, "recapped")
        XCTAssertNil(WorkResume.destination(context, candidates: [candidates[0]], now: now))
        XCTAssertNil(WorkResume.destination(context, candidates: candidates, now: now.addingTimeInterval(901)))
        XCTAssertNil(WorkResume.destination(context, candidates: candidates, now: now.addingTimeInterval(-1)))
        XCTAssertNil(WorkResume.destination(.init(work: nil, summary: "Yok", createdAt: now), candidates: candidates, now: now))
    }

    func testWorkSelectionSkipsUnusableRowsAndKeepsAgentIdentity() {
        let now = Date()
        let projects = [AgentProject(name: "Jarvis", folder: "/test", latestSession: .init(id: "valid", title: "Çalışma", lastActivity: now))]
        let candidates = [
            CloudSessionNavigation.Candidate(id: "unmapped", title: "Başka", activity: now.timeIntervalSince1970 + 1, excerpt: ""),
            CloudSessionNavigation.Candidate(id: "valid", title: "Çalışma", activity: now.timeIntervalSince1970, excerpt: "Son durum")
        ]
        let work = GreetingBriefing.latestWork(agent: .claudeCode, projects: projects, candidates: candidates, now: now)
        XCTAssertEqual(work?.sessionID, "valid")
        XCTAssertEqual(work?.agent, .claudeCode)
        XCTAssertEqual(work?.excerpt, "Son durum")
        let future = CloudSessionNavigation.Candidate(id: "valid", title: "Çalışma", activity: now.timeIntervalSince1970 + 120, excerpt: "")
        XCTAssertNil(GreetingBriefing.latestWork(agent: .codex, projects: projects, candidates: [future], now: now))
    }

    func testLocalGreetingSourceReadOnly() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LOCAL_SESSION_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only check of actual local work history")
        }
        let work = try XCTUnwrap(GreetingBriefing.latestWork())
        let agent = try XCTUnwrap(work.agent)
        let id = try XCTUnwrap(work.sessionID)
        XCTAssertFalse(work.project.isEmpty)
        XCTAssertTrue(CloudSessionNavigation.load(agent).contains { $0.id == id })
    }
}

@MainActor
final class WorkResumeRoutingTests: XCTestCase {
    func testRecapContinuationOverridesEditorFocusButNotDictationOrConfirmations() {
        var facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                                      focus: .editable, hasTargetApp: true, hasWorkRecap: true)
        for text in ["Tamam kaldığımız yerden devam edelim", "Oraya tekrar bakalım", "Tekrar anlat", "Boş ver"] {
            guard case .workResume = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Expected contextual continuation: \(text)")
                continue
            }
        }
        for text in ["Buraya yaz devam edelim", "Oraya dönelim bunu yaz"] {
            guard case .typed = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Explicit dictation wins: \(text)")
                continue
            }
        }
        facts.pendingWhatsAppSend = true
        guard case .whatsAppConfirmation = VoiceRouter.route("Devam edelim", facts: facts) else {
            return XCTFail("Pending send confirmation must win")
        }
        facts.pendingWhatsAppSend = false
        facts.pendingDeletion = true
        if case .workResume = VoiceRouter.route("Devam edelim", facts: facts) { XCTFail("Pending deletion must win") }
        facts.pendingDeletion = false
        facts.isVoiceCommand = false
        if case .workResume = VoiceRouter.route("Devam edelim", facts: facts) { XCTFail("Keyboard dictation must remain dictation") }
        facts.isVoiceCommand = true
        facts.hasWorkRecap = false
        if case .workResume = VoiceRouter.route("Devam edelim", facts: facts) { XCTFail("No recap means no implied destination") }
        facts.hasWorkRecap = true
        facts.commandAmongPlayback = true
        if case .workResume = VoiceRouter.route("Devam edelim", facts: facts) { XCTFail("Playback recovery must not navigate") }
    }
}
