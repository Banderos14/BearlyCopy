import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 7.1: persistent hand-off with its character count, one Relay per
/// screen across running copies, Capture Health, Living Relay, import.
@MainActor
final class Phase71Tests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p71.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP71-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p71-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func makeModel() async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root.appendingPathComponent("store")))
        await m.refreshNow()
        return m
    }

    @discardableResult
    func importReport(_ m: AppModel, _ text: String, files: [String]) throws -> ReportRef {
        _ = m.importReport(text: text, task: "Задача \(text.prefix(8))", projectPath: "/a", sessionLabel: nil)
        let ref = try XCTUnwrap(m.currentRef)
        let dir = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data("# \(name)\n".utf8).write(to: dir.appendingPathComponent(name))
            try XCTUnwrap(m.reportStore).addFile(from: dir.appendingPathComponent(name), to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        return ref
    }

    // MARK: Persistent hand-off

    /// Copy with Context → switch answer → back: the step is there again,
    /// with the count of the very text the clipboard holds; another answer
    /// never shows the first one's files or count. A restart keeps it.
    func testHandOffSurvivesSwitchingAnswersAndARestart() async throws {
        let m = await makeModel()
        let long = String(repeating: "Длинный ответ 🚀 с `кодом`.\n", count: 3_000)
        let a = try importReport(m, long, files: ["a1.md", "a2.md", "a3.md"])
        let b = try importReport(m, "Короткий", files: [])
        m.open(a)
        await m.copySelectedContext()
        let step = try XCTUnwrap(m.activeHandoff)
        let copied = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(step.text, copied, "the snapshot is what is on the clipboard")
        XCTAssertEqual(step.characters, CharacterCount.of(copied), "the count is of the copied text")
        XCTAssertGreaterThan(step.characters, 80_000)
        XCTAssertEqual(DetailsHandoffText.status(step), "Text copied · \(step.characters.formatted()) characters · Now 3 files")
        XCTAssertEqual(DetailsHandoffText.compact(step), "\(step.characters.formatted()) chars copied · 3 files next")

        m.open(b)
        XCTAssertNil(m.activeHandoff, "another answer shows none of A's files or count")
        m.suspendHandoffs()
        m.open(a)
        let back = try XCTUnwrap(m.activeHandoff, "back on A: restored")
        XCTAssertTrue(back.resumed)
        XCTAssertTrue(DetailsHandoffText.status(back).hasPrefix("Continue Transfer · 3 Files"))

        let restarted = AppModel(core: FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-31T10:00:00.000000Z")]),
                                 clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                                 reportStore: ReportStore(root: root.appendingPathComponent("store")))
        await restarted.refreshNow()
        restarted.open(a)
        XCTAssertEqual(restarted.activeHandoff?.text, copied, "kept across a restart")
        restarted.copyHandoffFiles()
        XCTAssertEqual(((board.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []).map(\.lastPathComponent), ["a1.md", "a2.md", "a3.md"])
        restarted.endHandoff()
        XCTAssertNil(restarted.activeHandoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store/handoffs.json").path))
    }

    /// The widest step 2 (Continue Transfer + Copy Text Again + 3 files +
    /// Done) stays inside Quick Peek and Details on short displays.
    func testWidestStepTwoFitsQuickPeekAndDetails() async throws {
        let m = await makeModel()
        let a = try importReport(m, String(repeating: "Ответ. ", count: 400), files: ["a.md", "b.md", "c.md"])
        m.open(a)
        await m.copySelectedContext()
        m.suspendHandoffs()
        for surface in [NotchPresentation.Surface.peek, .expanded] {
            for maxContent: CGFloat in [268, 448] {
                let host = IslandHost(model: m, surface: surface, maxContentHeight: maxContent)
                defer { host.close() }
                let id = surface == .peek ? "peek.handoff" : "details.handoff"
                let f = try XCTUnwrap(host.presentation.layoutFrames[id], "\(surface) \(maxContent)")
                XCTAssertGreaterThanOrEqual(f.minX, 8); XCTAssertLessThanOrEqual(f.maxX, host.width - 8, "\(surface) \(maxContent): \(f)")
                XCTAssertLessThanOrEqual(f.maxY, host.height, "inside the island: \(surface) \(maxContent) \(f) \(host.presentation.layoutFrames.filter { $0.key.hasPrefix("peek") || $0.key.hasPrefix("handoff") })")
                let status = try XCTUnwrap(host.presentation.layoutFrames["handoff.status"])
                XCTAssertTrue(f.insetBy(dx: -1, dy: -1).contains(status), "the count never spills out of step 2")
            }
        }
    }

    func testReplacedClipboardOffersTheSameTextAgain() async throws {
        let m = await makeModel()
        let a = try importReport(m, "Ответ", files: ["a.md"])
        m.open(a)
        await m.copySelectedContext()
        let text = try XCTUnwrap(m.activeHandoff?.text)
        XCTAssertFalse(m.handoffTextReplaced)
        board.clearContents(); board.setString("something else", forType: .string)
        m.islandOpened()
        XCTAssertTrue(m.handoffTextReplaced, "the user copied something else meanwhile")
        m.copyHandoffTextAgain()
        XCTAssertEqual(board.string(forType: .string), text, "the same snapshot, not rebuilt")
        XCTAssertFalse(m.handoffTextReplaced)
        XCTAssertEqual(m.copyFeedback, .copied(.context, characters: CharacterCount.of(text)))
    }

    func testRestartDropsAHandOffWhoseFilesAreGone() async throws {
        let m = await makeModel()
        let a = try importReport(m, "Ответ", files: ["a.md"])
        m.open(a)
        await m.copySelectedContext()
        let file = try XCTUnwrap(m.attachments(for: a).first.flatMap(m.attachmentURL))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(AppModel.loadHandoffs(try XCTUnwrap(m.reportStore)).isEmpty)
    }

    // MARK: One Relay

    func testOnlyTheNewestCopyOfABuildKeepsTheNotch() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        let debugOld = AppBuild.Copy(pid: 10, bundleID: AppBuild.debugBundleID, launched: t0)
        let debugNew = AppBuild.Copy(pid: 11, bundleID: AppBuild.debugBundleID, launched: t1)
        let release = AppBuild.Copy(pid: 12, bundleID: AppBuild.releaseBundleID, launched: t1)
        let all = [debugOld, debugNew, release, AppBuild.Copy(pid: 13, bundleID: "fr.louisraille.Coucou", launched: t1)]
        XCTAssertEqual(AppBuild.yields(own: debugOld, to: all), [debugNew], "the older Debug run steps aside")
        XCTAssertEqual(AppBuild.yields(own: debugNew, to: all), [], "the newest Debug run keeps the notch")
        XCTAssertEqual(AppBuild.yields(own: release, to: all), [debugOld, debugNew], "Release yields to Debug")
        let sameTime = AppBuild.Copy(pid: 20, bundleID: AppBuild.debugBundleID, launched: t0)
        XCTAssertEqual(AppBuild.yields(own: debugOld, to: [sameTime]), [sameTime], "ties: the higher PID")
    }

    func testCaptureHealthTellsTheCasesApart() throws {
        let none = try JSONDecoder().decode(ObservedCounts.self, from: Data(#"{"tool_events":0,"runs_exit_zero":0,"runs_nonzero":0,"runs_unknown":0,"files_changed":0,"background_started":0}"#.utf8))
        XCTAssertEqual(CaptureHealthRows.commandsHealth(captureOn: true, observed: none, imported: false).text, "recorded; this turn ran no tools")
        XCTAssertEqual(CaptureHealthRows.commandsHealth(captureOn: false, observed: nil, imported: false).text, "capture is off for this project")
        XCTAssertTrue(CaptureHealthRows.commandsHealth(captureOn: true, observed: nil, imported: false).text.hasPrefix("not recorded"))
    }
}

@MainActor
final class TooltipWidthTests: XCTestCase {
    func measure(_ text: String) -> CGSize {
        let tips = IslandTooltips()
        let host = NSHostingView(rootView: IslandTooltipOverlay(tips: tips, size: CGSize(width: 640, height: 400))
            .environment(\.islandFrameSink, { id, r in if id == "tooltip" { TooltipWidthTests.last = r } }))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        tips.show(UUID(), text: text, anchor: CGRect(x: 300, y: 100, width: 26, height: 26))
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return TooltipWidthTests.last.size
    }
    nonisolated(unsafe) static var last = CGRect.zero

    /// Fits its text; long text wraps inside the maximum, never truncated.
    func testTipIsAsWideAsItsTextAndWrapsAtTheMaximum() {
        let short = measure("Back (Esc)")
        XCTAssertLessThan(short.width, 90, "short tip hugs its text")
        let long = measure(Labels.copyWithContextHelp)
        XCTAssertLessThanOrEqual(long.width, IslandTooltipOverlay.maxWidth + 0.5)
        XCTAssertGreaterThan(long.height, short.height * 2.5, "long text wraps onto several lines")
    }
}

// MARK: - Living Relay

@MainActor
final class LivingRelayTests: XCTestCase {
    /// The idle machine: beats only after quiet, one timer at a time, back
    /// to Idle after each; the pointer and events win at once; sleepy after
    /// a long quiet time, woken by activity.
    func testIdleBeatsYieldToTheUserAndSleepAfterQuiet() {
        let scheduler = ManualScheduler()
        var rolls = [0.1, 0.2, 0.9]   // gap, choice (glance), side; then 0.5
        let life = RelayLife(scheduler: scheduler, now: { scheduler.now }, random: { rolls.isEmpty ? 0.5 : rolls.removeFirst() })
        var poses: [RelayLife.Pose] = []
        life.apply = { poses.append($0) }
        life.start()
        XCTAssertEqual(scheduler.liveTimers, 1, "one timer, nothing else running")
        scheduler.advance(40)
        XCTAssertEqual(life.phase, .glance, "a glance to one side")
        XCTAssertNotEqual(poses.last?.look, .zero)
        life.activity()
        XCTAssertEqual(life.phase, .idle, "the pointer wins at once")
        XCTAssertEqual(poses.last, RelayLife.Pose(), "back to neutral")
        XCTAssertEqual(scheduler.liveTimers, 1)
        // Quiet for 5 minutes: sleepy, and it stays until activity.
        for _ in 0..<80 where life.phase != .sleepy { scheduler.advance(5) }
        XCTAssertGreaterThanOrEqual(scheduler.now - 40, RelayLife.sleepAfter, "not before 5 quiet minutes")
        XCTAssertEqual(life.phase, .sleepy)
        XCTAssertEqual(poses.last?.expression, .sleepy)
        life.activity()
        XCTAssertEqual(life.phase, .idle, "activity wakes it")
        life.stop()
        XCTAssertEqual(scheduler.liveTimers, 0, "stopped: no timer left")
    }

    func testEveryBeatEndsInIdleWithoutOverlap() {
        let scheduler = ManualScheduler()
        for choice in [0.1, 0.5, 0.7, 0.95] {
            var rolls = [0.0, choice, 0.9]
            let life = RelayLife(scheduler: scheduler, now: { scheduler.now }, random: { rolls.isEmpty ? 0.0 : rolls.removeFirst() })
            life.start()
            scheduler.advance(34)
            XCTAssertNotEqual(life.phase, .idle, "choice \(choice) plays a beat")
            XCTAssertLessThanOrEqual(scheduler.liveTimers, 1, "never two timers")
            for _ in 0..<10 { scheduler.advance(0.5) }
            XCTAssertEqual(life.phase, .idle, "choice \(choice) returns to Idle")
            life.stop()
        }
    }

    /// Extreme poses at rest stay inside the ear (clear of the camera, the
    /// outline and the top of the screen), the 2.5D ear shift included.
    func testExtremePosesStayInsideTheEar() {
        for x in stride(from: -1.0, through: 1.0, by: 0.25) {
            for y in stride(from: -1.0, through: 1.0, by: 0.25) {
                for mood in [MascotState.Mood.idle, .curious, .pleased] {
                    let pose = RestingPose(head: CGPoint(x: x, y: y), mood: mood, lift: -RestingPose.hop)
                    let points = RestingPose.silhouette(dx: pose.dx, dy: pose.dy, turn: pose.turn, lift: 0,
                                                        earLift: mood == .curious ? 0.025 : 0)
                    for p in points {
                        XCTAssertTrue(RestingPose.safe.insetBy(dx: -0.01, dy: -0.01).contains(p), "\(x),\(y) \(mood): \(p)")
                    }
                    XCTAssertGreaterThan(pose.k, 0.3, "it still moves visibly")
                }
            }
        }
    }

    /// The 2.5D turn moves the layers by depth: nose more than eyes, eyes
    /// more than the outline, ears the other way; the far eye narrower.
    func testTurnParallaxIsLayered() {
        let t = MascotView.Turn(yaw: 1, pitch: 0)
        XCTAssertGreaterThan(t.layer(1.0), t.layer(0.7))
        XCTAssertGreaterThan(t.layer(0.7), t.outlineShift)
        XCTAssertLessThan(t.earShift(side: -1), 0, "ears move against the turn")
        XCTAssertLessThan(t.eyeWidth(side: 1), t.eyeWidth(side: -1), "the far eye is foreshortened")
        XCTAssertLessThan(t.earScale(side: 1), t.earScale(side: -1), "the far ear is smaller")
        let up = MascotView.Turn(yaw: 0, pitch: -1)
        XCTAssertLessThan(up.pitchShift(1), 0, "looking up raises the face")
        XCTAssertLessThan(up.muzzleSquash, 1)
        let neutral = MascotView.Turn(yaw: 0, pitch: 0)
        XCTAssertEqual(neutral.layer(1), 0); XCTAssertEqual(neutral.eyeWidth(side: 1), 1)
    }

    func testRelayMotionSettings() {
        let defaults = UserDefaults(suiteName: "PromptRelayTests.relay.\(UUID().uuidString)")!
        let s = NotchSettings(defaults: defaults)
        XCTAssertEqual(s.relayMotion, .subtle)
        XCTAssertTrue(s.relayIdle); XCTAssertTrue(s.relayFollowsPointer); XCTAssertTrue(s.relayWithoutNotch)
        XCTAssertEqual(NotchSettings.RelayMotion.off.amplitude, 0)
        XCTAssertLessThan(NotchSettings.RelayMotion.subtle.amplitude, NotchSettings.RelayMotion.expressive.amplitude)
        s.relayMotion = .off
        XCTAssertEqual(NotchSettings(defaults: defaults).relayMotion, .off, "remembered")
    }
}

/// Opt-in: PROMPT_RELAY_SNAPSHOT_DIR=<dir> renders Relay's poses (the real
/// drawing code, offscreen) for docs/images/phase71-relay/. Not a check of
/// motion on the live screen.
@MainActor
final class RelayPoseRenderTests: XCTestCase {
    func testRenderPoses() throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set PROMPT_RELAY_SNAPSHOT_DIR to render Relay's poses")
        }
        let poses: [(String, CGPoint, MascotState.Mood, MascotState.Expression, CGFloat)] = [
            ("neutral", .zero, .idle, .none, 0), ("left", CGPoint(x: -1, y: 0), .idle, .none, 0),
            ("right", CGPoint(x: 1, y: 0), .idle, .none, 0), ("up", CGPoint(x: 0, y: -1), .idle, .none, 0),
            ("down", CGPoint(x: 0, y: 1), .idle, .none, 0), ("up-right", CGPoint(x: 0.8, y: -0.8), .idle, .none, 0),
            ("down-left", CGPoint(x: -0.8, y: 0.8), .idle, .none, 0), ("curious", CGPoint(x: 0.3, y: -0.5), .curious, .none, 0),
            ("new answer", .zero, .curious, .none, 0), ("copied", .zero, .pleased, .none, 1),
            ("smile", .zero, .idle, .smile, 0), ("sleepy", CGPoint(x: 0, y: 0.55), .idle, .sleepy, 0),
            ("capture error", .zero, .concerned, .none, 0),
        ]
        let grid = VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<2) { row in
                HStack(spacing: 14) {
                    ForEach(Array(poses.enumerated()).filter { $0.offset / 7 == row }, id: \.offset) { _, p in
                        VStack(spacing: 4) {
                            MascotFace(gazeX: p.1.x, gazeY: p.1.y, eyeOpen: 1, squint: p.4, mood: p.2, yaw: p.1.x, pitch: p.1.y, expression: p.3)
                                .frame(width: 84, height: 84)
                                .rotationEffect(.degrees(p.2 == .curious && p.1 != .zero ? 7 : 0), anchor: .bottom)
                            Text(p.0).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }
        }
        .padding(16).background(Color.black)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("relay-poses.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
