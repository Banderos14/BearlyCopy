import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 7.2: Relay's frame-rate independent motion, full context only,
/// the Copy with Context header.
@MainActor
final class RelayMotionTests: XCTestCase {
    /// Positions at the same moment after the same input, sampled at `hz`.
    func trace(hz: Double, jitter: Bool = false, seconds: Double = 0.6, at times: [Double]) -> [CGPoint] {
        let m = RelayMotion()
        let t0: TimeInterval = 1_000
        m.look(at: CGPoint(x: 0.8, y: -0.4), now: t0)
        var t = t0, out: [CGPoint] = [], i = 0, next = times.map { t0 + $0 }
        while t < t0 + seconds {
            let base = 1 / hz
            t += jitter ? (i % 2 == 0 ? base * 0.55 : base * 1.45) : base
            i += 1
            // Sample exactly at the comparison times (an extra frame there).
            while let n = next.first, t >= n { out.append(m.frame(at: n).head); next.removeFirst() }
            _ = m.frame(at: t)
        }
        return out
    }

    /// ProMotion or not, Relay moves the same way in time.
    func testSpeedDoesNotDependOnTheRefreshRate() {
        let times = [0.1, 0.2, 0.35, 0.5]
        let at60 = trace(hz: 60, at: times), at120 = trace(hz: 120, at: times)
        for (a, b) in zip(at60, at120) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.04); XCTAssertEqual(a.y, b.y, accuracy: 0.04)
        }
    }

    /// Uneven frames (the jitter that made Coucou's step-debt clock freeze
    /// and jump) give the same motion: time-based sub-steps, not frame counts.
    func testUnevenFramesGiveTheSameMotion() {
        let times = [0.1, 0.2, 0.35, 0.5]
        for (a, b) in zip(trace(hz: 60, at: times), trace(hz: 60, jitter: true, at: times)) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.05)
        }
    }

    /// Eyes lead, the head trails with a little overshoot, the ears swing
    /// once against a fast turn; then everything settles and stops.
    func testEyesLeadHeadTrailsEarsSwingThenStill() {
        let m = RelayMotion()
        var t: TimeInterval = 500
        m.look(at: CGPoint(x: 1, y: 0), now: t)
        var maxHead: CGFloat = 0, minEar: CGFloat = 0, eyesFirst = false
        for _ in 0..<120 {
            t += 1 / 60
            let f = m.frame(at: t)
            if f.gaze.x > 0.5, f.head.x < 0.5 { eyesFirst = true }
            maxHead = max(maxHead, f.head.x); minEar = min(minEar, f.earLag)
        }
        XCTAssertTrue(eyesFirst, "the eyes get there before the head")
        XCTAssertGreaterThan(maxHead, 1.0, "a touch of overshoot")
        XCTAssertLessThan(maxHead, 1.08, "but only a touch")
        XCTAssertLessThan(minEar, -0.1, "the ears lag behind the turn")
        XCTAssertTrue(m.isSettled, "settled within two seconds")
        let f = m.frame(at: t + 1)
        XCTAssertEqual(f.head, CGPoint(x: 1, y: 0)); XCTAssertEqual(f.earLag, 0)
    }

    func testBlinkClosesFastOpensSoftlyAndEnds() {
        let m = RelayMotion()
        m.blink(now: 10)
        let closed = m.frame(at: 10.07).eyeOpen
        XCTAssertLessThan(closed, 0.1, "closed at 70 ms")
        XCTAssertGreaterThan(m.frame(at: 10.02).eyeOpen, 0.6, "eases in")
        XCTAssertGreaterThan(m.frame(at: 10.14).eyeOpen, 0.6, "opens with an ease-out")
        XCTAssertEqual(m.frame(at: 10.25).eyeOpen, 1)
        XCTAssertTrue(m.isSettled, "nothing to draw after the blink")
    }

    func testExpressionsBlendInsteadOfJumping() {
        let m = RelayMotion()
        m.setAmounts(RelayMotion.Amounts(smile: 1), now: 0)
        let early = m.frame(at: 0.05).amounts.smile, mid = m.frame(at: 0.2).amounts.smile
        XCTAssertGreaterThan(early, 0); XCTAssertLessThan(early, mid); XCTAssertLessThan(mid, 1)
        var t = 0.2
        while t < 2 { t += 1 / 60; _ = m.frame(at: t) }
        XCTAssertTrue(m.isSettled)
        XCTAssertEqual(m.amounts.smile, 1)
    }

    /// A long gap (sleep, hidden panel) is not replayed as one big jump.
    func testALongGapIsNotReplayed() {
        let m = RelayMotion()
        m.look(at: CGPoint(x: 1, y: 0), now: 0)
        let f = m.frame(at: 5)
        XCTAssertLessThan(f.head.x, 0.9, "at most 0.1 s of motion in one frame")
    }

    func testFrameIntervalAsksForSixtyFramesASecond() {
        XCTAssertLessThan(RelayMotion.frameInterval, 1 / 60, "a little short of 1/60 s, so 60 Hz frames are not skipped")
        XCTAssertGreaterThan(RelayMotion.frameInterval, 1 / 120, "on ProMotion: about 60, not 120")
    }
}

