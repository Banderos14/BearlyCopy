import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 15.1: one attribution rule for test/build exit codes, used by
/// Failure Inspector, Evidence Check, the Answer chip, Quick Peek and the
/// Copy with Context Commands row — and no alarm for diagnostic non-matches.
/// See docs/PHASE15_AUDIT.md §7.
@MainActor
final class Phase151Tests: XCTestCase {

    private func cmd(_ command: String?, kind: String, exit: Int?, compound: Bool? = nil,
                     outcome: String? = nil) -> ObservedCommand {
        var json: [String: Any] = ["at": "2026-11-08T10:00:00.000000Z", "kind": kind,
                                   "outcome": outcome ?? (exit == 0 ? "ok" : "failed"), "duration_ms": 100,
                                   "background": false, "after_stop": false]
        if let command { json["command"] = command } else { json["command_withheld"] = "possible_secret" }
        if let exit { json["exit_code"] = exit }
        // The Core's `has_compound`: a pipe, `;`, `||` or `&` (not `&&`).
        let text = command ?? ""
        json["compound"] = compound ?? (text.replacingOccurrences(of: "&&", with: "").range(of: #"\||;|&\s*$|&\s+\S"#, options: .regularExpression) != nil)
        return try! JSONDecoder().decode(ObservedCommand.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func detail(_ commands: [ObservedCommand]) -> ObservedDetail {
        let encoded = try! JSONSerialization.data(withJSONObject: ["commands": [], "files_changed": [], "shown_files": [],
                                                                   "artifacts": [], "notifications": 0])
        let empty = try! JSONDecoder().decode(ObservedDetail.self, from: encoded)
        return ObservedDetail(commands: commands, filesChanged: empty.filesChanged, shownFiles: [], artifacts: [], notifications: 0)
    }

    private func counts(_ commands: [ObservedCommand]) -> ObservedCounts {
        let runs = commands.filter { ["test", "build"].contains($0.kind ?? "") }
        return ObservedCounts(toolEvents: commands.count, runsExitZero: runs.filter { $0.exitCode == 0 }.count,
                              runsNonzero: runs.filter { ($0.exitCode ?? 0) != 0 }.count, runsUnknown: 0, filesChanged: 0,
                              backgroundStarted: 0, commandsNonzero: commands.filter { ($0.exitCode ?? 0) != 0 }.count)
    }

    private func evidence(_ commands: [ObservedCommand], answer: String = "Here is the change.") -> EvidenceCheck {
        var input = EvidenceCheck.Input()
        input.observed = counts(commands)
        input.detail = detail(commands)
        input.answer = answer
        return .make(input)
    }

    // MARK: 1. No false successes

    func testAPipedOrSemicolonHelperNeverMakesATestOrBuildPass() {
        let cases: [(String, String)] = [
            ("swift test | tee test.log", "test"), ("swift build | tee build.log", "build"),
            ("pytest | tail -20", "test"), ("swift build; echo done", "build"),
            ("swift build 2>&1 | grep -E \"error|warning\"", "build"), ("swift build || true", "build"),
        ]
        for (line, kind) in cases {
            for exit in [0, 1] {
                XCTAssertEqual(FailureBreakdown.stageResult(cmd(line, kind: kind, exit: exit)), .unclear, "\(line) exit \(exit)")
            }
        }
    }

    func testPipefailAttributesASuccessButNotAFailure() {
        for prefix in ["set -o pipefail; ", "set -euo pipefail && ", "set -eo pipefail\n"] {
            let line = prefix.replacingOccurrences(of: "\n", with: "; ") + "swift test 2>&1 | tee test.log"
            XCTAssertEqual(FailureBreakdown.stageResult(cmd(line, kind: "test", exit: 0)), .passed,
                           "\(line): every stage exited 0")
            XCTAssertEqual(FailureBreakdown.stageResult(cmd(line, kind: "test", exit: 1)), .unclear,
                           "\(line): which stage failed is not recorded")
        }
    }

    func testAndChainsPassOnlyWhenEveryStepExitedZero() {
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("swift build && swift test", kind: "build", exit: 0)), .passed)
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("swift build && swift test", kind: "build", exit: 1)), .unclear)
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("cd macos && swift test", kind: "test", exit: 1)), .failed,
                       "cd is setup, not a stage")
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("echo start; swift test", kind: "test", exit: 1)), .failed,
                       "after `;` the exit code is the last stage's, the test's")
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("swift test", kind: "test", exit: 0)), .passed)
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("swift test", kind: "test", exit: 1)), .failed)
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("swift build &", kind: "build", exit: 0)), .unclear, "backgrounded")
        XCTAssertNil(FailureBreakdown.stageResult(cmd("grep x f", kind: "other", exit: 1)))
    }

    func testEvidenceCheckDoesNotCountAPipedTestAsPassing() {
        let e = evidence([cmd("swift test | tee test.log", kind: "test", exit: 0)], answer: "All tests pass.")
        XCTAssertFalse(e.items.contains { $0.text == "1 test command exited 0" }, "\(e.items.map(\.text))")
        XCTAssertTrue(e.items(.observed).contains { $0.text.contains("test result is unknown") })
        XCTAssertTrue(e.items(.notVerified).contains { $0.text.contains("may be another step's") })
        XCTAssertFalse(e.items(.notVerified).contains { $0.text.contains("a test command exited 0") })

        let done = evidence([cmd("swift build | tee build.log", kind: "build", exit: 0)], answer: "All done.")
        XCTAssertTrue(done.items(.notVerified).contains { $0.text.hasPrefix("Task outcome unknown") },
                      "an unattributable exit 0 does not back up “done”")

        let strict = evidence([cmd("set -o pipefail; swift test | tee test.log", kind: "test", exit: 0)], answer: "All tests pass.")
        XCTAssertTrue(strict.items(.observed).contains { $0.text == "1 test command exited 0" })
    }

    // MARK: 2. Consistent semantics everywhere

    func testAnUnidentifiedFailingStepIsNeverCalledABuildFailure() {
        let c = cmd("swift build && swift test", kind: "build", exit: 1)
        let meaning = FailureInspector.meaning(c)
        XCTAssertFalse(meaning.contains("did not succeed"), meaning)
        XCTAssertTrue(meaning.contains("may belong to another step"), meaning)
        XCTAssertEqual(FailureBreakdown.make([c]).summary, "1 build unclear")
        let e = evidence([c])
        XCTAssertEqual(e.failureBreakdown.summary, "1 build unclear")
        XCTAssertFalse(e.items.contains { $0.alert }, "unclear, not an alarm: \(e.items.map(\.text))")
        XCTAssertTrue(e.items(.observed).contains { $0.text.contains("returned exit 1") && $0.text.contains("result is unknown") },
                      "the exit code itself stays visible")
        let row = HandoffContentsCard.commands(counts([c]), captureOn: true, detail: detail([c]))
        XCTAssertEqual(row, e.failureBreakdown.summary, "Commands row and chip agree")
        let checklist = ReviewChecklist.make(evidence: e, completeness: ArtifactCompleteness(lines: []), changedPaths: [],
                                             answer: nil, handoffFiles: 0, imported: false, isLatest: true)
        XCTAssertEqual(checklist.items.first { $0.id == "build" }?.reason,
                       "A test or build result could not be established from its exit code")
    }

    func testAProvenBuildFailureStaysAnAlarmEverywhere() {
        let c = cmd("cd macos && swift build", kind: "build", exit: 1)
        XCTAssertEqual(FailureInspector.meaning(c), "The build command exited 1: the build did not succeed.")
        let e = evidence([c])
        XCTAssertTrue(e.items.contains { $0.alert && $0.text == "1 command returned exit 1" })
        XCTAssertEqual(HandoffContentsCard.commands(counts([c]), captureOn: true, detail: detail([c])), "1 build failed")
        let checklist = ReviewChecklist.make(evidence: e, completeness: ArtifactCompleteness(lines: []), changedPaths: [],
                                             answer: nil, handoffFiles: 0, imported: false, isLatest: true)
        XCTAssertEqual(checklist.items.first { $0.id == "build" }?.reason, "A command failed during the turn")
        let facts = PeekContent.facts(observed: counts([c]), summary: AppModel.MaterialSummary(), detail: detail([c])).map(\.text)
        XCTAssertTrue(facts.contains("1 failed command"), "\(facts)")
    }

    func testQuickPeekAndCommandsRowNameAnUnclearPassAsUnclear() {
        let c = cmd("swift test | tee test.log", kind: "test", exit: 0)
        XCTAssertEqual(HandoffContentsCard.commands(counts([c]), captureOn: true, detail: detail([c])), "1 unclear")
        let facts = PeekContent.facts(observed: counts([c]), summary: AppModel.MaterialSummary(), detail: detail([c])).map(\.text)
        XCTAssertTrue(facts.contains("1 result to double-check"), "\(facts)")
        XCTAssertFalse(facts.contains { $0.contains("completed") }, "never “completed” for an unattributable exit 0: \(facts)")
        // Without per-command detail the aggregate wording is unchanged.
        let aggregate = PeekContent.facts(observed: counts([c]), summary: AppModel.MaterialSummary()).map(\.text)
        XCTAssertTrue(aggregate.contains("1 command completed"))
    }

    // MARK: 3. Diagnostics are facts, not alarms

    func testAGrepWithoutAMatchIsListedButNeitherAlarmsNorAsksForARebuild() {
        let grep = cmd("grep -rn TODO Sources", kind: "other", exit: 1)
        let e = evidence([grep])
        XCTAssertFalse(e.items.contains { $0.alert }, "\(e.items.map(\.text))")
        XCTAssertTrue(e.items(.observed).contains { $0.text.contains("returned exit 1, likely a normal no-match") },
                      "the exit code stays visible as an observed fact")
        XCTAssertEqual(e.failureBreakdown.summary, "1 likely not an error")
        let checklist = ReviewChecklist.make(evidence: e, completeness: ArtifactCompleteness(lines: []), changedPaths: [],
                                             answer: nil, handoffFiles: 0, imported: false, isLatest: true)
        XCTAssertNil(checklist.items.first { $0.id == "build" }, "no mandatory rerun for a grep")
        let facts = PeekContent.facts(observed: counts([grep]), summary: AppModel.MaterialSummary(), detail: detail([grep])).map(\.text)
        XCTAssertFalse(facts.contains { $0.contains("failed") }, "\(facts)")
        XCTAssertTrue(facts.contains("1 likely not an error"))
        // A grep with exit 2 (bad pattern, missing file) is a real error.
        XCTAssertTrue(evidence([cmd("grep x missing.txt", kind: "other", exit: 2)]).items.contains { $0.alert })
    }

    // MARK: 4. Withheld command text

    func testAWithheldCompoundLineIsNeverDefinitiveEvidence() {
        let piped0 = cmd(nil, kind: "test", exit: 0, compound: true)
        let piped1 = cmd(nil, kind: "build", exit: 1, compound: true)
        XCTAssertEqual(FailureBreakdown.stageResult(piped0), .unclear)
        XCTAssertEqual(FailureBreakdown.stageResult(piped1), .unclear)
        XCTAssertEqual(FailureBreakdown.make([piped1]).summary, "1 build unclear")
        XCTAssertTrue(FailureInspector.meaning(piped1).contains("withheld"))
        XCTAssertFalse(evidence([piped0], answer: "All tests pass.").items.contains { $0.text == "1 test command exited 0" })
        // A withheld *simple* line keeps its own exit code.
        XCTAssertEqual(FailureBreakdown.stageResult(cmd(nil, kind: "test", exit: 1, compound: false)), .failed)
        XCTAssertEqual(FailureBreakdown.stageResult(cmd(nil, kind: "test", exit: 0, compound: false)), .passed)
        // Interrupted, or failed without an exit code: unclear, not failed.
        XCTAssertEqual(FailureBreakdown.stageResult(cmd("swift test", kind: "test", exit: nil, outcome: "interrupted")), .unclear)
    }
}
