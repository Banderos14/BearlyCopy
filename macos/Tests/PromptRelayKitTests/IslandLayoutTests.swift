import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// The open island rendered for real (SwiftUI in an AppKit window) with a
/// long report: spacing against the island's visible outline, the Response
/// card's own scrolling, and the mascot's pose.
@MainActor
final class IslandLayoutTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.layout.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayLayout-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-layout-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    /// A model showing an imported long report (the same Home as a local one).
    func model(reports: [String] = [ReportFixture.report(sections: 12)]) async -> AppModel {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("sa", project: "/a", last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["sa"] = [turn(1, preview: "Ответ", chars: 5, request: "Задача")]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        await m.refreshNow()
        for text in reports {
            _ = m.importReport(text: text, task: "Сделай подробный отчёт о проделанной работе по островку и маскоту",
                               projectPath: "/a", sessionLabel: nil)
        }
        return m
    }

    // MARK: Spacing

    func testContentKeepsItsDistanceFromTheIslandOutline() async throws {
        let m = await model()
        // Phase 5 Details: 640 wide, at most 38 % of the display (341 pt of
        // content on a 14-inch MacBook, 448 on a large display).
        for maxContent: CGFloat in [448, 341] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            let metrics = IslandMetrics.of(island.presentation)
            let f = island.presentation.layoutFrames
            for id in ["card.task", "card.response", "home.actions", "card.handoff", "card.attachments", "details.header"] {
                let rect = try XCTUnwrap(f[id], "\(id) is laid out")
                XCTAssertGreaterThanOrEqual(rect.minX - metrics.edge, 20, "\(id): clear of the left side (\(maxContent))")
                XCTAssertGreaterThanOrEqual(island.width - metrics.edge - rect.maxX, 20, "\(id): clear of the right side")
                XCTAssertTrue(island.contains(rect.insetBy(dx: -8, dy: -8)), "\(id): 8 pt inside the rounded outline")
            }
            let footer = try XCTUnwrap(f["home.actions"])
            XCTAssertGreaterThanOrEqual(island.height - footer.maxY, 16, "the actions sit above the rounded bottom edge")
            XCTAssertLessThanOrEqual(island.height, 32 + maxContent, "Details fits the display without clipping")
            // Two columns side by side, none wider than the island allows.
            let left = try XCTUnwrap(f["card.response"]), right = try XCTUnwrap(f["card.handoff"])
            XCTAssertLessThan(left.maxX, right.minX, "the report left, the hand-off right")
            // With the line of copy feedback shown it still fits.
            await m.copySelectedResponse()
            island.settle()
            let withFeedback = try XCTUnwrap(island.presentation.layoutFrames["home.actions"])
            XCTAssertGreaterThanOrEqual(island.height - withFeedback.maxY, 16, "after a copy, the actions are not cut off (\(maxContent))")
            // One left edge for the band and the content below it.
            XCTAssertEqual(try XCTUnwrap(f["band.mascot"]).minX, try XCTUnwrap(f["card.task"]).minX, accuracy: 0.5)
            XCTAssertLessThanOrEqual(try XCTUnwrap(f["band.mascot"]).maxX, (island.width - 185) / 2 - 8,
                                     "Relay stays clear of the camera housing")
            // Blocks are separated by the shared spacing, nothing touches.
            let task = try XCTUnwrap(f["card.task"]), response = try XCTUnwrap(f["card.response"])
            XCTAssertEqual(response.minY - task.maxY, metrics.spacing, accuracy: 0.5)
            island.close()
        }
    }

    func testQuickPeekKeepsTheSameRules() async throws {
        let m = await model()
        let island = IslandHost(model: m, surface: .peek)
        let actions = try XCTUnwrap(island.presentation.layoutFrames["peek.actions"])
        XCTAssertTrue(island.contains(actions.insetBy(dx: -8, dy: -8)))
        XCTAssertGreaterThanOrEqual(actions.minX - IslandMetrics.of(island.presentation).edge, 20)
        XCTAssertLessThan(island.height, 32 + 300, "Quick Peek stays compact")
        island.close()
    }

    func testMetricsAdaptToTheDisplay() {
        let roomy = IslandMetrics.make(width: 480, maxContentHeight: 568, floating: false, peek: false)
        XCTAssertEqual(roomy.inset, 22)
        XCTAssertEqual(roomy.leading, 22 + NotchRootView.expandedTopRadius, "measured from the visible side, not the window")
        let short = IslandMetrics.make(width: 480, maxContentHeight: 380, floating: false, peek: false)
        XCTAssertLessThan(short.spacing + short.bottom, roomy.spacing + roomy.bottom, "short displays keep more text visible")
        XCTAssertEqual(IslandMetrics.make(width: 560, maxContentHeight: 568, floating: false, peek: false).inset, 24)
        XCTAssertEqual(IslandMetrics.make(width: 480, maxContentHeight: 568, floating: true, peek: false).edge, 0,
                       "the floating island has straight sides")
    }

    func addImages(_ m: AppModel, names: [String]) throws {
        let dir = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let colors: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .systemPink]
        let urls = try names.enumerated().map { i, name -> URL in
            let drawing = NSImage(size: NSSize(width: 1440, height: 900), flipped: false) { rect in
                colors[i % colors.count].setFill(); rect.fill()
                NSColor.white.setFill(); NSRect(x: 80, y: 80, width: 600, height: 300).fill()
                return true
            }
            let url = dir.appendingPathComponent(name)
            try NSBitmapImageRep(data: drawing.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        m.addAttachments(urls, to: try XCTUnwrap(m.currentRef))
    }

    func testSeveralImagesStayInsideTheAttachmentsCardAndDetailsStillFits() async throws {
        let m = await model()
        try addImages(m, names: ["Снимок экрана 2026-10-30 в 10.12.04.png", "island.png", "settings.png", "error.png"])
        XCTAssertEqual(m.attachments(for: m.currentRef).count, 4)
        for maxContent: CGFloat in [448, 341] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            let f = island.presentation.layoutFrames
            let row = try XCTUnwrap(f["card.attachments"], "the attachments card is shown")
            let footerTop = try XCTUnwrap(f["details.footer"]).minY
            XCTAssertLessThanOrEqual(row.maxY, footerTop - 4, "any number of files scrolls inside the card, above the footer")
            island.assertNoOverlap(["details.header", "card.task", "card.response", "card.handoff", "card.attachments", "details.footer"])
            await m.copySelectedResponse()
            island.settle()
            let footer = try XCTUnwrap(island.presentation.layoutFrames["home.actions"])
            XCTAssertTrue(island.contains(row.insetBy(dx: -8, dy: -8)))
            XCTAssertGreaterThanOrEqual(row.minX - IslandMetrics.of(island.presentation).edge, 20)
            XCTAssertGreaterThanOrEqual(island.height - footer.maxY, 16, "Home fits with the images and the copy line (\(maxContent))")
            XCTAssertLessThanOrEqual(island.height, 32 + maxContent)
            XCTAssertNotNil(f["response.scroll"], "the answer keeps its scroll area")
            island.close()
        }
    }

    /// Phase 5.11 (real e2e render): with step 2 open, the taller bar pushed
    /// the copy line out of the island; the columns now give it room.
    func testStepTwoBarAndCopyLineFitInsideDetails() async throws {
        let m = await model()
        try addImages(m, names: ["blue.png", "island.png", "settings.png"])
        for maxContent: CGFloat in [448, 341] {
            let island = IslandHost(model: m, maxContentHeight: maxContent)
            await m.copySelectedContext()
            XCTAssertNotNil(m.handoffStep)
            m.copyHandoffFiles()
            island.settle()
            let bar = try XCTUnwrap(island.presentation.layoutFrames["details.handoff"], "the step-2 bar is shown")
            XCTAssertTrue(island.contains(bar), "the step-2 bar is inside the island (\(maxContent))")
            XCTAssertGreaterThanOrEqual(island.height - bar.maxY, 16, "the step-2 footer sits above the rounded edge (\(maxContent))")
            island.assertNoOverlap(["details.header", "card.task", "card.response", "card.handoff", "card.attachments", "details.footer"])
            XCTAssertLessThanOrEqual(island.height, 32 + maxContent)
            m.endHandoff()
            island.close()
        }
    }

    // MARK: Response scrolling

    func testTheResponseScrollsInsideItsCardAndCopyAlwaysTakesTheWholeText() async throws {
        let long = ReportFixture.report(sections: 12)
        let other = "# Другой отчёт\n\n" + ReportFixture.section(99)
        let m = await model(reports: [other, long])
        let island = IslandHost(model: m)
        let scroll = try XCTUnwrap(island.responseScrollView(), "the answer has its own scroll view")
        XCTAssertNil(island.ancestorScrollView(of: scroll), "not nested in another vertical scroll: the wheel scrolls only the answer")
        let card = try XCTUnwrap(island.presentation.layoutFrames["response.scroll"])
        XCTAssertLessThanOrEqual(card.maxY, try XCTUnwrap(island.presentation.layoutFrames["response.full"]).minY,
                                 "View Full Report stays below the answer, never under it")
        island.assertNoOverlap(["details.header", "card.task", "card.response", "details.footer"])
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentView.bounds.height * 3, "a long report scrolls")
        XCTAssertNotNil(island.presentation.layoutFrames["response.full"], "View Full Report stays")

        let windowFrame = island.window.frame
        let start = scroll.contentView.bounds.origin.y
        island.scrollWheel(scroll, by: -240)
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(abs(scrolled - start), 100, "the wheel over the answer scrolls it")
        XCTAssertEqual(island.window.frame, windowFrame, "the island itself does not move or resize")
        XCTAssertEqual(m.route, .home)

        await m.copySelectedResponse()
        XCTAssertEqual(board.string(forType: .string).map { Data($0.utf8) }, Data(long.utf8),
                       "Copy Response copies the original, whatever is scrolled into view")

        // Another answer starts at its top.
        let otherID = try XCTUnwrap(m.imports.first { $0.text == other }?.id)
        m.open(.imported(id: otherID))
        island.settle()
        if let next = island.responseScrollView() {
            XCTAssertEqual(next.contentView.bounds.origin.y, start, accuracy: 1, "a different answer is shown from its top")
        }
        m.open(.imported(id: try XCTUnwrap(m.imports.first { $0.text == long }?.id)))
        island.settle()
        let again = try XCTUnwrap(island.responseScrollView())
        XCTAssertEqual(again.contentView.bounds.origin.y, start, accuracy: 1, "and so does the long one, opened again")
        island.close()
    }

    // MARK: Mascot

    func testRelaysPoseIsBoundedAndNeutralWithoutAPointer() {
        let neutral = MascotPose(gaze: .zero)
        XCTAssertEqual(neutral.tilt, 0)
        XCTAssertEqual(neutral.shift, .zero)
        let far = MascotPose(gaze: CGPoint(x: 40, y: -40))
        XCTAssertEqual(far.tilt, MascotPose.maxTilt, "the head tilts at most a few degrees")
        XCTAssertEqual(far.eyes, CGPoint(x: 1, y: -1))
        XCTAssertLessThanOrEqual(abs(far.shift.width), MascotPose.maxShift)
        XCTAssertLessThanOrEqual(abs(far.shift.height), MascotPose.maxShift)
        XCTAssertEqual(MascotPose(gaze: CGPoint(x: -0.5, y: 0)).tilt, -MascotPose.maxTilt / 2, "toward the pointer")
    }

    func testGazeIsMeasuredFromRelayInTheBand() {
        let p = NotchPresentation()
        p.notchSize = CGSize(width: 185, height: 32)
        p.islandWidth = NotchLayout.expandedWidth
        p.maxContentHeight = 568
        p.isExpanded = true
        p.surface = .expanded
        let height: CGFloat = 400
        let center = CGPoint(x: IslandMetrics.of(p).leading + MascotView.size(notchHeight: 32) / 2, y: height - 16)
        XCTAssertEqual(NotchController.gaze(toward: center, windowHeight: height, presentation: p), .zero)
        let right = NotchController.gaze(toward: CGPoint(x: center.x + 3000, y: center.y), windowHeight: height, presentation: p)
        XCTAssertEqual(right.x, 1, accuracy: 0.001, "far away (another display): settles at the edge")
        XCTAssertEqual(right.y, 0)
        let near = NotchController.gaze(toward: CGPoint(x: center.x + 40, y: center.y), windowHeight: height, presentation: p)
        XCTAssertEqual(near.x, tanh(40 / 220), accuracy: 0.001, "near the bear the eyes move most")
        let below = NotchController.gaze(toward: CGPoint(x: center.x, y: center.y - 160), windowHeight: height, presentation: p)
        XCTAssertEqual(below.y, tanh(1), accuracy: 0.01, "y grows downward")
        XCTAssertEqual(MascotView.size(notchHeight: 32), 28)
        XCTAssertEqual(MascotView.size(notchHeight: 38), 28)
        XCTAssertEqual(MascotView.size(notchHeight: 30), 26, "2 pt clear above and below on a shorter housing")
    }

    func testEveryMoodDrawsAtEverySize() throws {
        for size in [MascotView.size(notchHeight: 32), 96] {
            for mood in [MascotState.Mood.idle, .curious, .pleased, .concerned] {
                for (open, squint) in [(CGFloat(1), CGFloat(0)), (0, 0), (1, 1)] {
                    let rep = try MascotSheet.render(mood: mood, gaze: CGPoint(x: 0.6, y: -0.4), eyeOpen: open, squint: squint, size: size)
                    XCTAssertGreaterThan(MascotSheet.opaquePixels(rep), Int(size * size) / 3, "\(mood) at \(size) is drawn")
                }
            }
        }
    }

    func testPastedRequestsAreShownWithoutTheirWrapperButKeptVerbatim() {
        let raw = "\n\n<pasted_content id=\"f5a2\">\nPROMPT RELAY — UX-полировка\nСделай X\n</pasted_content id=\"f5a2\">\n"
        let shown = Wording.requestForDisplay(raw)
        XCTAssertTrue(shown.pasted)
        XCTAssertEqual(shown.text, "PROMPT RELAY — UX-полировка\nСделай X")
        XCTAssertEqual(AppModel.oneLine(raw), "PROMPT RELAY — UX-полировка", "History shows the first real line")
        let preview = "\n\n<pasted_content id=\"f5a2\">\nPROMPT RELAY — Улучше"   // a cut preview: no closing tag
        XCTAssertEqual(Wording.requestForDisplay(preview).text, "PROMPT RELAY — Улучше")
        XCTAssertEqual(Wording.requestForDisplay("Use <b>tags</b> as is").text, "Use <b>tags</b> as is")
        XCTAssertFalse(Wording.requestForDisplay("продолжи где остановился").pasted)
        XCTAssertEqual(Wording.requestForDisplay("<pasted_content id=\"x\"></pasted_content>").text,
                       "<pasted_content id=\"x\"></pasted_content>", "nothing else to show: the raw text")
    }

    // MARK: Review Pack

    func testTheResponseIsReadBackFromTheReviewPackExactly() {
        let text = "## Claude final response\n````\nnested ``` fence\n````\n```swift\nlet x = 1\n```\r\nend 🚀"
        let task = "Continue where you stopped\n## Claude final response\n```markdown\nnot the answer\n```"
        let report = ImportedReport(id: "i", importedAt: "t", text: text, task: task, projectPath: nil, projectName: nil,
                                    sessionLabel: nil, digest: "d")
        let pack = ReviewPack.render(imported: report, attachments: [], exportedAt: "t")
        XCTAssertEqual(ReviewPackReader.response(in: pack).map { Data($0.utf8) }, Data(text.utf8),
                       "the original bytes; headings and fences inside it or in the task do not confuse the reader")
        XCTAssertEqual(pack.components(separatedBy: text).count - 1, 1)
        XCTAssertNil(ReviewPackReader.response(in: "# no pack"))
    }

    // MARK: Visual examples (opt-in)

    /// PROMPT_RELAY_VISUALS=<dir> writes PNGs of the island and of Relay for review.
    func testWriteVisualExamples() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] else {
            throw XCTSkip("set PROMPT_RELAY_VISUALS=<dir> to write visual examples")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = await model()
        var island = IslandHost(model: m, mascot: true)
        try island.png("\(dir)/home-long-top.png")
        if let scroll = island.responseScrollView() { island.scrollWheel(scroll, by: -600) }
        try island.png("\(dir)/home-long-scrolled.png")
        island.close()
        island = IslandHost(model: m, maxContentHeight: 380, mascot: true)
        try island.png("\(dir)/home-short-display.png")
        island.close()
        try addImages(m, names: ["Снимок экрана 2026-10-30 в 10.12.04.png", "island.png", "settings.png"])
        island = IslandHost(model: m, mascot: true)
        try island.png("\(dir)/home-with-images.png")
        island.close()
        island = IslandHost(model: m, surface: .peek, mascot: true)
        try island.png("\(dir)/quick-peek.png")
        island.close()
        m.navigate(to: .reader)
        island = IslandHost(model: m, mascot: true)
        try island.png("\(dir)/full-report.png")
        island.close()
        m.route = .home

        // Resting beside the camera housing (marked grey), looking right.
        for (name, gaze) in [("resting-relay.png", CGPoint(x: 1, y: 0.4)), ("resting-relay-left.png", CGPoint(x: -1, y: 0.4))] {
            let p = NotchPresentation()
            p.notchSize = CGSize(width: 185, height: 32)
            p.showsMascot = true
            p.mascot.gaze = gaze
            let ear = NotchLayout.earWidth
            let size = NSSize(width: 185 + 2 * ear + 40, height: 44)
            let root = ZStack(alignment: .top) {
                Color(white: 0.85)
                NotchRootView(model: m, presentation: p, interaction: NotchInteraction(scheduler: MainQueueScheduler()),
                              actions: SurfaceActions(quit: {}))
                    .frame(width: 185 + 2 * ear, height: 32)
                Rectangle().stroke(Color.red, lineWidth: 1).frame(width: 185, height: 32)   // the camera housing
            }
            .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 4
            let image = try XCTUnwrap(renderer.nsImage)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }

        // Relay: each mood, a blink, the happy closed eyes, and the gaze.
        var tiles: [(String, NSBitmapImageRep)] = []
        for (name, mood) in [("idle", MascotState.Mood.idle), ("curious", .curious), ("pleased", .pleased), ("concerned", .concerned)] {
            tiles.append((name, try MascotSheet.render(mood: mood, gaze: .zero, eyeOpen: 1, squint: 0, size: 96, background: .black)))
        }
        tiles.append(("blink", try MascotSheet.render(mood: .idle, gaze: .zero, eyeOpen: 0, squint: 0, size: 96, background: .black)))
        tiles.append(("copied", try MascotSheet.render(mood: .pleased, gaze: .zero, eyeOpen: 1, squint: 1, size: 96, background: .black)))
        for (name, g) in [("look-left", CGPoint(x: -1, y: 0)), ("look-right", CGPoint(x: 1, y: 0.3)), ("look-down", CGPoint(x: 0.2, y: 1))] {
            tiles.append((name, try MascotSheet.render(mood: .idle, gaze: g, eyeOpen: 1, squint: 0, size: 96, background: .black)))
        }
        try MascotSheet.write(tiles, to: "\(dir)/relay-states.png")
    }
}

