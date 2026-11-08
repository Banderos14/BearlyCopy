import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 14: Automatic final screenshots. The planner's rules, the stability
/// check on real pixel buffers, and the whole flow in AppModel with a fake
/// capturer that holds several picked windows (no ScreenCaptureKit, no GUI).
@MainActor
@Suite struct Phase14CaptureTests {
    // MARK: Fixtures

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func ago(_ s: TimeInterval) -> String { iso.string(from: Date(timeIntervalSinceNow: -s)) }

    static func session(_ key: String, provider: String = "claude_code", host: String = "claude_desktop", profile: String? = nil,
                        project: String = "/a", last: String, turns: Int = 1, completion: String = "answer",
                        attention: String? = nil, running: Bool = false) -> SessionSummary {
        var json: [String: Any] = [
            "session_id": key, "session_key": key, "project": ["path": project, "name": (project as NSString).lastPathComponent],
            "first_event_at": last, "last_event_at": last, "event_count": 2, "turn_count": turns, "cwds": [project],
            "last_turn": ["index": turns, "status": "stop_received", "answered_at": last, "completion": completion],
            "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0],
            "answered_count": turns, "running": running,
            "source": ["provider": provider, "host": host, "native_session_id": "n-" + key, "capture": "hooks",
                       "capabilities": ["prompt", "final_response"]],
        ]
        if let profile {
            json["profile"] = ["id": profile, "provider": provider, "basis": "config_dir", "default": false, "hint": "~/.x"]
        }
        if let attention { json["attention"] = ["state": "needs_input", "kind": attention, "since": last, "subagent": false] }
        return try! JSONDecoder().decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Picks hand out windows h1, h2…; each capture returns the next frame
    /// queued for that window (else its color).
    final class MultiCapture: WindowCapturing {
        var picks = 0
        var cancelPick = false
        var windowIDs: [UInt32?] = []
        var captures: [String: Int] = [:]
        var failing: [String: WindowCaptureError] = [:]
        var frames: [String: [NSColor]] = [:]
        var color: [String: NSColor] = [:]
        var forgotten: [String] = []
        var delay: UInt64 = 0
        var total: Int { captures.values.reduce(0, +) }

        func captureWindow(completion: @escaping @MainActor (Result<WindowCapture.Shot, Error>?) -> Void) { completion(nil) }
        func pickWindow(completion: @escaping @MainActor (Result<PickedWindow, Error>?) -> Void) {
            guard !cancelPick else { completion(nil); return }
            picks += 1
            let id = picks <= windowIDs.count ? windowIDs[picks - 1] : nil
            completion(.success(PickedWindow(handle: "h\(picks)", label: "Claude window", windowID: id)))
        }
        func capture(_ window: PickedWindow) async throws -> WindowCapture.Shot {
            captures[window.handle, default: 0] += 1
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if let error = failing[window.handle] { throw error }
            let c = frames[window.handle]?.isEmpty == false ? frames[window.handle]!.removeFirst() : (color[window.handle] ?? .systemBlue)
            return .init(png: Phase14CaptureTests.png(c), label: "Window")
        }
        func forget(_ window: PickedWindow) { forgotten.append(window.handle) }
        /// Phase 15.2: windows macOS no longer lists; offscreen ones exist but are hidden.
        var gone: Set<String> = []
        var offscreen: Set<String> = []
        func presence(of window: PickedWindow) -> WindowPresence {
            gone.contains(window.handle) ? .gone : .present(onScreen: !offscreen.contains(window.handle))
        }
    }

    static func png(_ color: NSColor, caret: Bool = false, lines: Int = 0) -> Data {
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            color.setFill(); rect.fill()
            NSColor.white.setFill()
            for i in 0..<lines { NSRect(x: 40, y: 360 - CGFloat(i) * 18, width: 560, height: 8).fill() }
            if caret { NSRect(x: 300, y: 40, width: 2, height: 16).fill() }
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    struct World {
        let core: FakeCore
        let model: AppModel
        let capture: MultiCapture
        let board: NSPasteboard
        let root: URL
    }

    func world(_ sessions: [SessionSummary]) async -> World {
        let core = FakeCore(projects: [project("/a", sessions: sessions.count, last: Self.ago(400)), project("/b", sessions: 0, last: Self.ago(900))])
        core.sessionsByProject["/a"] = sessions.filter { $0.project.path == "/a" }
        core.sessionsByProject["/b"] = sessions.filter { $0.project.path == "/b" }
        for s in sessions { core.turnsBySession[s.sessionKey] = (1...s.turnCount).map { turn($0, at: s.lastEventAt ?? Self.ago(400)) } }
        core.showResult = { [unowned core] key, i in
            .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "answer \(i)")), warnings: []))
        }
        let board = NSPasteboard(name: .init("PromptRelay14c-\(UUID().uuidString)"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr14c-" + UUID().uuidString)
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, reportStore: ReportStore(root: root))
        let capture = MultiCapture()
        m.windowCapture = capture
        m.captureSettle = .immediate
        m.captureNow = { Date().addingTimeInterval(-200) }    // links made "200 s ago"; answers after that are new
        await m.refreshNow()
        m.autoCaptureFinalWindow = true
        return World(core: core, model: m, capture: capture, board: board, root: root)
    }

    /// A session finishes a new turn now-ish.
    func finish(_ w: World, _ s: SessionSummary, at: String, turns: Int, completion: String = "answer", attention: String? = nil,
                provider: String = "claude_code", host: String = "claude_desktop", profile: String? = nil) async {
        let updated = Self.session(s.sessionKey, provider: provider, host: host, profile: profile, project: s.project.path ?? "/a",
                                   last: at, turns: turns, completion: completion, attention: attention)
        let path = s.project.path ?? "/a"
        w.core.sessionsByProject[path] = [updated] + (w.core.sessionsByProject[path] ?? []).filter { $0.sessionKey != s.sessionKey }
        w.core.turnsBySession[s.sessionKey] = (1...turns).map { turn($0, at: $0 == turns ? at : Self.ago(400),
                                                                  completion: $0 == turns ? completion : nil) }
        await w.model.refreshNow()
        await w.model.waitForAutoCaptures()
    }

    func files(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { ($0 as? URL)?.lastPathComponent }
    }

    func cleanup(_ w: World) { w.board.releaseGlobally(); try? FileManager.default.removeItem(at: w.root) }

    // MARK: Planner rules

    let key = CaptureSourceKey(provider: .claudeCode, profileID: "cc-personal", host: .claudeDesktop, projectPath: "/a")
    let then = Date(timeIntervalSince1970: 1_000_000)

    func binding(_ key: CaptureSourceKey, session: String? = nil, handle: String = "h1", id: UInt32? = nil) -> WindowBinding {
        WindowBinding(key: key, sessionKey: session, window: PickedWindow(handle: handle, label: "w", windowID: id), createdAt: then)
    }

    @Test func onlyARealFinalAnswerIsCaptured() {
        let b = [binding(key)]
        func decide(final: Bool, needsInput: Bool = false, at: TimeInterval = 10) -> AutoCapturePlanner.Decision {
            AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: then.addingTimeInterval(at), isFinal: final,
                                      needsInput: needsInput, bindings: b, others: [], now: then.addingTimeInterval(20))
        }
        #expect(decide(final: true) == .capture(b[0]))
        #expect(decide(final: false) == .skip(nil), "intermediate Stop / background wait: no screenshot")
        #expect(decide(final: true, needsInput: true) == .skip(nil), "a question or plan approval: no screenshot")
        #expect(decide(final: true, at: -5) == .skip(nil), "finished before the link: never")
    }

    @Test func theAgentProfileHostAndProjectMustAllMatch() {
        let b = [binding(key)]
        for other in [CaptureSourceKey(provider: .claudeCode, profileID: "cc-work", host: .claudeDesktop, projectPath: "/a"),
                      CaptureSourceKey(provider: .codex, profileID: "cc-personal", host: .claudeDesktop, projectPath: "/a"),
                      CaptureSourceKey(provider: .claudeCode, profileID: "cc-personal", host: .xcode, projectPath: "/a"),
                      CaptureSourceKey(provider: .claudeCode, profileID: "cc-personal", host: .claudeDesktop, projectPath: "/b")] {
            #expect(AutoCapturePlanner.decide(sessionKey: "s", key: other, finishedAt: then.addingTimeInterval(5), isFinal: true,
                                              needsInput: false, bindings: b, others: [], now: then) == .skip(.windowNotBound))
        }
        let unknownHost = CaptureSourceKey(provider: .claudeCode, profileID: "cc-personal", host: .unknown, projectPath: "/a")
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: unknownHost, finishedAt: then.addingTimeInterval(5), isFinal: true,
                                          needsInput: false, bindings: b, others: [], now: then) == .skip(.windowNotBound))
    }

    @Test func twoActiveConversationsInOneLinkedWindowAreAmbiguous() {
        let now = then.addingTimeInterval(60)
        let other = AutoCapturePlanner.Candidate(sessionKey: "t", key: key, lastEventAt: now.addingTimeInterval(-30), running: false)
        let shared = [binding(key)]
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: shared, others: [other], now: now) == .skip(.associationRequired))
        // The other conversation has been quiet for over 30 minutes: not ambiguous.
        let quiet = AutoCapturePlanner.Candidate(sessionKey: "t", key: key, lastEventAt: now.addingTimeInterval(-3600), running: false)
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: shared, others: [quiet], now: now) == .capture(shared[0]))
        // The user links this conversation to its own window: resolved.
        let own = binding(key, session: "s", handle: "h2")
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: shared + [own], others: [other], now: now) == .capture(own))
        // …but not when that same window is also the other conversation's.
        let same = binding(key, session: "s", handle: "h1")
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: shared + [same], others: [other], now: now) == .skip(.associationRequired))
        // Two different windows linked for one agent: ambiguous.
        let second = binding(key, handle: "h3")
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: shared + [second], others: [], now: now) == .skip(.associationRequired))
    }

    @Test func oneWindowLinkedForTwoProfilesIsAmbiguousWhileBothAreActive() {
        let work = CaptureSourceKey(provider: .claudeCode, profileID: "cc-work", host: .claudeDesktop, projectPath: "/a")
        let now = then.addingTimeInterval(60)
        let both = [binding(key, handle: "h1", id: 77), binding(work, handle: "h2", id: 77)]   // the same system window
        let other = AutoCapturePlanner.Candidate(sessionKey: "w", key: work, lastEventAt: now, running: true)
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: both, others: [other], now: now) == .skip(.associationRequired))
        let differentWindows = [binding(key, handle: "h1", id: 77), binding(work, handle: "h2", id: 78)]
        #expect(AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: differentWindows, others: [other], now: now) == .capture(differentWindows[0]))
    }

    // MARK: Stability on real pixel buffers

    @Test func stabilityIgnoresACaretButNotNewText() throws {
        let base = try #require(CaptureStability.fingerprint(png: Self.png(.darkGray, lines: 6)))
        let caret = try #require(CaptureStability.fingerprint(png: Self.png(.darkGray, caret: true, lines: 6)))
        let more = try #require(CaptureStability.fingerprint(png: Self.png(.darkGray, lines: 9)))
        #expect(CaptureStability.same(base, base))
        #expect(CaptureStability.same(base, caret), "a blinking caret is not a change")
        #expect(!CaptureStability.same(base, more), "three more lines drawn: still changing")
        #expect(!CaptureStability.same(base, nil))
    }

    // MARK: The whole flow

    @Test func oneFinalAnswerGetsOneScreenshotInMemoryUnchecked() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        // The model writes only to its injected pasteboard; the system one is
        // not checked (a person copying during the run would change it).
        let boardBefore = w.board.changeCount
        w.model.chooseAutoCaptureWindow()
        #expect(w.model.autoCaptureBindings.count == 1)
        await finish(w, s, at: Self.ago(5), turns: 2)
        let ref = ReportRef.local(sessionKey: "s", turn: 2)
        let shots = w.model.attachments(for: ref)
        #expect(shots.count == 1 && shots[0].isInMemory && shots[0].effectiveSource == .windowCapture)
        #expect(shots[0].originalFilename.hasPrefix("Auto screenshot Claude Desktop"))
        #expect(!shots[0].isSelected, "not in the hand-off until the user ticks it")
        #expect(w.model.handoffAttachments(for: ref).isEmpty, "Copy with Context / Context Pack leave it out")
        #expect(w.model.autoCaptureStatus(for: ref) == .captured)
        // Redelivery and refreshes: still one.
        await w.model.refreshNow(); await w.model.refreshNow(); await w.model.waitForAutoCaptures()
        #expect(w.capture.total == 1 && w.model.attachments(for: ref).count == 1)
        #expect(files(under: w.root).filter { $0.hasSuffix(".png") }.isEmpty, "no PNG written")
        #expect(w.board.changeCount == boardBefore, "no clipboard write")
        // The user ticks it: now it goes with Copy with Context and Context Packs.
        w.model.setSelected(shots[0], true)
        #expect(w.model.handoffAttachments(for: ref).map(\.id) == [shots[0].id])
        // The earlier answer never gets this screenshot.
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 1)).isEmpty)
    }

    @Test func includeInHandoffStartsThemChecked() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.autoScreenshotsInHandoff = true
        w.model.chooseAutoCaptureWindow()
        await finish(w, s, at: Self.ago(5), turns: 2)
        let ref = ReportRef.local(sessionKey: "s", turn: 2)
        #expect(w.model.handoffAttachments(for: ref).count == 1)
    }

    @Test func questionsPlansAndBackgroundWaitsGetNoScreenshot() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.chooseAutoCaptureWindow()
        // Background work still running at the Stop: not the result.
        await finish(w, s, at: Self.ago(30), turns: 2, completion: "waiting_background")
        #expect(w.capture.total == 0)
        // A question / plan approval pending on the session: nothing either.
        await finish(w, s, at: Self.ago(20), turns: 3, attention: "question")
        #expect(w.capture.total == 0)
        // The continuation's real final answer: exactly one.
        await finish(w, s, at: Self.ago(10), turns: 4)
        #expect(w.capture.total == 1)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 4)).count == 1)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 2)).isEmpty)
    }

    @Test func twoAgentsInTwoWindowsEachGetTheirOwn() async throws {
        let claude = Self.session("claude", last: Self.ago(400))
        let codex = Self.session("codex", provider: "codex", host: "xcode", last: Self.ago(410))
        let w = await world([claude, codex]); defer { cleanup(w) }
        w.capture.color = ["h1": .systemOrange, "h2": .systemGreen]
        w.model.selectSession("claude"); w.model.chooseAutoCaptureWindow()      // h1: Claude Desktop
        w.model.selectSession("codex"); w.model.chooseAutoCaptureWindow()       // h2: Xcode
        await finish(w, codex, at: Self.ago(8), turns: 2, provider: "codex", host: "xcode")
        await finish(w, claude, at: Self.ago(5), turns: 2)
        #expect(w.capture.captures == ["h1": 1, "h2": 1])
        let a = try #require(w.model.attachments(for: .local(sessionKey: "claude", turn: 2)).first)
        let b = try #require(w.model.attachments(for: .local(sessionKey: "codex", turn: 2)).first)
        #expect(w.model.attachmentData(a) == Self.png(.systemOrange))
        #expect(w.model.attachmentData(b) == Self.png(.systemGreen))
    }

    @Test func twoProfilesOfOneProviderNeverShareAWindow() async throws {
        let personal = Self.session("p", profile: "cc-personal", last: Self.ago(4000))
        let work = Self.session("w", profile: "cc-work", last: Self.ago(4100))
        let w = await world([personal, work]); defer { cleanup(w) }
        w.model.selectSession("p"); w.model.chooseAutoCaptureWindow()          // Personal only
        await finish(w, work, at: Self.ago(10), turns: 2, profile: "cc-work")
        #expect(w.capture.total == 0)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "w", turn: 2)) == .windowNotBound)
        await finish(w, personal, at: Self.ago(5), turns: 2, profile: "cc-personal")
        #expect(w.capture.total == 1)
        #expect(w.model.attachments(for: .local(sessionKey: "p", turn: 2)).count == 1)
    }

    @Test func twoConversationsInOneAppNeedAnExplicitLink() async throws {
        let s = Self.session("s", last: Self.ago(60))
        let t = Self.session("t", last: Self.ago(90))
        let w = await world([s, t]); defer { cleanup(w) }
        w.model.selectSession("s"); w.model.chooseAutoCaptureWindow()
        await finish(w, s, at: Self.ago(5), turns: 2)
        let ref = ReportRef.local(sessionKey: "s", turn: 2)
        #expect(w.capture.total == 0, "never a picture of the wrong conversation")
        #expect(w.model.autoCaptureStatus(for: ref) == .associationRequired)
        #expect(w.model.attachments(for: ref).isEmpty)
        // Linking this conversation to its own window resolves the next answer.
        w.model.selectSession("s"); w.model.linkAutoCaptureWindowToConversation()
        await finish(w, s, at: Self.ago(2), turns: 3)
        #expect(w.capture.captures["h2"] == 1 && (w.capture.captures["h1"] ?? 0) == 0)
    }

    @Test func permissionDeniedKeepsTheLinkAndSaysSo() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.chooseAutoCaptureWindow()
        w.capture.failing["h1"] = .permissionDenied
        await finish(w, s, at: Self.ago(10), turns: 2)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "s", turn: 2)) == .permissionRequired)
        #expect(w.model.autoCaptureBindings.count == 1)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 2)).isEmpty)
        // Permission given again: the next answer is captured.
        w.capture.failing["h1"] = nil
        await finish(w, s, at: Self.ago(5), turns: 3)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 3)).count == 1)
    }

    @Test func aClosedWindowIsDroppedNeverReplaced() async throws {
        let claude = Self.session("claude", last: Self.ago(400))
        let codex = Self.session("codex", provider: "codex", host: "xcode", last: Self.ago(410))
        let w = await world([claude, codex]); defer { cleanup(w) }
        w.model.selectSession("claude"); w.model.chooseAutoCaptureWindow()
        w.model.selectSession("codex"); w.model.chooseAutoCaptureWindow()
        w.capture.failing["h1"] = .failed                                       // Claude's window was closed
        w.capture.gone.insert("h1")
        await finish(w, claude, at: Self.ago(5), turns: 2)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "claude", turn: 2)) == .windowUnavailable)
        #expect(w.model.attachments(for: .local(sessionKey: "claude", turn: 2)).isEmpty)
        #expect((w.capture.captures["h2"] ?? 0) == 0, "Xcode's window is never used instead")
        #expect(w.model.autoCaptureBindings.map(\.window.handle) == ["h2"])
        #expect(w.capture.forgotten.contains("h1"))
    }

    @Test func aNewerAnswerWhileTheWindowSettlesSupersedesTheOlder() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.captureSettle = CaptureSettle(first: 0.4, recheck: 0, maxShots: 1)
        w.model.chooseAutoCaptureWindow()
        // Turn 2 arrives; before its picture is taken, turn 3 arrives.
        let updated2 = Self.session("s", last: Self.ago(20), turns: 2)
        w.core.sessionsByProject["/a"] = [updated2]
        w.core.turnsBySession["s"] = [turn(1, at: Self.ago(400)), turn(2, at: Self.ago(20))]
        await w.model.refreshNow()
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "s", turn: 2)) == .pending)
        await finish(w, s, at: Self.ago(10), turns: 3)
        #expect(w.capture.total == 1)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "s", turn: 2)) == .superseded)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 2)).isEmpty)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 3)).count == 1)
    }

    @Test func turningItOffDuringACaptureAddsNothing() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.captureSettle = CaptureSettle(first: 0.3, recheck: 0, maxShots: 1)
        w.model.chooseAutoCaptureWindow()
        let updated = Self.session("s", last: Self.ago(10), turns: 2)
        w.core.sessionsByProject["/a"] = [updated]
        w.core.turnsBySession["s"] = [turn(1, at: Self.ago(400)), turn(2, at: Self.ago(10))]
        await w.model.refreshNow()
        w.model.autoCaptureFinalWindow = false
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(w.capture.total == 0)
        #expect(w.model.attachments(for: .local(sessionKey: "s", turn: 2)).isEmpty)
        #expect(w.model.autoCaptureBindings.isEmpty && w.capture.forgotten == ["h1"])
    }

    @Test func theWindowIsCapturedAgainUntilItSettles() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.captureSettle = CaptureSettle(first: 0, recheck: 0, maxShots: 3)
        w.capture.frames["h1"] = [.systemRed, .systemGreen, .systemGreen]       // still drawing, then settled
        w.model.chooseAutoCaptureWindow()
        await finish(w, s, at: Self.ago(5), turns: 2)
        #expect(w.capture.total == 3)
        let shot = try #require(w.model.attachments(for: .local(sessionKey: "s", turn: 2)).first)
        #expect(w.model.attachmentData(shot) == Self.png(.systemGreen))
    }

    @Test func oldAnswersAndAnswersBeforeTheFeatureAreNeverCaptured() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.chooseAutoCaptureWindow()
        await w.model.refreshNow(); await w.model.waitForAutoCaptures()
        #expect(w.capture.total == 0, "the answer from before the link stays without one")
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "s", turn: 1)) == nil)
    }

    @Test func screenshotsExpireAndClearWithoutTouchingAnswers() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.model.chooseAutoCaptureWindow()
        await finish(w, s, at: Self.ago(5), turns: 2)
        let ref = ReportRef.local(sessionKey: "s", turn: 2)
        let shot = try #require(w.model.attachments(for: ref).first)
        #expect(w.model.temporaryScreenshotSummary.count == 1)
        let store = try #require(w.model.reportStore)
        store.clock = { Date().addingTimeInterval(store.ephemeralLimits.maxAge + 1) }
        #expect(!w.model.isAttachmentAvailable(shot), "expired after the Phase 10 age limit")
        store.clock = Date.init
        w.model.clearTemporaryScreenshots()
        #expect(w.model.attachments(for: ref).isEmpty && w.model.temporaryScreenshotSummary.count == 0)
        #expect(w.model.autoCaptureBindings.count == 1, "links stay")
    }

    @Test func cancellingThePickerLinksNothing() async throws {
        let s = Self.session("s", last: Self.ago(400))
        let w = await world([s]); defer { cleanup(w) }
        w.capture.cancelPick = true
        w.model.chooseAutoCaptureWindow()
        #expect(w.model.autoCaptureBindings.isEmpty && !w.model.isPresentingSystemDialog)
        await finish(w, s, at: Self.ago(5), turns: 2)
        #expect(w.capture.total == 0)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "s", turn: 2)) == .windowNotBound)
    }

    @Test func decidingWithThreeThousandConversationsIsCheap() {
        let now = then.addingTimeInterval(60)
        let others = (0..<3000).map { i in
            AutoCapturePlanner.Candidate(sessionKey: "s\(i)", key: CaptureSourceKey(provider: .claudeCode, profileID: "p\(i % 7)",
                                                                                  host: .claudeDesktop, projectPath: "/p\(i % 50)"),
                                         lastEventAt: now.addingTimeInterval(-Double(i)), running: false)
        }
        let b = [binding(key)]
        let start = Date()
        for _ in 0..<10 {
            _ = AutoCapturePlanner.decide(sessionKey: "s", key: key, finishedAt: now, isFinal: true, needsInput: false,
                                          bindings: b, others: others, now: now)
        }
        #expect(Date().timeIntervalSince(start) / 10 < 0.05, "one decision over 3,000 conversations stays under 50 ms")
    }

    @Test func twoFinalsInOneRefreshEachGetTheirOwnScreenshot() async throws {
        let claude = Self.session("claude", last: Self.ago(400))
        let codex = Self.session("codex", provider: "codex", host: "xcode", last: Self.ago(410))
        let w = await world([claude, codex]); defer { cleanup(w) }
        w.capture.color = ["h1": .systemOrange, "h2": .systemGreen]
        w.model.selectSession("claude"); w.model.chooseAutoCaptureWindow()
        w.model.selectSession("codex"); w.model.chooseAutoCaptureWindow()
        // Both stop between two refreshes (one FSEvents batch).
        w.core.sessionsByProject["/a"] = [Self.session("claude", last: Self.ago(6), turns: 2),
                                          Self.session("codex", provider: "codex", host: "xcode", last: Self.ago(7), turns: 2)]
        w.core.turnsBySession["claude"] = [turn(1, at: Self.ago(400)), turn(2, at: Self.ago(6))]
        w.core.turnsBySession["codex"] = [turn(1, at: Self.ago(410)), turn(2, at: Self.ago(7))]
        await w.model.refreshNow()
        await w.model.waitForAutoCaptures()
        #expect(w.capture.captures == ["h1": 1, "h2": 1])
        let a = try #require(w.model.attachments(for: .local(sessionKey: "claude", turn: 2)).first)
        let b = try #require(w.model.attachments(for: .local(sessionKey: "codex", turn: 2)).first)
        #expect(w.model.attachmentData(a) == Self.png(.systemOrange) && w.model.attachmentData(b) == Self.png(.systemGreen))
        #expect(files(under: w.root).filter { $0.hasSuffix(".png") }.isEmpty)
    }
}
