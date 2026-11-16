import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 15 (independent audit of Phases 14–14.2): regressions for the
/// defects confirmed in the audit. See docs/PHASE15_AUDIT.md.
@MainActor
final class Phase15Tests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p15.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP15-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr15-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - D1: review marks were pruned in hash order, not by recency

    /// Before: `newValue.prefix(200)` on a `Dictionary` kept an arbitrary
    /// 200 entries (Swift's per-process hash order). Past 200 marked
    /// answers, the tick the user had just made could be dropped at once.
    func testATickMadePast200MarkedAnswersIsKeptAndTheOldestAreDropped() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let key = try XCTUnwrap(m.currentRef?.key)
        let item = try XCTUnwrap(m.reviewChecklist?.items.first)
        // 250 answers marked before Phase 15 (no recency list stored yet).
        var legacy: [String: [String]] = [:]
        for i in 0..<250 { legacy[String(format: "legacy-%03d", i)] = ["build"] }
        defaults.set(legacy, forKey: AppModel.reviewChecksKey)

        m.setReviewChecked(item.id, true)

        XCTAssertEqual(m.reviewCheckState(item.id), .checked, "the tick just made is never the one pruned")
        let stored = try XCTUnwrap(defaults.dictionary(forKey: AppModel.reviewChecksKey) as? [String: [String]])
        XCTAssertEqual(stored.count, AppModel.reviewChecksLimit)
        XCTAssertNotNil(stored[key])
        // Entries without a recorded order rank below every recorded one and
        // among themselves by key: deterministic, never hash order.
        let expectedLegacy = Set((51..<250).map { String(format: "legacy-%03d", $0) })
        XCTAssertEqual(Set(stored.keys).subtracting([key]), expectedLegacy)
    }

    func testKeepingMostRecentFollowsTheOrderTheAnswersWereMarkedIn() {
        var all: [String: Set<String>] = [:]
        for i in 0..<5 { all["k\(i)"] = ["ui"] }
        // Marked k4, k0, k3, k1, k2 (oldest first): keep the newest three.
        let kept = AppModel.keepingMostRecent(all, order: ["k4", "k0", "k3", "k1", "k2"], limit: 3)
        XCTAssertEqual(Set(kept.keys), ["k3", "k1", "k2"])
        XCTAssertEqual(AppModel.keepingMostRecent(all, order: [], limit: 10), all, "under the limit nothing is dropped")
    }

    func testRemarkingAnOldAnswerMakesItRecentAgain() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let key = try XCTUnwrap(m.currentRef?.key)
        let item = try XCTUnwrap(m.reviewChecklist?.items.first)
        m.setReviewChecked(item.id, true)
        defaults.set(["other-1", key, "other-2"], forKey: AppModel.reviewRecentKey)
        m.setReviewChecked(item.id, false)
        XCTAssertEqual(defaults.stringArray(forKey: AppModel.reviewRecentKey)?.last, key)
    }

    // MARK: - D2: a piped or chained helper's exit code was read as the build's

    private func cmd(kind: String, exit: Int, command: String, compound: Bool = false,
                     at: String = "2026-11-07T10:00:00.000000Z") -> ObservedCommand {
        let json: [String: Any] = ["at": at, "command": command, "kind": kind, "outcome": exit == 0 ? "ok" : "failed",
                                   "exit_code": exit, "duration_ms": 100, "compound": compound, "background": false,
                                   "after_stop": false]
        return try! JSONDecoder().decode(ObservedCommand.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The common `swift build 2>&1 | grep -E "error|warning"`: a clean build
    /// makes grep find nothing and exit 1. Before Phase 15 this read
    /// "1 build failed"; the build's own result was never recorded.
    func testABuildPipedIntoGrepIsUnclearNotAFailedBuild() {
        let c = cmd(kind: "build", exit: 1, command: #"swift build 2>&1 | grep -E "error|warning""#, compound: true)
        let b = FailureBreakdown.make([c])
        XCTAssertEqual(b.buildsFailed, 0)
        XCTAssertEqual(b.buildsUnclear, 1)
        XCTAssertEqual(b.summary, "1 build unclear")
        XCTAssertFalse(b.isEmpty, "still a non-zero exit that was observed, never hidden")
    }

    func testABuildOrTestWhoseOwnExitCodeIsReportedStillCountsAsFailed() {
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "build", exit: 1, command: "swift build 2>&1")]).summary, "1 build failed",
                       "a redirection is not a pipe: the exit code is the build's")
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "test", exit: 1, command: "cd macos && swift test")]).summary, "1 test failed")
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "build", exit: 2, command: "make")]).summary, "1 build failed")
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "test", exit: 1, command: "FOO=1 pytest -q")]).summary, "1 test failed")
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "test", exit: 1, command: "swift test --filter A && swift test --filter B")]).summary,
                       "1 test failed", "every step is a test")
    }

    func testABuildFollowedByAnotherKindOfStepIsUnclear() {
        let b = FailureBreakdown.make([cmd(kind: "build", exit: 1, command: "swift build && swift test")])
        XCTAssertEqual(b.buildsUnclear, 1, "the exit code may be the test's; the build's result is unknown")
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "test", exit: 1, command: "pytest | tee log", compound: true)]).summary,
                       "1 test unclear")
    }

    func testDiagnosticNonMatchesAreNamedLikelyNotAnError() {
        let quoted = cmd(kind: "other", exit: 1, command: #"grep -E "foo|bar" Sources/a.swift"#)
        let redirected = cmd(kind: "other", exit: 1, command: "grep -rn Foo Sources 2>&1")
        XCTAssertTrue(FailureInspector.likelyNotAnError(quoted), "a quoted | is not a pipe")
        XCTAssertTrue(FailureInspector.likelyNotAnError(redirected), "2>&1 does not create a part named “1”")
        let b = FailureBreakdown.make([quoted, redirected])
        XCTAssertEqual(b.likelyNotAnError, 2)
        XCTAssertEqual(b.commandsFailed, 0)
        XCTAssertEqual(b.summary, "2 likely not an error")
        // grep exit 2 is a real error (bad pattern, missing file).
        XCTAssertEqual(FailureBreakdown.make([cmd(kind: "other", exit: 2, command: "grep x missing.txt")]).summary, "1 command failed")
    }

    /// The real Phase 14.1 command behind the owner's "1 failed": the line
    /// ends in `head`, so it is an ordinary failed command, not a no-match.
    func testTheRealPhase141DiagnosticLineIsAFailedCommand() {
        let line = #"plutil -p Info.plist 2>/dev/null | grep -iE "screen" ; echo "---"; grep -il "screen" en.lproj/*.strings 2>/dev/null; strings x.searchTerms 2>/dev/null | grep -i "screen" | head -10"#
        let b = FailureBreakdown.make([cmd(kind: "other", exit: 1, command: line, compound: true)])
        XCTAssertEqual(b.summary, "1 command failed")
    }

    func testEveryKindIsNamedSeparatelyInAFixedOrder() {
        let b = FailureBreakdown.make([
            cmd(kind: "other", exit: 1, command: "grep x f"),
            cmd(kind: "test", exit: 1, command: "swift test"),
            cmd(kind: "build", exit: 1, command: "swift build"),
            cmd(kind: "other", exit: 127, command: "nosuchtool"),
            cmd(kind: "build", exit: 1, command: "swift build | grep error", compound: true),
        ])
        XCTAssertEqual(b.summary, "1 build failed · 1 test failed · 1 command failed · 1 build unclear · 1 likely not an error")
        XCTAssertEqual(b.total, 5, "every observed non-zero exit is still counted")
    }

    /// The Swift copy of the Core's command-kind prefixes must not drift
    /// from `plugin/prompt_relay/tools.py`.
    func testKindPrefixesMatchTheCore() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("plugin/prompt_relay/tools.py"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "KIND_PREFIXES = ("))
        let end = try XCTUnwrap(source.range(of: "\n)\n", range: start.upperBound..<source.endIndex))
        let block = String(source[start.upperBound..<end.lowerBound])
        var core: [(String, [String])] = []
        let entry = try NSRegularExpression(pattern: #"\("(\w+)",\s*\(([^)]*)\)\)"#)
        for match in entry.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            let kind = String(block[Range(match.range(at: 1), in: block)!])
            let list = String(block[Range(match.range(at: 2), in: block)!])
            let words = try NSRegularExpression(pattern: #""([^"]*)""#).matches(in: list, range: NSRange(list.startIndex..., in: list))
                .map { String(list[Range($0.range(at: 1), in: list)!]).trimmingCharacters(in: .whitespaces) }
            core.append((kind, words))
        }
        XCTAssertEqual(core.map(\.0), FailureBreakdown.kindPrefixes.map(\.kind))
        XCTAssertEqual(core.map(\.1), FailureBreakdown.kindPrefixes.map(\.prefixes))
    }
}