// MARK: - Helpers

/// The island in a borderless window, as the panel shows it.
@MainActor
final class IslandHost {
    let presentation = NotchPresentation()
    let window: NSWindow
    let host: NSView
    let width: CGFloat

    init(model: AppModel, surface: NotchPresentation.Surface = .expanded, maxContentHeight: CGFloat = 568, mascot: Bool = true) {
        width = surface == .peek ? NotchLayout.peekWidth : NotchLayout.expandedWidth
        presentation.notchSize = CGSize(width: 185, height: 32)
        presentation.islandWidth = width
        presentation.isExpanded = true
        presentation.surface = surface
        presentation.showsMascot = mascot
        presentation.maxContentHeight = maxContentHeight
        let size = NSSize(width: width, height: 32 + maxContentHeight)
        let settings = NotchSettings(defaults: UserDefaults(suiteName: "PromptRelayLayout-\(UUID().uuidString)")!)
        host = NSHostingView(rootView: NotchRootView(model: model, presentation: presentation,
                                                     interaction: NotchInteraction(scheduler: MainQueueScheduler()),
                                                     actions: SurfaceActions(quit: {}), settings: settings)
            .frame(width: size.width, height: size.height).background(Color(white: 0.86)))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        settle()
    }

    var height: CGFloat { presentation.notchSize.height + presentation.contentHeight }

