import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// A local turn as the Core reports it after a real working session: a
/// failed build, a compound command, a grep that matched nothing, a later
/// passing test, changed files. Shared by the Phase 8 checks and renders.
@MainActor
enum Phase8Fixture {
    static let answer = """
    ## Done

    I fixed the tooltip layout and the Answer footer.

    - `IslandTooltips.swift`: measured width
    - `IslandViews.swift`: the Evidence chip has its own row

    All tests pass.
    """

    static let commands: [[String: Any]] = [
        ["at": "2026-10-31T10:00:01.000000Z", "command": "swift build", "kind": "build", "outcome": "failed", "exit_code": 1,
         "duration_ms": 8_400, "compound": false, "background": false, "after_stop": false,
         "output_tail": "error: cannot find 'TipLayout' in scope\nerror: fatalError"],
        ["at": "2026-10-31T10:00:20.000000Z", "command": "grep -rn TipLayout Sources", "kind": "other", "outcome": "failed",
         "exit_code": 1, "duration_ms": 40, "compound": false, "background": false, "after_stop": false],
        ["at": "2026-10-31T10:01:00.000000Z", "command": "swift build 2>&1 | tail -5", "kind": "build", "outcome": "ok",
         "exit_code": 0, "duration_ms": 9_100, "compound": true, "background": false, "after_stop": false],
        ["at": "2026-10-31T10:02:00.000000Z", "command": "swift test --filter Tooltip", "kind": "test", "outcome": "ok",
         "exit_code": 0, "duration_ms": 21_000, "compound": false, "background": false, "after_stop": false],
        ["at": "2026-10-31T10:03:00.000000Z", "command": "git status --short", "kind": "git", "outcome": "ok",
         "exit_code": 0, "duration_ms": 30, "compound": false, "background": false, "after_stop": false],
        // Withheld by the Core's secret scan: no command text at all.
        ["at": "2026-10-31T10:03:30.000000Z", "command_withheld": "possible_secret", "kind": "test", "outcome": "ok",
         "exit_code": 0, "duration_ms": 120, "compound": false, "background": false, "after_stop": false],
    ]

    static func turnJSON(_ index: Int, detail: Bool, files: Int = 6) -> [String: Any] {
        var t: [String: Any] = [
            "index": index, "status": "stop_received", "link": "prompt_id",
            "request": ["preview": "Fix the tooltips and the Answer footer overlap", "truncated": false, "char_count": 46,
                        "utf8_bytes": 46, "prompt_id": "p\(index)", "received_at": "2026-10-31T09:59:00.000000Z"],
            "final_response": ["preview": String(answer.prefix(60)), "truncated": true, "char_count": answer.count,
                               "utf8_bytes": answer.utf8.count, "prompt_id": "p\(index)", "received_at": "2026-10-31T10:04:00.000000Z",
                               "text": answer],
            "response_event_count": 1, "background_tasks": NSNull(), "error": NSNull(), "candidate_request_turns": [],
            "observed": ["tool_events": 12, "runs_exit_zero": 2, "runs_nonzero": 1, "runs_unknown": 0, "files_changed": files,
                         "background_started": 0, "commands_nonzero": 2],
            "request_origin": "user",
        ]
        if detail {
            t["observed_detail"] = [
                "commands": commands, "notifications": 0, "shown_files": [], "artifacts": [],
                "files_changed": (0..<files).map { ["path": "/a/macos/Sources/PromptRelayKit/Notch/File\($0)WithALongName.swift",
                                                    "tools": ["Edit"], "count": 1 + $0 % 3] },
            ]
        }
        return t
    }

    static func turn(_ index: Int, detail: Bool) -> Turn {
        try! JSONDecoder().decode(Turn.self, from: JSONSerialization.data(withJSONObject: turnJSON(index, detail: detail)))
    }

    static func model(defaults: MemorySettingsStore, board: NSPasteboard, root: URL) async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:04:00.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-31T10:04:00.000000Z")]
        core.turnsBySession["sa"] = [turn(1, detail: false)]
        core.showResult = { key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, detail: true)), warnings: []))
        }
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        let deadline = Date().addingTimeInterval(3)
        while m.detail.value == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return m
    }
}

