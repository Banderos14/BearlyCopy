import XCTest
@testable import PromptRelayKit

final class StoreWatcherTests: XCTestCase {
    func testOnlyHistoryAndConfigChangesCount() {
        let root = "/Users/u/Library/Application Support/PromptRelay"
        XCTAssertTrue(StoreWatcher.isRelevant(root + "/events/abc.jsonl", root: root))
        XCTAssertTrue(StoreWatcher.isRelevant(root + "/config.json", root: root))
        XCTAssertTrue(StoreWatcher.isRelevant(root + "/events", root: root))
        XCTAssertFalse(StoreWatcher.isRelevant(root + "/handler.log", root: root), "every hook run writes the log")
        XCTAssertFalse(StoreWatcher.isRelevant(root + "/events/abc.jsonl.lock", root: root))
        XCTAssertFalse(StoreWatcher.isRelevant(root + "/config.json.123.tmp", root: root))
        XCTAssertFalse(StoreWatcher.isRelevant("/elsewhere/events/x.jsonl", root: root))
    }

    func testMissingDirectoryFallsBack() {
        let watcher = StoreWatcher(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) {}
        XCTAssertEqual(watcher.start(), .unavailable)
    }

    func testAppendToSessionFileIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pr-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("events"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events/s.jsonl")
        try Data("{}\n".utf8).write(to: file)

        let changed = expectation(description: "change reported")
        changed.assertForOverFulfill = false
        let watcher = StoreWatcher(directory: dir, latency: 0.1) { changed.fulfill() }
        XCTAssertEqual(watcher.start(), .watching)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)  // FSEvents only reports events after the stream started
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{\"a\":1}\n".utf8))
        try handle.close()
        wait(for: [changed], timeout: 5)
    }

    func testLogOnlyChangesAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pr-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let changed = expectation(description: "no change reported")
        changed.isInverted = true
        let watcher = StoreWatcher(directory: dir, latency: 0.1) { changed.fulfill() }
        XCTAssertEqual(watcher.start(), .watching)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try Data("2026 Stop via=plugin stored\n".utf8).write(to: dir.appendingPathComponent("handler.log"))
        wait(for: [changed], timeout: 1.5)
    }
}