    func settle() {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        }
    }

    func close() { window.close() }

    /// The blocks are laid out, inside the island, and none overlaps another
    /// (the Phase 5 defect: the footer drew over the Response).
    func assertNoOverlap(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        settle()
        let f = presentation.layoutFrames
        let rects = ids.compactMap { id in f[id].map { (id, $0) } }
        XCTAssertEqual(rects.count, ids.count, "laid out: \(ids.filter { f[$0] == nil })", file: file, line: line)
        for (id, r) in rects {
            XCTAssertTrue(contains(r.insetBy(dx: 1, dy: 1)), "\(id) \(r) inside the island (height \(height))", file: file, line: line)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].1.intersection(rects[j].1)
                XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                              "\(rects[i].0) \(rects[i].1) overlaps \(rects[j].0) \(rects[j].1)", file: file, line: line)
            }
        }
    }

    /// Whether every corner and edge midpoint of `rect` is inside the island outline.
    func contains(_ rect: CGRect) -> Bool {
        let outline = NotchShape(bottomRadius: 26, topRadius: NotchRootView.expandedTopRadius)
            .path(in: CGRect(x: 0, y: 0, width: width, height: height))
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                      CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]
        return points.allSatisfy { outline.contains($0) }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
    }

    /// The Response card's scroll view: the vertical one with the most content.
    func responseScrollView() -> NSScrollView? {
        scrollViews(in: host)
            .filter { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1 }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    func ancestorScrollView(of view: NSView) -> NSScrollView? {
        var v = view.superview
        while let current = v {
            if let scroll = current as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 1 {
                return scroll
            }
            v = current.superview
        }
        return nil
    }

    /// A real scroll-wheel event (pixels; negative scrolls down) to `scroll`.
    func scrollWheel(_ scroll: NSScrollView, by delta: Int32) {
        for _ in 0..<4 {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta / 4, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            scroll.scrollWheel(with: event)
        }
        settle()
    }

    func png(_ path: String) throws {
        settle()
        let rect = NSRect(x: 0, y: host.bounds.height - height, width: width, height: height)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let full = NSImage(size: host.bounds.size)
        full.addRepresentation(rep)
        let cropped = NSImage(size: rect.size, flipped: false) { _ in
            full.draw(in: NSRect(origin: .zero, size: rect.size), from: rect, operation: .copy, fraction: 1)
            return true
        }
        let out = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(cropped.tiffRepresentation)))
        try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

/// Relay drawn on its own, for checks and the visual examples.
@MainActor
enum MascotSheet {
    static func render(mood: MascotState.Mood, gaze: CGPoint, eyeOpen: CGFloat, squint: CGFloat, size: CGFloat,
                       background: Color = .clear) throws -> NSBitmapImageRep {
        let face = MascotFace(gazeX: gaze.x, gazeY: gaze.y, eyeOpen: eyeOpen, squint: squint, mood: mood)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(MascotPose(gaze: gaze).tilt), anchor: .bottom)
            .padding(4)
            .background(background)
        let renderer = ImageRenderer(content: face)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    }

    static func opaquePixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { n += 4 }
        }
        return n / 4
    }

    static func write(_ tiles: [(String, NSBitmapImageRep)], to path: String) throws {
        let tile: CGFloat = 120
        let size = NSSize(width: tile * CGFloat(tiles.count), height: tile + 24)
        let sheet = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            for (i, (name, rep)) in tiles.enumerated() {
                rep.draw(in: NSRect(x: CGFloat(i) * tile + 12, y: 30, width: 96, height: 96))
                (name as NSString).draw(at: NSPoint(x: CGFloat(i) * tile + 12, y: 8),
                                        withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12)])
            }
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sheet.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
