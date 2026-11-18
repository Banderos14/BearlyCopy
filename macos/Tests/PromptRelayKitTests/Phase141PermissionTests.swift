import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Phase 14.1: one-click recovery from "Auto screenshot needs permission".
///
/// Three things must never be true: (1) opening System Settings is read as
/// granted access by itself; (2) a denied/still-denied check ever loops into
/// a repeated system request (there is none — only the non-prompting
/// preflight call and a real capture, neither of which ever shows a dialog
/// more than macOS's own, user-initiated System Settings does); (3) a window
/// that is simply gone is ever reported as a permission problem.
@MainActor
final class Phase141PermissionTests: XCTestCase {
    var suite: String!
    var defaults: MemorySettingsStore!
    var board: NSPasteboard!
    var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "PromptRelayTests.p141.\(UUID().uuidString)"
        defaults = TestDefaults.named(suite)
        board = NSPasteboard(name: NSPasteboard.Name("PromptRelayP141-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pr141-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        board.releaseGlobally()
        removeTestDefaults(suite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Status: compact text, correct recovery per case

    func testStatusTextIsShortAndEachCaseOffersExactlyOneRecoveryKind() {
        for status: AutoCaptureStatus in [.pending, .captured, .permissionRequired, .restartRequired, .windowNotBound,
                                          .windowUnavailable, .failed, .associationRequired, .superseded] {
            if let title = status.title { XCTAssertLessThan(title.count, 40, "\(status): a compact title, not a paragraph") }
            if let detail = status.detail { XCTAssertLessThan(detail.count, 140, "\(status): one short sentence, not a how-to paragraph") }
            let recoveries = [status.offersPermissionRecovery, status.offersRestartRecovery, status.offersLink]
            XCTAssertLessThanOrEqual(recoveries.filter { $0 }.count, 1, "\(status): at most one recovery button group")
        }
        XCTAssertTrue(AutoCaptureStatus.permissionRequired.offersPermissionRecovery)
        XCTAssertTrue(AutoCaptureStatus.restartRequired.offersRestartRecovery)
        XCTAssertFalse(AutoCaptureStatus.permissionRequired.offersLink, "Permission required shows Open Settings, not Link Window…")
        XCTAssertFalse(AutoCaptureStatus.restartRequired.offersLink)
        XCTAssertTrue(AutoCaptureStatus.permissionRequired.offersRecheck)
        XCTAssertTrue(AutoCaptureStatus.restartRequired.offersRecheck)
    }

    // MARK: Fakes

    final class FakePermission: ScreenRecordingPermissionChecking {
        var granted = false
        var opens = 0
        var openResult = true
        func isGranted() -> Bool { granted }
        @discardableResult
        func openSettings() -> Bool { opens += 1; return openResult }
    }

    @MainActor final class FakeCapture: WindowCapturing {
        var pickResult: Result<PickedWindow, Error>? = .success(PickedWindow(handle: "h1", label: "w"))
        var captureResult: Result<WindowCapture.Shot, Error> = .success(.init(png: Phase14CaptureTests.png(.systemBlue), label: "w"))
        var captures = 0
        var forgotten: [String] = []
        func captureWindow(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>?) -> Void) { completion(nil) }
        func pickWindow(completion: @escaping @MainActor (Result<PickedWindow, Error>?) -> Void) { completion(pickResult) }
        func capture(_ window: PickedWindow) async throws -> WindowCapture.Shot { captures += 1; return try captureResult.get() }
        func forget(_ window: PickedWindow) { forgotten.append(window.handle) }
        /// Phase 15.2: what macOS says about the window (unknown keeps the link).
        var windowPresence: WindowPresence = .unknown
        func presence(of window: PickedWindow) -> WindowPresence { windowPresence }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func ago(_ s: TimeInterval) -> String { iso.string(from: Date(timeIntervalSinceNow: -s)) }

    func model() async -> (AppModel, FakePermission, FakeCapture) {
        let core = FakeCore(projects: [project("/a", sessions: 1, last: Self.ago(400))])
        core.sessionsByProject["/a"] = [Phase93Tests.session("s", provider: "claude_code", host: "claude_desktop", project: "/a",
                                                             last: Self.ago(400))]
        core.turnsBySession["s"] = [turn(1, preview: "answer", chars: 6, at: Self.ago(400))]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults,
                         reportStore: ReportStore(root: root))
        let permission = FakePermission()
        let capture = FakeCapture()
        m.screenRecordingPermission = permission
        m.windowCapture = capture
        // Fixed wall-clock timestamps would always be "before the feature was
        // armed" (armedAt defaults to the real now); keep both real-time-relative.
        m.captureNow = { Date().addingTimeInterval(-200) }
        await m.refreshNow()
        m.autoCaptureFinalWindow = true
        return (m, permission, capture)
    }

    // MARK: Opening Settings never means granted

    func testOpeningSettingsNeverChangesTheStatusByItself() async throws {
        let (m, permission, _) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.autoCaptureStatuses[ref.key] = .permissionRequired
        permission.granted = false
        XCTAssertTrue(m.openScreenRecordingSettings())
        XCTAssertEqual(permission.opens, 1)
        XCTAssertEqual(m.autoCaptureStatus(for: ref), .permissionRequired, "opening Settings is not read as granted")
    }

    // MARK: Check Again — denied, and repeated denial never loops

    func testCheckAgainWithAccessStillDeniedStaysPermissionRequiredAndNeverLoops() async throws {
        let (m, permission, capture) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.chooseAutoCaptureWindow()
        m.autoCaptureStatuses[ref.key] = .permissionRequired
        permission.granted = false
        capture.captureResult = .failure(WindowCaptureError.permissionDenied)
        for _ in 0..<3 {
            let result = await m.checkAutoCaptureAccess(for: ref)
            XCTAssertEqual(result, .permissionRequired)
            XCTAssertEqual(m.autoCaptureStatus(for: ref), .permissionRequired)
        }
        XCTAssertEqual(capture.captures, 3, "the real capture decides, once per check")
    }

    /// A window picked in macOS's own picker is captured with its per-window
    /// consent: the system-wide "not granted" reading alone never blocks.
    func testCheckAgainSucceedsWhenTheCaptureWorksEvenIfThePreflightSaysNo() async throws {
        let (m, permission, _) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.chooseAutoCaptureWindow()
        m.autoCaptureStatuses[ref.key] = .permissionRequired
        permission.granted = false
        let result = await m.checkAutoCaptureAccess(for: ref)
        XCTAssertNil(result)
        XCTAssertNil(m.autoCaptureStatus(for: ref))
        XCTAssertNotEqual(m.dailyUse.state, .permissionRequired)
    }

    // MARK: Check Again — granted, capture confirms it

    func testCheckAgainWithGrantedAccessAndWorkingCaptureClearsTheStatus() async throws {
        let (m, permission, capture) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.chooseAutoCaptureWindow()                       // links h1 via the fake picker
        m.autoCaptureStatuses[ref.key] = .permissionRequired
        permission.granted = true
        capture.captureResult = .success(.init(png: Phase14CaptureTests.png(.systemGreen), label: "w"))
        let result = await m.checkAutoCaptureAccess(for: ref)
        XCTAssertNil(result)
        XCTAssertNil(m.autoCaptureStatus(for: ref))
        XCTAssertEqual(capture.captures, 1, "the real operation auto-capture depends on is exercised, not just the API")
        // The probe capture is never attached to the report as an attachment.
        XCTAssertTrue(m.attachments(for: ref).isEmpty)
    }

    // MARK: Check Again — API says granted, capture still fails: restart

    func testApiGrantedButCaptureStillDeniedMeansRestartRequired() async throws {
        let (m, permission, capture) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.chooseAutoCaptureWindow()
        permission.granted = true
        capture.captureResult = .failure(WindowCaptureError.permissionDenied)
        let result = await m.checkAutoCaptureAccess(for: ref)
        XCTAssertEqual(result, .restartRequired)
        XCTAssertEqual(m.autoCaptureStatus(for: ref), .restartRequired)
        // The link itself is not dropped: the window is fine, the process
        // just has not picked the grant up yet.
        XCTAssertEqual(m.autoCaptureBindings.count, 1)
    }

    // MARK: An unavailable window is never reported as a permission issue

    func testAnUnavailableWindowIsNeverMaskedAsAPermissionError() async throws {
        let (m, permission, capture) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.chooseAutoCaptureWindow()
        permission.granted = true
        capture.captureResult = .failure(WindowCaptureError.failed)   // the window was closed, not a permission issue
        capture.windowPresence = .gone                                  // Phase 15.2: macOS no longer lists it
        let result = await m.checkAutoCaptureAccess(for: ref)
        XCTAssertEqual(result, .windowUnavailable)
        XCTAssertEqual(m.autoCaptureStatus(for: ref), .windowUnavailable)
        XCTAssertTrue(m.autoCaptureBindings.isEmpty, "the stale link is dropped, never replaced by another window")
        XCTAssertEqual(capture.forgotten, ["h1"])
    }

    // MARK: No window linked at all, even with access granted

    func testCheckAgainWithNoLinkAtAllReportsWindowNotBound() async throws {
        let (m, permission, _) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        permission.granted = true
        let result = await m.checkAutoCaptureAccess(for: ref)
        XCTAssertEqual(result, .windowNotBound)
    }

    // MARK: Quit never loses history or settings

    func testQuitAppIsInjectedAndNeverTouchesHistoryOrLinks() async throws {
        let (m, _, _) = await model()
        let ref = try XCTUnwrap(m.currentRef)
        m.chooseAutoCaptureWindow()
        let bindingsBefore = m.autoCaptureBindings
        var quitCalls = 0
        m.quitApp = { quitCalls += 1 }
        m.autoCaptureStatuses[ref.key] = .restartRequired
        m.quitApp()
        XCTAssertEqual(quitCalls, 1)
        XCTAssertEqual(m.autoCaptureBindings, bindingsBefore, "quitting (to reopen) does not drop the link")
        XCTAssertEqual(m.autoCaptureStatus(for: ref), .restartRequired, "the status is explained, not cleared, until Check Again confirms it")
    }

    // MARK: The picker's own permission denial drives Settings' recovery button

    func testPickerPermissionDenialSetsAndClearsTheSettingsRecoveryFlag() async throws {
        let (m, _, capture) = await model()
        capture.pickResult = .failure(WindowCaptureError.permissionDenied)
        m.chooseAutoCaptureWindow()
        XCTAssertTrue(m.autoCapturePermissionBlocked)
        capture.pickResult = .success(PickedWindow(handle: "h2", label: "w"))
        m.chooseAutoCaptureWindow()
        XCTAssertFalse(m.autoCapturePermissionBlocked, "a successful link clears it")
    }

    func testPickerFailureForOtherReasonsDoesNotSetTheRecoveryFlag() async throws {
        let (m, _, capture) = await model()
        capture.pickResult = .failure(WindowCaptureError.failed)
        m.chooseAutoCaptureWindow()
        XCTAssertFalse(m.autoCapturePermissionBlocked, "not every picker failure is a permission problem")
    }

    // MARK: Regression: normal capture still works end to end when granted

    func testNormalAutoCaptureStillWorksWhenAccessIsGranted() async throws {
        let (m, permission, _) = await model()
        permission.granted = true
        m.chooseAutoCaptureWindow()
        let core = m.core as! FakeCore
        core.sessionsByProject["/a"] = [Phase93Tests.session("s", provider: "claude_code", host: "claude_desktop", project: "/a",
                                                             last: Self.ago(5), turns: 2)]
        core.turnsBySession["s"] = [turn(1, chars: 6, at: Self.ago(400)), turn(2, at: Self.ago(5))]
        m.captureSettle = .immediate
        await m.refreshNow()
        await m.waitForAutoCaptures()
        let ref = ReportRef.local(sessionKey: "s", turn: 2)
        XCTAssertEqual(m.attachments(for: ref).count, 1)
        XCTAssertEqual(m.autoCaptureStatus(for: ref), .captured)
        // In memory only.
        XCTAssertTrue(m.attachments(for: ref)[0].isInMemory)
        XCTAssertTrue(files(under: root).filter { $0.hasSuffix(".png") }.isEmpty)
    }

    func files(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { ($0 as? URL)?.lastPathComponent }
    }
}

// MARK: - LiveScreenRecordingPermission: URL fallback chain

@MainActor
final class LiveScreenRecordingPermissionTests: XCTestCase {
    func testOpenSettingsTriesEachURLInOrderUntilOneSucceeds() {
        var tried: [String] = []
        let permission = LiveScreenRecordingPermission { url in
            tried.append(url.absoluteString)
            return tried.count == 2    // the first fails, the second succeeds
        }
        XCTAssertTrue(permission.openSettings())
        XCTAssertEqual(tried, Array(LiveScreenRecordingPermission.settingsURLs.prefix(2)))
    }

    func testOpenSettingsReturnsFalseWhenNothingCanBeOpened() {
        let permission = LiveScreenRecordingPermission { _ in false }
        XCTAssertFalse(permission.openSettings())
    }

    func testTheCurrentPaneIdentifierIsTriedFirst() {
        XCTAssertEqual(LiveScreenRecordingPermission.settingsURLs.first,
                       "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
    }
}

// MARK: - Settings: the recovery button appears only while blocked

@MainActor
final class Phase141SettingsRecoveryTests: XCTestCase {
    func testOpenSettingsButtonAppearsOnlyWhilePermissionBlocked() async throws {
        let suite = "PromptRelayTests.p141settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(TestDefaults.named(suite))
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally(); removeTestDefaults(suite) }
        let core = FakeCore(projects: [project("/a", sessions: 1, last: "2026-10-29T16:13:51.000000Z")])
        core.sessionsByProject["/a"] = [sessionSummary("s", project: "/a", last: "2026-10-29T16:13:51.000000Z")]
        core.turnsBySession["s"] = [turn(1, chars: 6)]
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        await m.refreshNow()

        func frames() -> [String: CGRect] {
            var collected: [String: CGRect] = [:]
            let sink = ScrollSegmentSink(space: "p141") { _, _ in }   // unused; real sink below
            _ = sink
            let host = NSHostingView(rootView: AutoCaptureLinksView(model: m)
                .environment(\.islandFrameSink) { id, rect in collected[id] = rect }
                .frame(width: 520).padding(12))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return collected
        }

        m.autoCapturePermissionBlocked = false
        XCTAssertNil(frames()["settings.autocapture.openSettings"])
        m.autoCaptureMessage = "Auto screenshot needs permission."
        m.autoCapturePermissionBlocked = true
        XCTAssertNotNil(frames()["settings.autocapture.openSettings"], "shown once the picker reports denied access")
    }
}
