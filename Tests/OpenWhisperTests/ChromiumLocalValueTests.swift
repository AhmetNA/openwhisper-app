import XCTest
@testable import OpenWhisper

final class ChromiumLocalValueTests: XCTestCase {
    func testSnappyLiteralOverlapAndBadOffsets() {
        XCTAssertEqual(ChromiumLocalValue.unsnappy([5, 16] + Array("hello".utf8)), Array("hello".utf8))
        XCTAssertEqual(ChromiumLocalValue.unsnappy([6, 0, 97, 18, 1, 0]), Array("aaaaaa".utf8))
        XCTAssertNil(ChromiumLocalValue.unsnappy([6, 18, 1, 0]))
        XCTAssertNil(ChromiumLocalValue.unsnappy([5, 16, 97]))
    }
    func testLogLatestSequenceAndTombstone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Array("_https://claude.ai\0\u{1}epitaxy-unread-v1".utf8)
        func record(_ sequence: UInt8, _ value: String?) -> Data {
            var batch: [UInt8] = [sequence,0,0,0,0,0,0,0,1,0,0,0, value == nil ? 0 : 1, UInt8(key.count)] + key
            if let value { let bytes = [UInt8(1)] + Array(value.utf8); batch += [UInt8(bytes.count)] + bytes }
            return Data([0,0,0,0,UInt8(batch.count),0,1] + batch)
        }
        try record(2, "new").write(to: directory.appendingPathComponent("1.log"))
        try record(1, "old").write(to: directory.appendingPathComponent("2.log"))
        XCTAssertEqual(ChromiumLocalValue.read(directory: directory, origin: "https://claude.ai", key: "epitaxy-unread-v1"), "new")
        try record(3, nil).write(to: directory.appendingPathComponent("3.log"))
        XCTAssertNil(ChromiumLocalValue.read(directory: directory, origin: "https://claude.ai", key: "epitaxy-unread-v1"))
    }
}
