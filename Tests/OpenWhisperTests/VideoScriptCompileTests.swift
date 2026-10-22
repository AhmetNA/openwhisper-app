import XCTest
@testable import OpenWhisper

/// The video AppleScripts are only run against a real Safari, so a syntax error showed up as
/// "Safari'ye ulaşılamadı" in use (2026-10-15: `before`/`after` are AppleScript keywords).
/// Compiling them catches that without Safari.
final class VideoScriptCompileTests: XCTestCase {
    func compile(_ source: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("s.applescript")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", dir.appendingPathComponent("s.scpt").path, script.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return process.terminationStatus == 0 ? "" : message
    }

    func testFullscreenScriptCompiles() throws {
        XCTAssertEqual(try compile(VideoController.fullscreenScript), "")
    }

    func testBestTabScriptCompiles() throws {
        XCTAssertEqual(try compile(VideoController.bestTabScript("(function(){return 'ok';})()")), "")
    }
}
