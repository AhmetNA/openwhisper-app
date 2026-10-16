import XCTest
@testable import OpenWhisper

/// Runs a tiny stand-in `server.py` (the same `/health` contract as the model servers) from
/// a temporary install folder, with the system Python.
@MainActor
final class LocalModelServerTests: XCTestCase {
    private var directory: URL!

    /// Answers "loading" twice, then "ready"; or an error when started with `--fail`.
    private static let script = """
        import argparse, json, os
        from http.server import BaseHTTPRequestHandler, HTTPServer
        parser = argparse.ArgumentParser()
        parser.add_argument("--port", type=int)
        parser.add_argument("--parent-pid", type=int)
        parser.add_argument("--fail", action="store_true")
        args = parser.parse_args()
        calls = {"n": 0}
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                calls["n"] += 1
                body = {"pid": os.getpid(), "parent_pid": args.parent_pid}
                if args.fail: body["error"] = "no model"
                else: body["ready"] = calls["n"] > 2
                data = json.dumps(body).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(data)
        HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
        """

    override func setUp() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "no system Python")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalModelServerTests-\(UUID().uuidString)")
        let bin = directory.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Not a symlink: /usr/bin/python3 is an xcrun shim that looks up the tool by its name.
        let wrapper = bin.appendingPathComponent("python")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try Self.script.write(to: directory.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func freePort() -> Int { Int.random(in: 20_000..<30_000) }

    func testStartsWaitsAndStops() async throws {
        let server = LocalModelServer(.init(port: freePort(), directory: directory))
        XCTAssertTrue(server.isInstalled)
        let initialHealth = await server.health()
        XCTAssertNil(initialHealth, "nothing should answer before start")

        let pid = try server.start()
        XCTAssertTrue(server.isRunning)
        guard case .ready(let json) = await server.waitUntilReady(timeout: 15, poll: .milliseconds(100)) else {
            return XCTFail("not ready")
        }
        XCTAssertEqual(json["pid"] as? Int, Int(pid))
        let stray = await server.strayPID()
        XCTAssertNil(stray, "our own server is not a stray")

        XCTAssertEqual(server.stop(), pid)
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.stop())
    }

    func testReportsALoadError() async throws {
        let server = LocalModelServer(.init(port: freePort(), directory: directory, extraArguments: ["--fail"]))
        _ = try server.start()
        defer { server.stop() }
        guard case .failed(let error) = await server.waitUntilReady(timeout: 15, poll: .milliseconds(100)) else {
            return XCTFail("expected a load error")
        }
        XCTAssertEqual(error, "no model")
    }

    func testSeesAServerSomeoneElseStarted() async throws {
        let port = freePort()
        let ours = LocalModelServer(.init(port: port, directory: directory))
        let pid = try ours.start()
        defer { ours.stop() }
        _ = await ours.waitUntilReady(timeout: 15, poll: .milliseconds(100))
        // Another owner of the same port didn't start it, but its parent pid is still this app.
        let other = LocalModelServer(.init(port: port, directory: directory))
        let stray = await other.strayPID()
        XCTAssertNil(stray, "a server this app started is never killed as a stray")
        XCTAssertEqual(ours.pid, pid)
    }

    func testEveryServerHasItsOwnPort() {
        let ports = LocalModelServer.allPorts()
        XCTAssertEqual(Set(ports).count, ports.count)
    }
}
