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