@MainActor
final class Phase8Tests: XCTestCase {
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!
    var suite: String!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p8.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP8-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p8-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
    }

    func model() async -> AppModel { await Phase8Fixture.model(defaults: defaults, board: board, root: root) }

    /// Shows the tip of the control whose help text starts with `prefix`.
    func showTip(_ island: IslandHost, _ prefix: String) throws -> CGRect {
        island.settle()
        let (owner, control) = try XCTUnwrap(island.tips.controls.first { $0.value.text.hasPrefix(prefix) }, "a control with \(prefix)")
        island.tips.show(owner, text: control.text, anchor: control.anchor)
        island.settle()
        return control.anchor
    }

    // MARK: Answer card and footer

    /// Phase 8 P0: the Evidence chip was an overlay on the Full Report row
    /// and covered "View Full Report"; the card could draw onto the footer.
    func testFullReportLinkEvidenceChipAndFooterNeverOverlap() async throws {
        let m = await model()
        XCTAssertNotNil(m.evidence, "the fixture has an Evidence chip")
        for maxContent: CGFloat in [268, 341, 448, 568] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            island.assertNoOverlap(["response.full", "response.evidence", "home.actions"])
            let f = island.presentation.layoutFrames
            let card = try XCTUnwrap(f["card.response"]), footer = try XCTUnwrap(f["home.actions"])
            XCTAssertLessThanOrEqual(card.maxY, footer.minY - 4, "the Answer card ends above the footer (\(maxContent))")
            for id in ["response.full", "response.evidence"] {
                let r = try XCTUnwrap(f[id])
                XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(id) \(r) inside the Answer card \(card) (\(maxContent))")
            }
            island.close()
        }
    }

    // MARK: Tooltips

    /// Phase 8 P0: a tip is as narrow as its lines (inline-block), stays in
    /// the black island, never covers its own control and does not lie on
    /// the copies or footer icons.
    func testTipsAvoidTheMainActionsAndStayInside() async throws {
        let m = await model()
        for maxContent: CGFloat in [268, 341, 448] {
            for surface in [NotchPresentation.Surface.expanded, .peek] {
                let island = IslandHost(model: m, surface: surface, maxContentHeight: maxContent)
                island.settle()
                let size = CGSize(width: island.width, height: island.height)
                let safe = TipPlacement.safeArea(island: size, band: 32)
                let prefixes = [Labels.copyAnswerHelp, Labels.copyWithContextHelp, "Browse previous", "Your recent copied"]
                let actions = island.tips.controls.filter { entry in prefixes.contains { entry.value.text.hasPrefix($0) } }
                XCTAssertGreaterThanOrEqual(actions.count, 2, "\(surface): the copies are registered")
                for (owner, control) in island.tips.controls where safe.intersects(control.anchor) {
                    island.tips.show(owner, text: control.text, anchor: control.anchor)
                    island.settle()
                    let tip = try XCTUnwrap(island.presentation.layoutFrames["tooltip"], control.text)
                    XCTAssertTrue(TipPlacement.safeArea(island: CGSize(width: island.width, height: island.height), band: 32).insetBy(dx: -1, dy: -1).contains(tip), "\(surface) \(maxContent) “\(control.text)” \(tip)")
                    XCTAssertTrue(island.contains(tip), "inside the island outline: \(control.text)")
                    XCTAssertFalse(tip.intersects(control.anchor.insetBy(dx: 1, dy: 1)), "not over its own control: \(control.text)")
                    for (other, action) in actions where other != owner && !action.anchor.intersects(control.anchor) {
                        XCTAssertFalse(tip.intersects(action.anchor.insetBy(dx: 1, dy: 1)),
                                       "\(surface) \(maxContent): “\(control.text)” covers “\(action.text)”")
                    }
                }
                island.tips.hideAll()
                island.close()
            }
        }
    }

    func testWrappedTipEndsWhereItsLongestLineEnds() {
        let tips = IslandTooltips()
        var last = CGRect.zero
        let host = NSHostingView(rootView: IslandTooltipOverlay(tips: tips, size: CGSize(width: 640, height: 400))
            .environment(\.islandFrameSink, { id, r in if id == "tooltip" { last = r } }))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        func measure(_ text: String) -> CGSize {
            tips.show(UUID(), text: text, anchor: CGRect(x: 300, y: 100, width: 26, height: 26))
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return last.size
        }
        let one = measure("Copy the original answer")
        // Phase 11: tooltip text is 11 pt (was 10.5), one line is 22 pt with its inset.
        XCTAssertLessThan(one.height, 23, "a short tip is one line")
        // Just over the maximum: two balanced lines, not one full line and a stub.
        let two = measure("Answer, request, commands, files, Git and chosen attachments as Markdown")
        XCTAssertGreaterThan(two.height, one.height * 1.6)
        XCTAssertLessThan(two.width, IslandTooltipOverlay.maxWidth * 0.85, "no empty strip on the right: \(two)")
    }

    // MARK: Black artifact in Observed Work

    /// Phase 8 P0: a withheld command's row had the tip "" — an empty black
    /// box drawn over the list of changed files. Blank tips never show.
    func testBlankTipIsNeverShown() async throws {
        let tips = IslandTooltips()
        tips.enter(UUID(), text: "  \n", anchor: CGRect(x: 10, y: 10, width: 20, height: 20))
        try await Task.sleep(nanoseconds: IslandTooltips.delay + 100_000_000)
        XCTAssertNil(tips.tip)
        let m = await model()
        m.route = .activity
        let island = IslandHost(model: m, maxContentHeight: 448)
        defer { island.close() }
        XCTAssertFalse(island.tips.controls.isEmpty)
        XCTAssertTrue(island.tips.controls.values.allSatisfy { !IslandTooltips.isBlank($0.text) }, "no control registers a blank tip")
        XCTAssertTrue(island.tips.controls.values.contains { $0.text.hasPrefix("Command hidden") }, "the withheld row says why")
    }

    // MARK: Failure Inspector

    func testFailureInspectorReportsOnlyWhatWasObserved() throws {
        let detail = try XCTUnwrap(Phase8Fixture.turn(1, detail: true).observedDetail)
        let inspector = FailureInspector(commands: detail.commands)
        XCTAssertEqual(inspector.entries.map(\.command.command), ["swift build", "grep -rn TipLayout Sources"])
        let build = inspector.entries[0], grep = inspector.entries[1]
        XCTAssertTrue(build.meaning.contains("build"))
        XCTAssertFalse(build.likelyNotAnError)
        XCTAssertEqual(build.later?.match, .sameTool, "the later `swift build 2>&1 | tail -5` is the same tool, not the same command")
        XCTAssertEqual(build.later?.command.command, "swift build 2>&1 | tail -5")
        XCTAssertTrue(build.later?.passed == true)
        XCTAssertTrue(build.unavailable.contains { $0.contains("last lines") }, "the tail is partial and says so")
        XCTAssertTrue(grep.likelyNotAnError, "grep exit 1 = no match")
        XCTAssertNil(grep.later)
        XCTAssertTrue(grep.unavailable.contains { $0.contains("only for failed tests and builds") })
        for e in inspector.entries {
            XCTAssertFalse((e.meaning + e.caveats.joined()).lowercased().contains("fixed"), "never claims a fix")
        }
    }

    func testFailureInspectorEdgeCases() throws {
        func cmd(_ json: [String: Any]) throws -> ObservedCommand {
            var j: [String: Any] = ["at": "2026-10-31T10:00:00.000000Z", "compound": false, "background": false, "after_stop": false]
            j.merge(json) { $1 }
            return try JSONDecoder().decode(ObservedCommand.self, from: JSONSerialization.data(withJSONObject: j))
        }
        let pipe = try cmd(["command": "pytest | tee log", "kind": "test", "outcome": "failed", "exit_code": 2, "compound": true])
        let chain = try cmd(["command": "cd x && make test", "kind": "test", "outcome": "failed", "exit_code": 2])
        let interrupted = try cmd(["command": "swift test", "kind": "test", "outcome": "interrupted"])
        let missing = try cmd(["command": "foo", "kind": "other", "outcome": "failed", "exit_code": 127])
        let bg = try cmd(["command": "server", "kind": "other", "outcome": "ok", "background": true])
        let secret = try cmd(["command_withheld": "possible_secret", "kind": "build", "outcome": "failed", "exit_code": 1,
                              "tail_withheld": "possible_secret"])
        let entries = FailureInspector(commands: [pipe, chain, interrupted, missing, bg, secret]).entries
        XCTAssertEqual(entries.count, 5, "a background start is not a failure")
        XCTAssertTrue(entries[0].caveats.first?.contains("last process") == true)
        XCTAssertTrue(entries[1].caveats.first?.contains("&&") == true)
        XCTAssertTrue(entries[2].meaning.contains("Interrupted"))
        XCTAssertTrue(entries[3].meaning.contains("127"))
        XCTAssertTrue(entries[4].unavailable.contains { $0.contains("Command text: withheld") })
        XCTAssertTrue(entries[4].unavailable.contains { $0.contains("Output: withheld") })
        XCTAssertEqual(FailureInspector.program("cd a && FOO=1 sudo grep -q x f"), "grep")
        XCTAssertEqual(FailureInspector.tool("cd a && swift test --filter X"), "swift test")
    }

    // MARK: Living Relay 2.0

    /// Phase 8 P0: vertical movement anywhere on the screen moves the look.
    /// Before, `tanh(dy/160)` was ≥ 0.96 for any pointer 300 pt or more
    /// below Relay, so up and down did almost nothing.
    func testVerticalPointerMovementMovesTheLookAcrossTheScreen() {
        let x: CGFloat = 300
        let ys: [CGFloat] = [-20, 50, 150, 300, 500, 800, 1100]   // down from Relay
        let looks = ys.map { NotchController.gaze(dx: x, dy: $0) }
        for (a, b) in zip(looks, looks.dropFirst()) {
            XCTAssertGreaterThan(b.y, a.y + 0.02, "lower pointer, lower look: \(a) → \(b)")
        }
        XCTAssertLessThan(looks[0].y, -0.2, "pointer up at the menu bar: Relay looks up")
        XCTAssertGreaterThan(looks.last!.y, 0.85, "pointer low on the screen: Relay looks down")
        // The old per-axis mapping for comparison: almost flat below 300 pt.
        let old = ys.map { tanh($0 / 160) }
        XCTAssertLessThan(old[6] - old[3], 0.06)
        XCTAssertGreaterThan(looks[6].y - looks[3].y, 0.25)
        // Continuous: no jump anywhere along a sweep, also near Relay itself.
        var last = NotchController.gaze(dx: -400, dy: -10)
        for i in 1...800 {
            let p = NotchController.gaze(dx: -400 + CGFloat(i), dy: -10 + CGFloat(i) * 0.4)
            XCTAssertLessThan(hypot(p.x - last.x, p.y - last.y), 0.05, "no jump at step \(i)")
            XCTAssertLessThanOrEqual(hypot(p.x, p.y), 1.0001, "inside the range")
            last = p
        }
        XCTAssertEqual(NotchController.gaze(dx: 0, dy: 0), .zero)
    }

    /// Up and down turn the face like left and right: the nose moves more
    /// than the eyes, the eyes more than the outline, the ears the other way.
    func testPitchIsLayeredAndEarsMoveAgainstIt() {
        let up = MascotView.Turn(yaw: 0, pitch: -1), down = MascotView.Turn(yaw: 0, pitch: 1)
        XCTAssertLessThan(up.pitchShift(1), up.pitchShift(0.7))
        XCTAssertLessThan(up.pitchShift(0.7), up.pitchShift(0.25))
        XCTAssertGreaterThan(up.earRise, 0, "looking up, the ears stay back (lower than the rising face)")
        XCTAssertEqual(down.earRise, 0, "looking down the face drops; the ears never rise above the screen")
        XCTAssertGreaterThanOrEqual(abs(down.pitchShift(1)), 0.08, "a clear vertical turn")
    }

    /// Expressive: a livelier head spring (some overshoot), Subtle calm;
    /// both settle and stop drawing.
    func testExpressiveOvershootsMoreAndBothSettle() {
        func peak(_ liveliness: CGFloat) -> (CGFloat, Bool) {
            let m = RelayMotion()
            m.headScale = 1; m.liveliness = liveliness
            var t = 1000.0
            _ = m.frame(at: t)
            m.look(at: CGPoint(x: 0, y: 1), now: t)
            var top: CGFloat = 0
            for _ in 0..<240 { t += 1.0 / 60; top = max(top, m.frame(at: t).head.y) }
            return (top, m.isSettled)
        }
        let (subtle, s1) = peak(0), (expressive, s2) = peak(1)
        XCTAssertGreaterThan(expressive, subtle + 0.01, "more overshoot when Expressive")
        XCTAssertLessThan(expressive, 1.12, "still a soft overshoot")
        XCTAssertTrue(s1 && s2, "both settle within 4 s; the display link then pauses")
    }

    func testNodAndPerkAreShortAndSettle() {
        for kind in [RelayMotion.Reaction.nod, .perk] {
            let m = RelayMotion()
            var t = 50.0
            _ = m.frame(at: t)
            m.react(kind, now: t)
            var moved = false
            for _ in 0..<60 { t += 1.0 / 60; let f = m.frame(at: t); if f.nod != 0 || f.lift != 0 { moved = true } }
            XCTAssertTrue(moved, "\(kind) is visible")
            XCTAssertTrue(m.isSettled, "\(kind) ends within a second")
        }
    }

    // MARK: Report Ready indicator

    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func testReadyIndicatorStates() async throws {
        let t0 = iso(Date().addingTimeInterval(-3600))
        let core = FakeCore(projects: [project("/a", sessions: 2, last: t0)])
        core.showResult = { [weak core] key, index in
            guard let core, let session = try? core.session(key) else {
                return .failure(.api(code: "not_found", message: "test session missing"))
            }
            return .success(CoreResult(data: ShowData(session: session, turn: turn(index, text: "answer")), warnings: []))
        }
        core.sessionsByProject["/a"] = [sessionSummary("s1", project: "/a", last: t0)]
        core.turnsBySession["s1"] = [turn(1, request: "first")]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()
        XCTAssertEqual(m.readyIndicator, .none, "first run: what was captured before counts as seen")

        // Claude is working on a new prompt in s1 (no Stop yet).
        let working = iso(Date().addingTimeInterval(-60))
        core.sessionsByProject["/a"] = [sessionSummary("s1", project: "/a", last: working, lastTurn: 2, status: "awaiting_response")]
        core.turnsBySession["s1"] = [turn(1, request: "first"), turn(2, status: "awaiting_response", preview: nil, request: "second")]
        await m.refreshNow()
        XCTAssertEqual(m.readyIndicator, .working(sessions: 1))

        // An old waiting prompt (interrupted, never stopped) is not "working".
        let stale = iso(Date().addingTimeInterval(-2 * 3600))
        core.sessionsByProject["/a"] = [sessionSummary("s1", project: "/a", last: stale, lastTurn: 2, status: "awaiting_response")]
        await m.refreshNow()
        XCTAssertEqual(m.readyIndicator, .none)

        // Two sessions finish: one indicator, two sessions, not "success".
        let a1 = iso(Date().addingTimeInterval(-30)), a2 = iso(Date().addingTimeInterval(-10))
        core.sessionsByProject["/a"] = [sessionSummary("s1", project: "/a", last: a1, lastTurn: 2),
                                        sessionSummary("s2", project: "/a", last: a2)]
        core.turnsBySession["s1"] = [turn(1, request: "first"), turn(2, request: "second", at: a1)]
        core.turnsBySession["s2"] = [turn(1, request: "other", at: a2)]
        await m.refreshNow()
        guard case .ready(let n, let automated, let background) = m.readyIndicator else { return XCTFail("ready: \(m.readyIndicator)") }
        XCTAssertEqual(n, 2); XCTAssertFalse(automated); XCTAssertFalse(background)
        XCTAssertFalse(ReadyIndicatorView.label(m.readyIndicator).lowercased().contains("success"))
        XCTAssertFalse(ReadyIndicatorView.label(m.readyIndicator).lowercased().contains("done"))

        // Opening the island: seen.
        await m.revealReadyAnswer()
        XCTAssertEqual(m.readyIndicator, .ready(sessions: 1, automated: false, backgroundPending: false),
                       "opening s2 leaves s1 unread")
        XCTAssertEqual(m.selectedSessionKey, "s2", "the newest answer's session is opened")
        await m.revealReadyAnswer()
        XCTAssertEqual(m.selectedSessionKey, "s1")
        XCTAssertEqual(m.readyIndicator, .none)
    }

    func testReadyIndicatorMarksATurnClaudeCodeStartedItself() async throws {
        let t0 = iso(Date().addingTimeInterval(-3600))
        let core = FakeCore(projects: [project("/a", sessions: 1, last: t0)])
        core.sessionsByProject["/a"] = [sessionSummary("s1", project: "/a", last: t0)]
        core.turnsBySession["s1"] = [turn(1, request: "first")]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()
        let at = iso(Date().addingTimeInterval(-5))
        var auto = Phase8Fixture.turnJSON(2, detail: false)
        auto["request_origin"] = "automated"
        (auto["final_response"] as? [String: Any]).map { var r = $0; r["received_at"] = at; auto["final_response"] = r }
        let automatedTurn = try JSONDecoder().decode(Turn.self, from: JSONSerialization.data(withJSONObject: auto))
        core.sessionsByProject["/a"] = [sessionSummary("s1", project: "/a", last: at, lastTurn: 2)]
        core.turnsBySession["s1"] = [turn(1, request: "first"), automatedTurn]
        await m.refreshNow()
        let deadline = Date().addingTimeInterval(2)
        while m.turns.value?.count != 2, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(m.readyIndicator, .ready(sessions: 1, automated: true, backgroundPending: false),
                       "an automated turn is not shown as your new finished task")
        XCTAssertTrue(ReadyIndicatorView.label(m.readyIndicator).contains("started itself"))
    }

    // MARK: Info buttons

    /// Every ⓘ answers what / source / checked here / not known, and none
    /// calls files verified when they were only seen in tool events.
    func testEveryInfoExplanationHasTheFourParts() async throws {
        let m = await model()
        let rows = HandoffContentsCard.rows(model: m)
        XCTAssertEqual(rows.map(\.title), ["Request & answer", "Commands", "Files changed", "Git status", "Attachments"])
        for row in rows {
            for (label, text) in row.explanation.lines {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(row.title): \(label)")
            }
        }
        let files = try XCTUnwrap(rows.first { $0.title == "Files changed" }).explanation
        XCTAssertTrue(files.checked.contains("not opened"), "edited files are not called checked")
        XCTAssertFalse((files.what + files.checked).lowercased().contains("verified"))
    }

    // MARK: Preview: Formatted and Markdown Source

    static func longPack(_ characters: Int) -> String {
        var text = "# Copy with Context\n\n## Session\n\n- Project: a\n\n## Claude final response\n\n"
        var i = 0
        while text.count < characters {
            i += 1
            text += "### Part \(i)\n\nParagraph \(i) with **bold**, `code` and a [link](https://example.com).\n\n| a | b |\n|---|---|\n| \(i) | x |\n\n```swift\nlet x = \(i)\n```\n\n"
        }
        return text + "## Not checked\n\n- end\n"
    }

    /// Both views read one snapshot; Sections jump to the same heading.
    func testFormattedJumpFindsTheSameHeadingAsTheSource() {
        let text = "## A\n\nx\n\n```\n## not a heading\n```\n\n## B\n\ny\n\n## A\n\nz\n"
        let blocks = Markdown.blocks(text)
        let sections = PackSection.sections(in: text)
        XCTAssertEqual(sections.map(\.title), ["A", "B", "A"])
        let indices = sections.compactMap { FormattedPackView.blockIndex(of: $0.offset, in: text, blocks: blocks) }
        XCTAssertEqual(indices.count, 3)
        for (section, index) in zip(sections, indices) {
            XCTAssertEqual(blocks[index], .heading(level: 2, text: section.title))
        }
        XCTAssertNotEqual(indices[0], indices[2], "the second “A” is the second heading, not the first")
    }

    /// 10 000 to 300 000 characters: parsed and laid out in a bounded,
    /// scrolling area without building every row (LazyVStack).
    func testFormattedPreviewOfLongPackagesStaysFast() {
        for n in [10_000, 30_000, 100_000, 300_000] {
            let text = Self.longPack(n)
            let started = Date()
            let host = NSHostingView(rootView: FormattedPackView(text: text, jump: nil).frame(width: 560, height: 360))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 2.5, "\(n) characters: \(elapsed) s")
            XCTAssertEqual(host.fittingSize.height <= 360 || host.frame.height == 360, true, "bounded")
            print(String(format: "P8-PREVIEW %d chars: %.0f ms to first layout", text.count, elapsed * 1000))
        }
    }

    // MARK: Renders (opt-in): PROMPT_RELAY_VISUALS=<dir>

    /// Relay (the real layer tree) looking toward nine pointer positions on a
    /// 1512 × 982 screen with Relay at the top, Phase 8 mapping vs the old one.
    func testRenderRelayPointerSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] else {
            throw XCTSkip("set PROMPT_RELAY_VISUALS=<dir> to write the Phase 8 renders")
        }
        let spots: [(String, CGFloat, CGFloat)] = [("menu bar, left", -500, -10), ("menu bar, near", 60, -5), ("menu bar, right", 600, -10),
                                                   ("mid, left", -500, 400), ("mid, below", 0, 400), ("mid, right", 600, 400),
                                                   ("bottom, left", -500, 900), ("bottom, below", 0, 900), ("bottom, right", 600, 900)]
        let tile = 150, cols = 9
        let w = tile * cols, h = tile * 2 + 40
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: w * 8,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (row, old) in [false, true].enumerated() {
            for (i, spot) in spots.enumerated() {
                let g = old ? CGPoint(x: tanh(spot.1 / 220), y: tanh(spot.2 / 160)) : NotchController.gaze(dx: spot.1, dy: spot.2)
                let state = MascotState()
                state.motion.place(gaze: g, head: g)
                let image = try XCTUnwrap(RelayRender.image(state, size: 110, resting: false, canvas: CGSize(width: 130, height: 130), scale: 2))
                ctx.draw(image, in: CGRect(x: i * tile + 10, y: h - (row + 1) * tile - 10, width: 130, height: 130))
            }
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        let labelled = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)]
            for (i, spot) in spots.enumerated() { (spot.0 as NSString).draw(at: NSPoint(x: i * tile + 12, y: 8), withAttributes: attrs) }
            ("Phase 8" as NSString).draw(at: NSPoint(x: 4, y: h - 16), withAttributes: attrs)
            ("before (7.2)" as NSString).draw(at: NSPoint(x: 4, y: h - tile - 16), withAttributes: attrs)
            return true
        }
        let out = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(labelled.tiffRepresentation)))
        try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/p8-relay-pointer-sheet.png"))
    }

    func testRenderPhase8States() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] else {
            throw XCTSkip("set PROMPT_RELAY_VISUALS=<dir> to write the Phase 8 renders")
        }
        let m = await model()
        for (name, maxContent) in [("details-448", CGFloat(448)), ("details-341", 341)] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            try island.png("\(dir)/p8-\(name).png")
            for (tip, prefix) in [("full", "Read the complete answer"), ("copy", Labels.copyAnswerHelp), ("history", "Browse previous")] {
                _ = try showTip(island, prefix)
                try island.png("\(dir)/p8-\(name)-tip-\(tip).png")
                island.tips.hideAll()
            }
            island.close()
        }
        m.route = .activity
        let activity = IslandHost(model: m, maxContentHeight: 448)
        try activity.png("\(dir)/p8-activity.png")
        if let (owner, c) = activity.tips.controls.first(where: { $0.value.text.isEmpty }) {
            activity.tips.show(owner, text: c.text, anchor: c.anchor)
            try activity.png("\(dir)/p8-activity-empty-tip.png")
        }
        activity.close()
        m.route = .home
        let peek = IslandHost(model: m, surface: .peek)
        try peek.png("\(dir)/p8-peek.png")
        _ = try showTip(peek, Labels.copyAnswerHelp)
        try peek.png("\(dir)/p8-peek-tip-copy.png")
        peek.close()
    }
}
