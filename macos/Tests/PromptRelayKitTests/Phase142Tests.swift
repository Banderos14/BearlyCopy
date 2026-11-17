import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 14.2: three real bugs the owner hit using BearlyCopy itself.
///
/// 1. "4 not verified" never moved after two manual checks: the Answer
///    chip's count was `EvidenceCheck`'s own fixed list of unverified claims
///    (never affected by the checklist), while the four checkable items
///    live in a *different* struct (`ReviewChecklist`) with its own ticks.
///    Confirmed by reading this very session's own captured turn 4 (Phase
///    14.1) from the Core: the `plutil`/`grep` command that returned exit 1
///    is `kind: "other"`, not a test or a build, amid several `kind: "build"`
///    and `kind: "test"` commands that all exited 0 — exactly the "1 failed"
///    the owner saw next to Claude's "all tests pass."
/// 2. Copy with Context showed one row and "+4 more" at common compact
///    heights (330–360 pt) with room in its own card to spare:
///    `PairedRows`' top-row cap was only Task's own height or 32 % of the
///    budget, never informed by how little the bottom row (`minBottom`)
///    actually needed. Reproduced and fixed with real AppKit/SwiftUI
///    measurements (`IslandHost`), not arithmetic.
@MainActor
final class Phase142Tests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p142.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP142-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr142-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Part I: manual verification progress vs. evidence provenance

    func testFourPendingChecksCountDownAsTheyAreTicked() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let checklist = try XCTUnwrap(m.reviewChecklist)
        XCTAssertEqual(checklist.items.map(\.id), ["ui", "build", "ci"], "the real items for this fixture")
        let n = checklist.items.count
        XCTAssertEqual(m.reviewProgress?.summary, "\(n) checks left")
        m.setReviewChecked(checklist.items[0].id, true)
        XCTAssertEqual(m.reviewProgress?.summary, "\(n - 1) checks left")
        m.setReviewChecked(checklist.items[1].id, true)
        XCTAssertEqual(m.reviewProgress?.summary, "\(n - 2) check\(n - 2 == 1 ? "" : "s") left")
        m.setReviewChecked(checklist.items[1].id, false)                 // Uncheck → remaining goes back up
        XCTAssertEqual(m.reviewProgress?.summary, "\(n - 1) checks left")
        m.setReviewChecked(checklist.items[1].id, true)
        m.setReviewChecked(checklist.items[2].id, true)
        XCTAssertEqual(m.reviewProgress?.summary, "All checks completed")
        XCTAssertEqual(m.reviewProgress?.isComplete, true)
    }

    func testTheEvidenceChipCombinesObservedFailuresAndChecklistProgressNeverMergingThem() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let checklist = try XCTUnwrap(m.reviewChecklist)
        // Before the fix this was still "6 observed · 1 failed · 3 not
        // verified" after two ticks — unaffected by the ticks at all.
        let before = EvidenceChip.combinedSummary(m)
        XCTAssertEqual(before, "6 observed · 1 build failed · 1 likely not an error · 3 checks left")
        m.setReviewChecked(checklist.items[0].id, true)
        m.setReviewChecked(checklist.items[1].id, true)
        let after = EvidenceChip.combinedSummary(m)
        XCTAssertEqual(after, "6 observed · 1 build failed · 1 likely not an error · 1 check left",
                      "ticking checklist items changes the checks-left count, never the observed/failed facts")
        XCTAssertNotEqual(before, after)
    }

    func testUnverifiedClaimsAndPendingChecksAreIndependentCounts() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let evidence = try XCTUnwrap(m.evidence)
        let claimedUnverifiedBefore = evidence.items(.notVerified).count
        let checklist = try XCTUnwrap(m.reviewChecklist)
        // Checking only one of several leaves a visibly different "checks
        // left" count while the claims Evidence Check could not verify
        // stay exactly as many as before — two unrelated numbers.
        m.setReviewChecked(checklist.items[0].id, true)
        XCTAssertEqual(m.reviewProgress?.remaining, checklist.items.count - 1)
        XCTAssertNotEqual(claimedUnverifiedBefore, m.reviewProgress?.remaining, "two different numbers in this fixture, not the same concept")
        for item in checklist.items { m.setReviewChecked(item.id, true) }
        let evidenceAfter = try XCTUnwrap(m.evidence)
        XCTAssertEqual(evidenceAfter.items(.notVerified).count, claimedUnverifiedBefore,
                      "Evidence Check's own unverified-claim count never changes because the user ticked checklist boxes")
        XCTAssertEqual(m.reviewProgress?.remaining, 0)
    }

    func testCheckedByYouNeverBecomesConfirmedLocally() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let checklist = try XCTUnwrap(m.reviewChecklist)
        let buildItem = try XCTUnwrap(checklist.items.first { $0.id == "build" })
        let confirmedBefore = Set(TrustSummary.make(evidence: m.evidence, completeness: m.completeness, checklist: checklist)
            .rows(.confirmed).map(\.text))
        m.setReviewChecked(buildItem.id, true)
        XCTAssertEqual(m.reviewCheckState(buildItem.id), .checked)
        let summary = TrustSummary.make(evidence: m.evidence, completeness: m.completeness, checklist: m.reviewChecklist)
        // Still in "needs verification", never promoted to "confirmed locally".
        XCTAssertTrue(summary.rows(.needsVerification).contains { $0.checklistID == buildItem.id })
        XCTAssertFalse(summary.rows(.confirmed).contains { $0.text == buildItem.text })
        let confirmedAfter = Set(summary.rows(.confirmed).map(\.text))
        XCTAssertEqual(confirmedBefore, confirmedAfter, "ticking a checklist item adds nothing to Confirmed locally")
    }

    func testCIWithoutIntegrationOffersNotApplicableAndItIsNotAPassedCheck() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let checklist = try XCTUnwrap(m.reviewChecklist)
        let ci = try XCTUnwrap(checklist.items.first { $0.id == "ci" })
        XCTAssertTrue(ci.allowsNotApplicable)
        XCTAssertEqual(m.reviewCheckState(ci.id), .pending)
        m.setReviewNotApplicable(ci.id, true)
        XCTAssertEqual(m.reviewCheckState(ci.id), .notApplicable)
        XCTAssertFalse(m.isReviewChecked(ci.id), "Not applicable is not the same as a passed CI check")
        // It still counts as resolved for the checklist's own progress.
        XCTAssertTrue(m.reviewProgress!.resolvedCount > 0)
        // Checking it afterwards clears Not applicable (mutually exclusive).
        m.setReviewChecked(ci.id, true)
        XCTAssertEqual(m.reviewCheckState(ci.id), .checked)
        XCTAssertFalse(m.isReviewNotApplicable(ci.id))
    }

    func testDifferentResultsHaveIndependentVerificationProgress() async throws {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:13:51.000000Z", lastTurn: 2)]
        core.turnsBySession["sa"] = [turn(1, preview: "one", chars: 3), turn(2, preview: "two", chars: 3)]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        m.selectSession("sa")
        m.selectTurn(1)
        // Imported reports always carry at least one checklist-worthy item
        // ("choice") so both refs have something to check.
        let ref1Text = m.importReport(text: "# A\nDone.", task: "t", projectPath: "/a", sessionLabel: nil)
        _ = ref1Text
        let ref1 = try XCTUnwrap(m.currentRef)
        let item1 = try XCTUnwrap(m.reviewChecklist?.items.first)
        m.setReviewChecked(item1.id, true)
        XCTAssertEqual(m.reviewCheckState(item1.id), .checked)
        _ = m.importReport(text: "# B\nAlso done.", task: "t2", projectPath: "/a", sessionLabel: nil)
        let ref2 = try XCTUnwrap(m.currentRef)
        XCTAssertNotEqual(ref1.key, ref2.key)
        let item2 = try XCTUnwrap(m.reviewChecklist?.items.first { $0.id == item1.id })
        XCTAssertEqual(m.reviewCheckState(item2.id), .pending, "a new result starts with nothing ticked")
    }

    func testSameNativeSessionIDDifferentProfilesDoNotShareChecksOrAttachments() async throws {
        // Phase 12: equal native session ids in two profiles key to two
        // different local session keys, so Phase 12's existing separation
        // alone already protects per-result state; confirm it still holds.
        let core = FakeCore(projects: [project("/a", sessions: 2, last: "2026-10-29T16:13:51.000000Z")])
        let personal = Phase12Tests.session("personal", provider: "claude_code", host: "claude_desktop", profile: "cc-personal",
                                            project: "/a", last: "2026-10-29T16:13:51.000000Z")
        let work = Phase12Tests.session("work", provider: "claude_code", host: "claude_desktop", profile: "cc-work",
                                        project: "/a", last: "2026-10-29T16:13:52.000000Z")
        core.sessionsByProject["/a"] = [personal, work]
        // Two turns each, viewing the OLDER one: "Make sure this is the
        // right answer" (`!isLatest`) always adds a checklist item, with no
        // dependency on observed commands or claims.
        core.turnsBySession["personal"] = [turn(1, preview: "p1", chars: 2), turn(2, preview: "p2", chars: 2)]
        core.turnsBySession["work"] = [turn(1, preview: "w1", chars: 2), turn(2, preview: "w2", chars: 2)]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        m.selectSession("personal")
        try await waitForTurns(m)
        m.selectTurn(1)
        let item = try XCTUnwrap(m.reviewChecklist?.items.first { $0.id == "choice" })
        m.setReviewChecked(item.id, true)
        m.selectSession("work")
        try await waitForTurns(m)
        m.selectTurn(1)
        XCTAssertEqual(m.reviewCheckState(item.id), .pending, "the other profile's conversation starts unchecked")
    }

    func testVerificationSurvivesCloseReopenDetailsToggleAndRestart() async throws {
        let m1 = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let ref = try XCTUnwrap(m1.currentRef)
        let item = try XCTUnwrap(m1.reviewChecklist?.items.first)
        m1.setReviewChecked(item.id, true)
        // Close/reopen Quick Peek, Details ↔ back, switching projects: none
        // of this clears the model's own ref — simulate by navigating.
        m1.navigate(to: .settings)
        m1.navigate(to: .home)
        XCTAssertEqual(m1.reviewCheckState(item.id), .checked)
        // "Restart the app": a brand-new AppModel reading the SAME store.
        let m2 = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        XCTAssertEqual(m2.currentRef, ref)
        XCTAssertEqual(m2.reviewCheckState(item.id), .checked, "the tick survives a restart")
        XCTAssertEqual(m2.reviewProgress?.remaining, (m2.reviewChecklist?.items.count ?? 0) - 1)
        // Phase 15: Not applicable must survive a restart too (the test only
        // covered the tick), and still never read as a passed CI check.
        if let ci = m2.reviewChecklist?.items.first(where: \.allowsNotApplicable) {
            m2.setReviewNotApplicable(ci.id, true)
            let m3 = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
            XCTAssertEqual(m3.reviewCheckState(ci.id), .notApplicable)
            XCTAssertFalse(m3.isReviewChecked(ci.id))
            XCTAssertEqual(m3.reviewCheckState(item.id), .checked)
        } else {
            XCTFail("the fixture has a CI item")
        }
    }

    // MARK: - Part II: command vs. test vs. build vs. unknown

    /// The real scenario (confirmed from this session's own captured turn 4
    /// — a Phase 14.1 `plutil`/`grep` command with `kind: "other"`, exit 1,
    /// alongside four `swift build`/`swift test` commands that all exited
    /// 0): Phase8Fixture mirrors it (a `kind: "other"` grep returning exit 1,
    /// AND — unlike the real example — a real build failure too, so both
    /// are separately exercised).
    func testADiagnosticCommandFailureIsNeverReportedAsATestOrBuildFailure() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let breakdown = try XCTUnwrap(m.evidence).failureBreakdown
        // Phase 15: the grep (kind "other", exit 1 = no match) is its own
        // outcome, "likely not an error" — no longer "1 command failed".
        XCTAssertEqual(breakdown.commandsFailed, 0, "the grep is not counted as a failed command")
        XCTAssertEqual(breakdown.likelyNotAnError, 1, "grep exit 1 (no match) is usually an answer, not an error")
        XCTAssertEqual(breakdown.buildsFailed, 1, "the real swift build failure")
        XCTAssertEqual(breakdown.testsFailed, 0, "no test command failed")
        XCTAssertEqual(breakdown.summary, "1 build failed · 1 likely not an error")
        XCTAssertFalse(breakdown.summary.contains("test failed"), "never invented")
        let row = HandoffContentsCard.commands(m.selectedTurn?.observed, captureOn: true, detail: m.selectedObservedDetail)
        XCTAssertEqual(row, breakdown.summary)
    }

    func testAFailingTestCommandIsCountedAsATestFailureOnly() {
        let commands: [ObservedCommand] = [
            cmd(kind: "test", exit: 1, command: "swift test --filter Foo"),
        ]
        let b = FailureBreakdown.make(commands)
        XCTAssertEqual(b.testsFailed, 1)
        XCTAssertEqual(b.buildsFailed, 0)
        XCTAssertEqual(b.commandsFailed, 0)
        XCTAssertEqual(b.summary, "1 test failed")
    }

    func testAFailingBuildIsCountedAsABuildFailureOnly() {
        let commands: [ObservedCommand] = [cmd(kind: "build", exit: 2, command: "xcodebuild build")]
        let b = FailureBreakdown.make(commands)
        XCTAssertEqual(b.buildsFailed, 1)
        XCTAssertEqual(b.testsFailed, 0)
        XCTAssertEqual(b.commandsFailed, 0)
        XCTAssertEqual(b.summary, "1 build failed")
    }

    func testALaterPassingTestRunAfterAnEarlierFailureIsObservedNotClaimedAsFixed() {
        let failing = cmd(kind: "test", exit: 1, command: "swift test", at: "2026-10-31T10:00:00.000000Z")
        let passing = cmd(kind: "test", exit: 0, command: "swift test", at: "2026-10-31T10:05:00.000000Z")
        let inspector = FailureInspector(commands: [failing, passing])
        XCTAssertEqual(inspector.entries.count, 1, "the earlier failure stays listed after a later pass")
        let entry = try! XCTUnwrap(inspector.entries.first)
        XCTAssertEqual(entry.command.at, failing.at, "the entry is the earlier, failing run")
        let later = try! XCTUnwrap(entry.later)
        XCTAssertTrue(later.passed)
        XCTAssertEqual(later.match, .sameCommand)
        // Phase 15: read the real sentence FailureCard shows (it used to be
        // only a comment here): an exit 0 was observed, never "fixed".
        let text = FailureCard.laterText(later)
        XCTAssertTrue(text.contains("exited 0"), text)
        XCTAssertTrue(text.contains("not proof that the cause is fixed"), text)
        for word in ["was fixed", "is fixed now", "recovered", "resolved"] { XCTAssertFalse(text.lowercased().contains(word), text) }
        // The earlier failure is still counted: a later pass never erases it.
        XCTAssertEqual(FailureBreakdown.make([failing, passing]).testsFailed, 1)
    }

    func testAConfirmedBuildErrorIsReportedAsABuildFailure() {
        let b = FailureBreakdown.make([cmd(kind: "build", exit: 1, command: "swift build")])
        XCTAssertEqual(b.buildsFailed, 1)
        XCTAssertTrue(b.summary == "1 build failed")
    }

    func testAShellPipelineWithAnAmbiguousExitCodeKeepsItsCaveat() {
        let compound = cmd(kind: "other", exit: 1, command: "swift build 2>&1 | tail -5", compound: true)
        let inspector = FailureInspector(commands: [compound])
        let entry = try! XCTUnwrap(inspector.entries.first)
        XCTAssertTrue(entry.caveats.contains { $0.contains("the exit code is the last process's") })
        // Still counted once, as one failed command — never assumed to prove
        // every step of the pipe failed, nor that it proves none did.
        let b = FailureBreakdown.make([compound])
        XCTAssertEqual(b.commandsFailed, 1)
    }

    func testNoToolEventsIsReportedHonestlyNotAsAFailure() {
        XCTAssertEqual(HandoffContentsCard.commands(nil, captureOn: true), "not recorded")
        XCTAssertEqual(HandoffContentsCard.commands(nil, captureOn: false), "capture off")
        let zero = ObservedCounts(toolEvents: 0, runsExitZero: 0, runsNonzero: 0, runsUnknown: 0, filesChanged: 0,
                                  backgroundStarted: 0, commandsNonzero: 0)
        XCTAssertEqual(HandoffContentsCard.commands(zero, captureOn: true), "none run")
    }

    func testAgentClaimsTestsPassedButTheObservedCommandFailedIsFlaggedNotHidden() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let evidence = try XCTUnwrap(m.evidence)
        XCTAssertTrue(evidence.items(.reported).contains { $0.text.contains("tests pass") })
        // The claim is listed, but a build genuinely failed — never painted over.
        XCTAssertGreaterThan(evidence.failureBreakdown.total, 0)
        XCTAssertTrue(evidence.items.contains { $0.kind == .observed && $0.alert })
    }

    func testTaskOutcomeUnknownWhenDoneIsClaimedWithNoTestOrBuildEvidence() {
        var input = EvidenceCheck.Input()
        input.observed = ObservedCounts(toolEvents: 3, runsExitZero: 3, runsNonzero: 0, runsUnknown: 0, filesChanged: 2,
                                        backgroundStarted: 0, commandsNonzero: 0)
        input.answer = "Everything works now, all done."
        let evidence = EvidenceCheck.make(input)
        XCTAssertTrue(evidence.items(.notVerified).contains { $0.text.hasPrefix("Task outcome unknown") })
    }

    private func waitForTurns(_ m: AppModel, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while m.turns.value == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        _ = try XCTUnwrap(m.turns.value, "turns did not load in time")
    }

    private func cmd(kind: String, exit: Int, command: String, at: String = "2026-10-31T10:00:00.000000Z",
                     compound: Bool = false) -> ObservedCommand {
        try! JSONDecoder().decode(ObservedCommand.self, from: Data("""
        {"at":"\(at)","command":"\(command)","kind":"\(kind)","outcome":"\(exit == 0 ? "ok" : "failed")","exit_code":\(exit),
         "duration_ms":100,"compound":\(compound),"background":false,"after_stop":false}
        """.utf8))
    }

    // MARK: - Part III: Copy with Context shows two full rows when it fits

    /// Real measurements (AppKit/SwiftUI layout), at the heights asked for.
    /// Before the fix: 1/5 rows visible with "+4 more" at 330/341/360 pt,
    /// despite slack in the card's own row budget. After: 2/5 (at least).
    func testCopyWithContextShowsAtLeastTwoFullRowsWhenThePhysicalSpaceAllows() async throws {
        let m = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let rows = HandoffContentsCard.rows(model: m)
        XCTAssertEqual(rows.map(\.title), ["Request & answer", "Commands", "Files changed", "Git status", "Attachments"])
        var sawOneRowOnly = false
        var checked: [CGFloat] = []
        for h: CGFloat in [268, 300, 330, 341, 360, 388, 410, 448, 500, 568] {
            let island = IslandHost(model: m, maxContentHeight: h)
            defer { island.close() }
            let f = island.presentation.layoutFrames
            guard let viewport = f["handoff.viewport"], let card = f["card.handoff"] else { continue }   // single column (< 330 pt)
            checked.append(h)
            let visible = rows.filter { row in
                guard let r = f["handoff.row.\(row.title)"] else { return false }
                return r.maxY <= viewport.maxY + 0.5
            }
            if visible.count == 1 { sawOneRowOnly = true }
            XCTAssertGreaterThanOrEqual(visible.count, 2, "at \(h) pt: \(visible.count)/\(rows.count) rows, viewport \(viewport)")
            XCTAssertEqual(f["handoff.more"] != nil, visible.count < rows.count, "“+N more” exactly when rows are hidden, at \(h) pt")
            // No half-visible rows: every row is wholly inside the viewport or wholly below it.
            for row in rows {
                guard let r = f["handoff.row.\(row.title)"] else { continue }
                let wholly_inside = r.maxY <= viewport.maxY + 0.5
                let wholly_below = r.minY >= viewport.maxY - 0.5
                XCTAssertTrue(wholly_inside || wholly_below, "\(row.title) \(r) is half-visible at \(h) pt (viewport \(viewport))")
            }
            // The Answer still gets a readable minimum (Phase 8's minBottom):
            // the fix must not starve it to grow Copy with Context.
            if let response = f["card.response"] {
                XCTAssertGreaterThanOrEqual(response.height, 130, "Answer keeps a readable minimum at \(h) pt")
            }
            // Never taller than it was: this redistributes the existing
            // budget, it does not grow the island.
            XCTAssertLessThanOrEqual(card.height, h, "the card never exceeds the whole budget")
        }
        XCTAssertFalse(sawOneRowOnly, "every two-column height now shows at least two rows")
        // Phase 15: the `guard … else { continue }` above could skip every
        // height and pass vacuously. Every height from 330 pt up must
        // actually have been measured.
        XCTAssertEqual(checked, [330, 341, 360, 388, 410, 448, 500, 568], "heights actually measured")
    }

    /// Phase 15: this test used to construct a `PairedRows` and assert
    /// nothing (`XCTAssertNoThrow` on a struct literal). It now checks the
    /// real height arithmetic: chrome 40 pt + rows of 22 pt, spacing 5.
    func testSingleRowFallbackWhenGenuinelyNothingElseFits() {
        let rows = PairedRows(rightWidth: 200, columnSpacing: 10, rowSpacing: 5, minBottom: 140,
                              rightMinRows: 2, rightRowHeight: 22, rightRowSpacing: 5)
        let oneRow: CGFloat = 40 + 22, twoRows: CGFloat = 40 + 22 + 5 + 22
        func split(_ budget: CGFloat, rightNatural: CGFloat = 40 + 5 * 22 + 4 * 5) -> (top: CGFloat, bottom: CGFloat) {
            rows.split(budget: budget, leftNatural: 30, rightNatural: rightNatural, rightSmallest: oneRow, topMin: oneRow,
                       topNatural: rightNatural, bottomMin: 120, bottomNatural: 600)
        }
        // Room for two rows and the Answer's 140 pt: exactly two rows.
        XCTAssertEqual(split(240).top, twoRows, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(split(240).bottom, 140)
        // Too little for two rows without starving the Answer: the slot is
        // at least one full row and less than two — the card's own bounded
        // scroll then shows one whole row + “+N more” (asserted on real
        // layout in the test above), never two half rows.
        let tight = split(215)
        XCTAssertGreaterThanOrEqual(tight.top, oneRow)
        XCTAssertLessThan(tight.top, twoRows, "two rows would starve the Answer here")
        XCTAssertGreaterThanOrEqual(tight.bottom, 140, "the Answer keeps its minimum")
        // A card with a single row never gets padded up to two.
        XCTAssertEqual(split(400, rightNatural: oneRow).top, oneRow, accuracy: 0.01)
        // Nothing is ever negative, whatever the budget.
        for budget: CGFloat in [0, 10, 100] {
            let r = split(budget)
            XCTAssertGreaterThanOrEqual(r.top, oneRow); XCTAssertGreaterThanOrEqual(r.bottom, 0)
        }
    }

    func testAnswerTaskAttachmentsAndContextPackSizesAreUnaffected() async throws {
        // Reuses the existing Phase 14 regression (different fixture, no
        // handoff rows pressure) to confirm this phase's PairedRows change
        // does not reintroduce half-visible lines elsewhere.
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["sa"] = [turn(1, preview: "Ответ", chars: 5, request: "Задача")]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        _ = m.importReport(text: Phase14LayoutTests.paragraphs, task: "t", projectPath: "/a", sessionLabel: nil)
        for h: CGFloat in [330, 341, 448] {
            let island = IslandHost(model: m, maxContentHeight: h)
            defer { island.close() }
            let f = island.presentation.layoutFrames
            if let task = f["card.task"], let handoff = f["card.handoff"] { XCTAssertEqual(task.height, handoff.height, accuracy: 0.5) }
        }
    }
}
