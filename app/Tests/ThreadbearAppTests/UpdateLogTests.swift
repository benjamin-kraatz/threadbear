import XCTest
@testable import Threadbear

final class UpdateLogTests: XCTestCase {
    func testTailHandlesMissingAndLongLogs() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(UpdateLogTail.read(file))
        try Data((String(repeating: "x", count: 9000) + "\nfinished\n").utf8).write(to: file)
        let tail = try XCTUnwrap(UpdateLogTail.read(file))
        XCTAssertTrue(tail.hasSuffix("finished"))
        XCTAssertLessThanOrEqual(tail.utf8.count, 8192)
    }
}
