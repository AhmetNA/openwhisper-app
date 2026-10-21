import XCTest
@testable import OpenWhisper

@MainActor
final class DamgaNormalizerTests: XCTestCase {
    private var directory: URL!
    private var normalizer: DamgaNormalizer?

    override func tearDown() async throws {
        normalizer?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(response: String = #"{"text":"150 TL"}"#, delay: Double = 0) throws -> DamgaNormalizer {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DamgaTests-\(UUID())")
        let bin = directory.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let script = """
        import argparse, json, os, time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        p = argparse.ArgumentParser()
        p.add_argument('--port', type=int)
        p.add_argument('--parent-pid', type=int)
        a = p.parse_args()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                data = json.dumps({'ready': True, 'service': 'jarvis-damga-1.0.3', 'parent_pid': a.parent_pid}).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(data)
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                time.sleep(\(delay))
                data = \(String(reflecting: response)).encode()
                self.send_response(200); self.end_headers()
                try: self.wfile.write(data)
                except BrokenPipeError: pass
        HTTPServer(('127.0.0.1', a.port), Handler).serve_forever()
        """
        try script.write(to: directory.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
        let instance = DamgaNormalizer(directory: directory, port: Int.random(in: 31_000..<40_000))
        normalizer = instance
        return instance
    }

    func testOnlyEnabledTurkishFinalOutputIsEligible() {
        XCTAssertTrue(DamgaNormalizer.shouldNormalize(enabled: true, language: "tr", text: "yüz elli lira"))
        XCTAssertFalse(DamgaNormalizer.shouldNormalize(enabled: false, language: "tr", text: "yüz elli lira"))
        XCTAssertFalse(DamgaNormalizer.shouldNormalize(enabled: true, language: "en", text: "one hundred"))
        XCTAssertFalse(DamgaNormalizer.shouldNormalize(enabled: true, language: "auto", text: "hello"))
        XCTAssertFalse(DamgaNormalizer.shouldNormalize(enabled: true, language: "tr", text: " \n"))
        XCTAssertFalse(DamgaNormalizer.shouldNormalize(enabled: true, language: "tr", text: String(repeating: "a", count: 4001)))
    }

    func testMissingInstallationReturnsInput() async {
        let instance = DamgaNormalizer(directory: URL(fileURLWithPath: "/nonexistent/DamgaTests"))
        let output = await instance.normalize("yüz elli lira")
        XCTAssertEqual(output, "yüz elli lira")
        XCTAssertTrue(instance.status.hasPrefix("Kurulu değil"))
    }

    func testHTTPBridgeAndRestartAfterStop() async throws {
        let instance = try fixture()
        let output = await instance.normalize("yüz elli lira")
        XCTAssertEqual(output, "150 TL")
        instance.stop()
        XCTAssertEqual(instance.status, "Kapalı")
        let restarted = await instance.normalize("yüz elli lira")
        XCTAssertEqual(restarted, "150 TL")
    }

    func testMalformedResponseKeepsInput() async throws {
        let instance = try fixture(response: "invalid JSON")
        let output = await instance.normalize("yüz elli lira")
        XCTAssertEqual(output, "yüz elli lira")
    }

    func testEmptyResponseKeepsInput() async throws {
        let instance = try fixture(response: #"{"text":""}"#)
        let output = await instance.normalize("yüz elli lira")
        XCTAssertEqual(output, "yüz elli lira")
    }

    func testTimeoutKeepsInput() async throws {
        let instance = try fixture(delay: 2)
        let prepared = await instance.prepare()
        XCTAssertTrue(prepared)
        let start = Date()
        let output = await instance.normalize("yüz elli lira")
        XCTAssertEqual(output, "yüz elli lira")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testDisablingDuringRequestKeepsInput() async throws {
        let instance = try fixture(delay: 0.25)
        let prepared = await instance.prepare()
        XCTAssertTrue(prepared)
        let task = Task { await instance.normalize("yüz elli lira") }
        try await Task.sleep(for: .milliseconds(50))
        instance.stop()
        let output = await task.value
        XCTAssertEqual(output, "yüz elli lira")
        XCTAssertEqual(instance.status, "Kapalı")
    }

    /// Set DAMGA_TEST_INSTALL to a setup.sh installation to exercise the real native WFST
    /// through exactly the same Swift process/HTTP bridge as dictation.
    func testRealNativeRuntimeWhenInstalled() async throws {
        guard let install = ProcessInfo.processInfo.environment["DAMGA_TEST_INSTALL"] else {
            throw XCTSkip("Set DAMGA_TEST_INSTALL for the optional real-runtime test")
        }
        let instance = DamgaNormalizer(directory: URL(fileURLWithPath: install), port: Int.random(in: 31_000..<40_000))
        normalizer = instance
        let samples = [
            ("yüz elli lira", "150 TL"),
            ("on beş ekim iki bin yirmi altı", "15 Ekim 2026"),
            ("telefonum sıfır beş otuz iki yüz yirmi üç kırk beş altmış yedi", "telefonum 0532 123 45 67"),
            ("derya nokta öztürk et gmail nokta com", "derya.ozturk@gmail.com"),
            ("https://example.com/API ve yüz elli lira", "https://example.com/API ve 150 TL"),
            ("a ve es ile yüz elli lira", "a ve es ile 150 TL"),
        ]
        for (input, expected) in samples {
            let output = await instance.normalize(input, protectedTerms: ["a ve es"])
            XCTAssertEqual(output, expected)
        }
    }
}
