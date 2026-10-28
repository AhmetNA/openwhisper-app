import XCTest
@testable import OpenWhisper

/// Claude Code's permission questions answered by voice: the question said, the answer read,
/// the hook's JSON written, the hook's HTTP request read. No sockets or audio.
final class ClaudePermissionTests: XCTestCase {

    private func request(_ json: String) -> ClaudePermission.Request {
        ClaudePermission.Request(json: Data(json.utf8))!
    }

    private let bash = """
    {"tool_name":"Bash","cwd":"/Users/a/Projects/Bitirme","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules"},
     "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}
    """

    func testQuestion() {
        XCTAssertEqual(ClaudePermission.question(for: request(bash)),
                       "Bitirme projesinde Claude bir komut çalıştırmak istiyor: Remove node_modules. İzin veriyor musun?")
        XCTAssertEqual(ClaudePermission.question(for: request(#"{"tool_name":"Edit","tool_input":{"file_path":"/x/AppState.swift"}}"#)),
                       "Claude AppState.swift dosyasını düzenlemek istiyor. İzin veriyor musun?")
        XCTAssertEqual(ClaudePermission.question(for: request(#"{"tool_name":"WebFetch","cwd":"/p/App","tool_input":{"url":"https://code.claude.com/docs"}}"#)),
                       "App projesinde Claude code.claude.com adresini açmak istiyor. İzin veriyor musun?")
        XCTAssertEqual(ClaudePermission.question(for: request(#"{"tool_name":"mcp__gmail__send_message","tool_input":{}}"#)),
                       "Claude gmail aracını kullanmak istiyor: send_message. İzin veriyor musun?")
        XCTAssertEqual(ClaudePermission.detail(for: request(bash)), "Claude izin istiyor · Bash: rm -rf node_modules")
        XCTAssertNil(ClaudePermission.Request(json: Data("{}".utf8)))
    }

    func testAnswers() {
        let cases: [(String, ClaudePermission.Answer?)] = [
            ("Evet.", .allow),
            ("Evet, izin ver.", .allow),
            ("Tamam Jarvis", .allow),
            ("Onayla", .allow),
            ("Her zaman.", .always),
            ("Evet, her zaman izin ver", .always),
            ("Bir daha sorma", .always),
            ("Hayır.", .deny(nil)),
            ("Hayır hayır", .deny(nil)),
            ("İzin verme", .deny(nil)),
            ("Hayır, önce testleri çalıştır.", .deny("önce testleri çalıştır")),
            ("Reddet ve bana planı anlat", .deny("ve bana planı anlat")),
            // Only a plain yes allows.
            ("Evet ama önce testleri çalıştır", nil),
            ("Bilmiyorum", nil),
            ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ClaudePermission.answer(text), expected, text)
        }
    }

    private func decision(_ answer: ClaudePermission.Answer, _ json: String) -> [String: Any] {
        let data = ClaudePermission.hookOutput(answer, request: request(json))
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let output = object["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        return output["decision"] as! [String: Any]
    }

    func testHookOutput() {
        XCTAssertEqual(decision(.allow, bash)["behavior"] as? String, "allow")
        XCTAssertNil(decision(.allow, bash)["updatedPermissions"])
        let always = decision(.always, bash)
        XCTAssertEqual(always["behavior"] as? String, "allow")
        XCTAssertEqual((always["updatedPermissions"] as? [[String: Any]])?.first?["destination"] as? String, "localSettings")
        let denied = decision(.deny("önce testleri çalıştır"), bash)
        XCTAssertEqual(denied["behavior"] as? String, "deny")
        XCTAssertEqual(denied["message"] as? String, "önce testleri çalıştır")
        XCTAssertEqual(decision(.deny(nil), bash)["message"] as? String, "Kullanıcı sesle reddetti.")
    }

    func testRequestBody() {
        let body = #"{"tool_name":"Bash"}"#
        let full = "POST /claude/permission HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        XCTAssertEqual(ClaudePermissionServer.body(of: Data(full.utf8)), Data(body.utf8))
        XCTAssertNil(ClaudePermissionServer.body(of: Data(full.dropLast(3).utf8)))
        XCTAssertNil(ClaudePermissionServer.body(of: Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n".utf8)))
    }
}