/// Opt-in: renders Relay's poses through the real layers (what the screen
/// shows) for docs/images/phase72-relay/. Not a check of live motion.
@MainActor
final class RelayLayerPoseRenderTests: XCTestCase {
    func testRenderPosesThroughLayers() throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set PROMPT_RELAY_SNAPSHOT_DIR to render Relay's poses")
        }
        let poses: [(CGPoint, MascotState.Mood, MascotState.Expression)] = [
            (.zero, .idle, .none), (CGPoint(x: -1, y: 0), .idle, .none), (CGPoint(x: 1, y: 0), .idle, .none),
            (CGPoint(x: 0, y: -1), .idle, .none), (CGPoint(x: 0, y: 1), .idle, .none), (CGPoint(x: 0.8, y: -0.8), .idle, .none),
            (CGPoint(x: -0.8, y: 0.8), .idle, .none), (CGPoint(x: 0.3, y: -0.5), .curious, .none), (.zero, .curious, .none),
            (.zero, .pleased, .none), (.zero, .idle, .smile), (CGPoint(x: 0, y: 0.55), .idle, .sleepy), (.zero, .concerned, .none),
        ]
        let cell: CGFloat = 96, scale: CGFloat = 2
        let w = Int(cell * 7 * scale), h = Int(cell * 2 * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, p) in poses.enumerated() {
            let state = MascotState()
            state.gaze = p.0; state.head = p.0; state.mood = p.1; state.expression = p.2
            state.motion.setAmounts(RelayMotion.Amounts(smile: p.2 == .smile ? 1 : 0, sleepy: p.2 == .sleepy ? 1 : 0, curious: p.2 == .curious ? 1 : 0), now: 0)
            _ = state.motion.frame(at: 0); for k in 1...200 { _ = state.motion.frame(at: Double(k) / 60) }
            state.gaze = p.0; state.head = p.0
            let image = try XCTUnwrap(RelayRender.image(state, size: 84, resting: false, canvas: CGSize(width: 84, height: 84), scale: scale))
            let col = i % 7, row = i / 7
            ctx.draw(image, in: CGRect(x: (CGFloat(col) * cell + 6) * scale, y: CGFloat(h) - (CGFloat(row + 1) * cell - 6) * scale,
                                       width: 84 * scale, height: 84 * scale))
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("relay-layers.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor
final class CopyWithContextHeaderTests: XCTestCase {
    /// The owner's screenshot: the title took three lines and "Preview"
    /// broke inside the word. Now one line each, at every width and height.
    func testTitleAndPreviewStayOnOneLine() async throws {
        let suite = "PromptRelayTests.p72h.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP72h-\(UUID().uuidString)"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p72h-\(UUID().uuidString)")
        defer { board.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: root) }
        let m = AppModel(core: FakeCore(projects: [project("/a", sessions: 0, last: nil)]), clipboard: ClipboardService(pasteboard: board),
                         dataDirectory: nil, stateDefaults: defaults, reportStore: ReportStore(root: root))
        await m.refreshNow()
        _ = m.importReport(text: ReportFixture.report(sections: 8), task: "Задача", projectPath: "/a", sessionLabel: nil)
        for maxContent: CGFloat in [341, 448] {
            let host = IslandHost(model: m, maxContentHeight: maxContent)
            defer { host.close() }
            let title = try XCTUnwrap(host.presentation.layoutFrames["handoff.title"], "\(maxContent)")
            let preview = try XCTUnwrap(host.presentation.layoutFrames["handoff.preview"])
            let card = try XCTUnwrap(host.presentation.layoutFrames["card.handoff"])
            XCTAssertLessThan(title.height, 16, "the title is one line (\(title))")
            XCTAssertLessThanOrEqual(preview.height, 20, "Preview is one line or the eye (\(preview))")
            XCTAssertFalse(title.intersects(preview), "no overlap")
            XCTAssertLessThanOrEqual(preview.maxX, card.maxX + 0.5, "inside the card")
            XCTAssertNil(host.presentation.layoutFrames["handoff.detail"], "no Standard / Full control")
        }
    }
}

/// Opt-in (PROMPT_RELAY_AUDIT_DIR): the island's surfaces as the real
/// views in an offscreen window, for a visual audit. Not the live panel.
@MainActor
final class SurfaceAuditRenderTests: XCTestCase {
    func testRenderSurfacesForAudit() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_AUDIT_DIR"] else {
            throw XCTSkip("set PROMPT_RELAY_AUDIT_DIR to render the surfaces")
        }
        let suite = "PromptRelayTests.p72a.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP72a-\(UUID().uuidString)"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-p72a-\(UUID().uuidString)")
        defer { board.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: root) }
        let m = AppModel(core: FakeCore(projects: [project("/a", sessions: 0, last: nil)]), clipboard: ClipboardService(pasteboard: board),
                         dataDirectory: nil, stateDefaults: defaults, reportStore: ReportStore(root: root))
        await m.refreshNow()
        _ = m.importReport(text: ReportFixture.report(sections: 8), task: String(repeating: "Длинная задача с подробностями. ", count: 12),
                           projectPath: "/a", sessionLabel: "ChatGPT", assistant: .chatGPT)
        let ref = try XCTUnwrap(m.currentRef)
        let src = root.appendingPathComponent("src"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for name in ["plan.md", "notes.txt", "shot.png"] {
            try (name.hasSuffix(".png") ? Phase6Tests.png(seed: 4) : Data("# \(name)\n".utf8)).write(to: src.appendingPathComponent(name))
            try XCTUnwrap(m.reportStore).addFile(from: src.appendingPathComponent(name), to: ref, source: .you, displayPath: name)
        }
        m.attachmentsVersion += 1
        func shot(_ name: String, surface: NotchPresentation.Surface = .expanded, maxContent: CGFloat = 341) throws {
            let host = IslandHost(model: m, surface: surface, maxContentHeight: maxContent)
            defer { host.close() }
            let view = host.host
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        m.route = .home; try shot("details-341"); try shot("details-448", maxContent: 448); try shot("details-268", maxContent: 268)
        try shot("peek", surface: .peek)
        await m.copySelectedContext(); m.suspendHandoffs()
        try shot("details-handoff"); try shot("peek-handoff", surface: .peek)
        m.endHandoff()
        for route in [AppModel.IslandRoute.taskReader, .reader, .evidence, .importReport, .settings, .history, .clipboard] {
            m.route = route; try shot("route-\(route.rawValue)")
        }
        await m.openPackPreview(); try shot("route-packagePreview")
    }
}
