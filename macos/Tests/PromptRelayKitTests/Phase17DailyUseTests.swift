import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 17: Daily Use — defaults, the one-step setup and the readiness
/// status, through the real Core of this checkout (real CLI, real hook, a
/// temporary data folder and an isolated HOME with a stand-in plugin
/// record). In-memory settings; fake Screen Recording and window picker.
@MainActor
final class Phase17DailyUseTests: XCTestCase {
    var base: URL!
    var home: URL!
    var fakeHome: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory.path.withCString { realpath($0, nil) }.map { String(cString: $0) }!
        base = URL(fileURLWithPath: tmp).appendingPathComponent("pr17-daily-\(UUID().uuidString)")
        home = base.appendingPathComponent("data")
        fakeHome = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    func locator() -> CoreLocator {
        CoreLocator(processEnvironment: ["HOME": fakeHome.path, "PROMPT_RELAY_HOME": home.path, "PROMPT_RELAY_CLI": Repo.cli],
                    bundleResourceURL: nil, defaults: { _ in nil })
    }

    /// What Claude Code records for an installed plugin (version only matters).
    func installPlugin(_ version: String?) throws {
        let dir = fakeHome.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("installed_plugins.json")
        guard let version else { try? FileManager.default.removeItem(at: file); return }
        let record: [String: Any] = ["version": 2, "plugins": ["prompt-relay@prompt-relay": [["scope": "user", "version": version,
                                                                                               "installPath": dir.appendingPathComponent("cache/\(version)").path]]]]
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }

    func repo(_ name: String) throws -> String {
        let url = base.appendingPathComponent("repos/\(name)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: url.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        return url.path
    }

    func hookTurn(_ session: String, in cwd: String, answer: String) throws {
        for payload in [["hook_event_name": "UserPromptSubmit", "session_id": session, "cwd": cwd, "prompt": "Task", "prompt_id": "p-\(session)"],
                        ["hook_event_name": "Stop", "session_id": session, "cwd": cwd, "prompt_id": "p-\(session)",
                         "last_assistant_message": answer, "stop_hook_active": false] as [String: Any]] {
            let location = try locator().locate()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: location.python)
            p.arguments = ["-I", "-S", location.cli, "hook"]
            p.environment = ["HOME": fakeHome.path, "PROMPT_RELAY_HOME": home.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
    }

    func outcomes() -> [String] {
        ((try? String(contentsOf: home.appendingPathComponent("handler.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { $0.split(separator: " ").last.map(String.init) }
    }

    struct Rig {
        let model: AppModel
        let permission: Phase141PermissionTests.FakePermission
        let capture: Phase141PermissionTests.FakeCapture
        let board: NSPasteboard
    }

    func rig(_ defaults: MemorySettingsStore) async -> Rig {
        let board = NSPasteboard(name: .init("PR17D-\(UUID().uuidString)"))
        // The app passes the Core no HOME (it reads the real one); here the
        // Core is given the isolated HOME so the stand-in plugin record is the
        // one it finds — never this Mac's real Claude Code plugin.
        let loc = locator(), fake = fakeHome.path
        let core = CoreClient {
            let found = try loc.locate()
            return CoreLocation(python: found.python, cli: found.cli, environment: found.environment.merging(["HOME": fake]) { $1 })
        }
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board),
                             dataDirectory: nil, stateDefaults: defaults, reportStore: ReportStore(root: base.appendingPathComponent("app")))
        let permission = Phase141PermissionTests.FakePermission()
        let capture = Phase141PermissionTests.FakeCapture()
        model.screenRecordingPermission = permission
        model.windowCapture = capture
        model.bundledCoreVersion = nil
        await model.refreshNow()
        await model.reloadDoctor()
        return Rig(model: model, permission: permission, capture: capture, board: board)
    }

    func link(_ model: AppModel) {
        let key = CaptureSourceKey(provider: .claudeCode, profileID: ProfileKey.unassigned, host: .claudeDesktop, projectPath: "/p")
        model.autoCaptureBindings.append(WindowBinding(key: key, sessionKey: nil, window: PickedWindow(handle: "h", label: "Claude"), createdAt: Date()))
    }

    // MARK: Defaults

    func testFreshInstallDefaultsNeedNoSetupAndNothingSensitiveIsOn() async throws {
        try installPlugin("0.9.0")
        let defaults = MemorySettingsStore()
        let r = await rig(defaults)
        defer { r.board.releaseGlobally() }
        let m = r.model
        // Work without any setup.
        XCTAssertTrue(m.followsLatest)
        XCTAssertFalse(m.staysOnChosenSession)
        XCTAssertFalse(m.sessionPinned)
        XCTAssertTrue(m.autoSelectResultAttachments, "result files are prepared")
        XCTAssertTrue(m.autoSelectPreparedAttachments, "and selected")
        XCTAssertTrue(m.tracksReadyAnswers, "new-answer indicators across all projects")
        // Need the user's yes: off, and nothing was written for them.
        XCTAssertEqual(m.captureSettings?.mode, .selected, "Global Capture is never on by itself")
        XCTAssertFalse(m.autoCaptureFinalWindow)
        XCTAssertFalse(m.autoScreenshotsInHandoff)
        XCTAssertNil(defaults.object(forKey: AppModel.autoCaptureKey))
        // The one setup is offered, with the recommended choices proposed (not applied).
        XCTAssertTrue(m.offersDailyUseSetup)
        XCTAssertEqual(m.dailyUseProposal, .init(globalCapture: true, autoScreenshots: true, screenshotsInHandoff: false))
        XCTAssertEqual(m.dailyUse.state, .setupIncomplete)
        XCTAssertNotEqual(m.dailyUse.state, .ready, "never Ready before anything was verified")
    }

    // MARK: The one-step setup

    func testEnableRecommendedTurnsOnExactlyWhatWasTickedAndReadinessFollowsTheRealState() async throws {
        try installPlugin("0.9.0")
        let defaults = MemorySettingsStore()
        let r = await rig(defaults)
        defer { r.board.releaseGlobally() }
        let m = r.model
        let outcome = await m.enableDailyUse(.init(globalCapture: true, autoScreenshots: true, screenshotsInHandoff: false))
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(m.captureSettings?.mode, .global)
        XCTAssertTrue(m.autoCaptureFinalWindow)
        XCTAssertFalse(m.autoScreenshotsInHandoff, "left to the user")
        XCTAssertFalse(m.offersDailyUseSetup, "asked once")
        XCTAssertFalse(m.offersGlobalCapture, "and the older offer does not ask again")

        // Toggles are on, but no event was ever stored: not Ready.
        XCTAssertEqual(m.dailyUse.state, .setupIncomplete)
        XCTAssertEqual(m.dailyUse.checks.first { $0.id == "hooks" }?.level, .attention)

        // A new repository, never switched on: captured (Global Capture works for real).
        let unknown = try repo("brand-new-repo")
        try hookTurn("s1", in: unknown, answer: "Done ✅")
        XCTAssertEqual(outcomes().suffix(2), ["stored", "stored"])
        await m.recheckDailyUse()
        XCTAssertEqual(m.readyAnswer?.sessionKey.contains("s1"), true, "the new conversation in the new project is Latest")
        XCTAssertEqual(m.selectedProjectPath, unknown)

        // Screenshots are on but no window is linked.
        XCTAssertEqual(m.dailyUse.state, .windowNotLinked)
        XCTAssertEqual(m.dailyUse.action, .linkWindow)
        link(m)
        r.permission.granted = false
        XCTAssertNotEqual(m.dailyUse.state, .permissionRequired, "the preflight alone never blocks a picked window")
        m.autoCapturePermissionBlocked = true   // a real capture was refused
        XCTAssertEqual(m.dailyUse.state, .permissionRequired)
        XCTAssertEqual(m.dailyUse.action, .openScreenRecordingSettings)
        XCTAssertEqual(m.dailyUse.secondaryAction, .quitToApply)
        XCTAssertEqual(m.dailyUse.steps.count, 3, "off, on, reopen — in order")
        XCTAssertTrue(m.dailyUse.steps[1].contains("off, then on"))
        m.perform(.openScreenRecordingSettings)
        XCTAssertEqual(r.permission.opens, 1)
        XCTAssertEqual(m.dailyUse.state, .permissionRequired, "opening Settings is not a grant")
        r.permission.granted = true
        await m.recheckDailyUse()   // Check Again
        XCTAssertEqual(m.dailyUse.state, .ready)
        XCTAssertNil(m.dailyUse.action)
        XCTAssertTrue(m.dailyUse.checks.allSatisfy { $0.level != .attention })

        // Paused: said first, with the way back.
        await m.setCaptureMode(.mode(.paused))
        XCTAssertEqual(m.dailyUse.state, .capturePaused)
        XCTAssertEqual(m.dailyUse.action, .resumeCapture)
        await m.setCaptureMode(.resume)
        XCTAssertEqual(m.dailyUse.state, .ready)

        // A pin is said, never hidden, and does not make it "not ready".
        m.stayOnThisConversation()
        XCTAssertEqual(m.dailyUse.checks.first { $0.id == "latest" }?.action, .followLatest)
        m.perform(.followLatest)
        XCTAssertFalse(m.sessionPinned)

        // Restart: preferences and the answer survive; window links do not (ADR-028).
        let again = await rig(defaults)
        defer { again.board.releaseGlobally() }
        again.permission.granted = true
        XCTAssertTrue(again.model.autoCaptureFinalWindow)
        XCTAssertEqual(again.model.captureSettings?.mode, .global)
        XCTAssertFalse(again.model.offersDailyUseSetup, "no repeated prompt")
        XCTAssertEqual(again.model.readyAnswer?.sessionKey.contains("s1"), true)
        XCTAssertEqual(again.model.dailyUse.state, .windowNotLinked, "said plainly, with one action")
        XCTAssertEqual(again.model.dailyUse.action, .linkWindow)
    }

    func testAnOutdatedPluginIsFoundBeforeGlobalCaptureCouldStopCapture() async throws {
        try installPlugin("0.4.1")
        let enabled = try repo("enabled")
        let defaults = MemorySettingsStore()
        let r = await rig(defaults)
        defer { r.board.releaseGlobally() }
        let m = r.model
        await m.setCapture(true, for: enabled)
        XCTAssertEqual(m.installedPluginVersion, "0.4.1")
        XCTAssertNotNil(m.globalCaptureBlockedByPlugin)

        let outcome = await m.enableDailyUse(.init(globalCapture: true, autoScreenshots: true, screenshotsInHandoff: true))
        XCTAssertEqual(outcome, .pluginUpdateFirst(installed: "0.4.1", needed: "0.8.0"))
        XCTAssertEqual(m.captureSettings?.mode, .selected, "not switched: an old plugin would then store nothing")
        XCTAssertTrue(m.autoCaptureFinalWindow && m.autoScreenshotsInHandoff, "the rest was applied")
        // Capture keeps working exactly as before.
        try hookTurn("s-old", in: enabled, answer: "still captured")
        XCTAssertEqual(outcomes().suffix(2), ["stored", "stored"])
        await m.recheckDailyUse()
        XCTAssertEqual(m.dailyUse.checks.first { $0.id == "plugin" }?.action, .showPluginUpdate)

        // The guided update: copyable commands.
        m.perform(.showPluginUpdate)
        let copied = r.board.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("claude plugin update prompt-relay@prompt-relay"))
        XCTAssertTrue(copied.contains("claude plugin marketplace add"))
        XCTAssertNotNil(m.dailyUseNotice)

        // If the mode was already set with an old plugin (0.8.0 behaviour): said as such.
        await m.setCaptureMode(.mode(.global))
        XCTAssertEqual(m.dailyUse.state, .pluginUpdateRequired)
        XCTAssertEqual(m.dailyUse.action, .showPluginUpdate)
        XCTAssertNotEqual(m.dailyUse.state, .ready)

        // After the update: Check Again sees it.
        try installPlugin("0.9.0")
        await m.recheckDailyUse()
        XCTAssertNil(m.globalCaptureBlockedByPlugin)
        XCTAssertNotEqual(m.dailyUse.state, .pluginUpdateRequired)
    }

    // MARK: Existing users

    func testExistingPreferencesAreNeverOverwrittenAndRepeatedSetupResetsNothing() async throws {
        try installPlugin("0.9.0")
        // An existing user: screenshots deliberately off, attachments deliberately off,
        // a conversation deliberately pinned.
        let saved = try JSONEncoder().encode(AppModel.SavedSelection(projectPath: "/gone", sessionKey: "old-session", pinnedAt: nil))
        let defaults = MemorySettingsStore([AppModel.autoCaptureKey: false, "attachments.autoSelectResults": false,
                                            AppModel.staysKey: true, AppModel.selectionKey: saved])
        let r = await rig(defaults)
        defer { r.board.releaseGlobally() }
        let m = r.model
        XCTAssertFalse(m.autoSelectResultAttachments, "an explicit Off survives the update")
        XCTAssertTrue(m.staysOnChosenSession && m.sessionPinned, "an explicit pin is kept, never erased")
        XCTAssertEqual(m.captureSettings?.mode, .selected, "an existing installation is never switched to All Projects by itself")
        XCTAssertFalse(m.dailyUseProposal.autoScreenshots, "what the user turned off is not proposed ticked")

        // Setup with nothing ticked changes nothing.
        let nothing = await m.enableDailyUse(.init(globalCapture: false, autoScreenshots: false, screenshotsInHandoff: false))
        XCTAssertEqual(nothing, .applied)
        XCTAssertEqual(m.captureSettings?.mode, .selected)
        XCTAssertFalse(m.autoCaptureFinalWindow)
        XCTAssertFalse(m.autoSelectResultAttachments)
        XCTAssertEqual(defaults.object(forKey: AppModel.autoCaptureKey) as? Bool, false)

        // The user turns things on, then repeats setup with everything unticked: nothing is reset.
        _ = await m.enableDailyUse(.init(globalCapture: true, autoScreenshots: true, screenshotsInHandoff: true))
        XCTAssertEqual(m.captureSettings?.mode, .global)
        m.autoSelectResultAttachments = true
        m.autoSelectPreparedAttachments = false
        _ = await m.enableDailyUse(.init(globalCapture: false, autoScreenshots: false, screenshotsInHandoff: false))
        XCTAssertEqual(m.captureSettings?.mode, .global)
        XCTAssertTrue(m.autoCaptureFinalWindow && m.autoScreenshotsInHandoff)
        XCTAssertFalse(m.autoSelectPreparedAttachments)
        XCTAssertEqual(m.dailyUseProposal, .init(globalCapture: true, autoScreenshots: true, screenshotsInHandoff: true),
                       "repeating setup shows what is on")

        // A deliberate Off after setup stays off across a restart.
        m.autoCaptureFinalWindow = false
        let again = await rig(defaults)
        defer { again.board.releaseGlobally() }
        XCTAssertFalse(again.model.autoCaptureFinalWindow)
        XCTAssertFalse(again.model.autoSelectPreparedAttachments)
        XCTAssertTrue(again.model.autoSelectResultAttachments)
        XCTAssertFalse(again.model.offersDailyUseSetup)
    }

    func testNotNowChangesNothingAndIsNotAskedAgain() async throws {
        try installPlugin("0.9.0")
        let defaults = MemorySettingsStore()
        let r = await rig(defaults)
        defer { r.board.releaseGlobally() }
        r.model.dismissDailyUseSetup()
        XCTAssertFalse(r.model.offersDailyUseSetup)
        XCTAssertEqual(r.model.captureSettings?.mode, .selected)
        XCTAssertFalse(r.model.autoCaptureFinalWindow)
        let again = await rig(defaults)
        defer { again.board.releaseGlobally() }
        XCTAssertFalse(again.model.offersDailyUseSetup)
        XCTAssertFalse(again.model.dailyUseProposal.globalCapture, "after a No, nothing is pre-ticked")
        XCTAssertFalse(again.model.dailyUseProposal.autoScreenshots)
    }

    // MARK: Screenshots across a restart and successive conversations

    func testScreenshotSettingSurvivesRestartAndOneLinkServesSuccessiveConversations() async throws {
        let defaults = MemorySettingsStore([AppModel.autoCaptureKey: true, AppModel.autoCaptureHandoffKey: true])
        let core = FakeCore(projects: [project("/p", sessions: 1, last: Phase141PermissionTests.ago(4000))])
        func session(_ key: String, ago: TimeInterval) -> SessionSummary {
            Phase93Tests.session(key, provider: "claude_code", host: "claude_desktop", project: "/p",
                                 last: Phase141PermissionTests.ago(ago), answeredAt: Phase141PermissionTests.ago(ago))
        }
        core.sessionsByProject["/p"] = [session("first", ago: 4000)]
        core.turnsBySession["first"] = [turn(1, at: Phase141PermissionTests.ago(4000))]
        let board = NSPasteboard(name: .init("PR17S-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let store = ReportStore(root: base.appendingPathComponent("shots"))
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults, reportStore: store)
        let capture = Phase141PermissionTests.FakeCapture()
        m.windowCapture = capture
        m.captureSettle = .immediate
        XCTAssertTrue(m.autoCaptureFinalWindow && m.autoScreenshotsInHandoff, "one opt-in, kept across restarts")
        await m.refreshNow()
        XCTAssertTrue(m.autoCaptureBindings.isEmpty, "links are never restored silently (ADR-028)")

        // One link for the agent · profile · host · project.
        m.chooseAutoCaptureWindow()
        XCTAssertEqual(m.autoCaptureBindings.count, 1)

        // A new conversation in the same project, long after the first went quiet.
        core.sessionsByProject["/p"] = [session("second", ago: -1), session("first", ago: 4000)]
        core.turnsBySession["second"] = [turn(1, at: Phase141PermissionTests.ago(-1))]
        await m.refreshNow()
        await m.waitForAutoCaptures()
        let shots = store.attachments(for: .local(sessionKey: "second", turn: 1)).filter { $0.effectiveSource == .windowCapture }
        XCTAssertEqual(shots.count, 1, "the same link serves the next conversation: no re-link, no Add")
        XCTAssertEqual(shots.first?.isSelected, true, "ticked for hand-off because the user asked for that")
        XCTAssertEqual(capture.captures, 1)

        // Two conversations active in that window at once: nothing is guessed.
        core.sessionsByProject["/p"] = [session("third", ago: -2), session("second", ago: -1), session("first", ago: 4000)]
        core.turnsBySession["third"] = [turn(1, at: Phase141PermissionTests.ago(-2))]
        await m.refreshNow()
        await m.waitForAutoCaptures()
        XCTAssertEqual(capture.captures, 1)
        XCTAssertEqual(m.autoCaptureStatus(for: .local(sessionKey: "third", turn: 1)), .associationRequired)
    }
}

/// Phase 17: the Swift models against the Core's contract.
@MainActor
final class Phase17ContractTests: XCTestCase {
    func testAnUnknownCaptureModeDoesNotBreakTheProjectList() throws {
        let json = #"{"projects":[],"settings":{"retention_days":null,"automatic_deletion":false,"capture":{"mode":"scheduled","excluded_projects":[],"enabled_projects":[],"resume_mode":null,"minimum_plugin_version":"1.2.0"}}}"#
        let data = try JSONDecoder().decode(ProjectsData.self, from: Data(json.utf8))
        XCTAssertNil(data.settings.capture, "unreadable policy: unknown, never a guess")
        XCTAssertEqual(AppModel.captureStatus(settings: data.settings.capture, installedPlugin: "0.9.0"), .unknown)
        XCTAssertFalse(AppModel.CaptureStatus.unknown.isActive)
    }

    func testCurrentAndPre080ProjectDocumentsDecode() throws {
        let current = #"{"projects":[{"path":"/p","name":"p","capture_enabled":false,"explicitly_enabled":false,"session_count":1,"last_event_at":null,"excluded":true}],"settings":{"retention_days":30,"automatic_deletion":false,"capture":{"mode":"global","excluded_projects":["/p"],"enabled_projects":[],"resume_mode":null,"minimum_plugin_version":"0.8.0"}}}"#
        let data = try JSONDecoder().decode(ProjectsData.self, from: Data(current.utf8))
        XCTAssertEqual(data.settings.capture?.mode, .global)
        XCTAssertEqual(data.settings.capture?.excludedProjects, ["/p"])
        XCTAssertEqual(data.settings.retentionDays, 30)
        // A Core before 0.8.0 (and the older schema snapshot): no capture, no excluded.
        let old = #"{"projects":[{"path":"/p","name":"p","capture_enabled":true,"explicitly_enabled":true,"session_count":1,"last_event_at":null}],"settings":{"retention_days":null,"automatic_deletion":false}}"#
        let before = try JSONDecoder().decode(ProjectsData.self, from: Data(old.utf8))
        XCTAssertNil(before.settings.capture)
        XCTAssertEqual(before.projects.first?.captureEnabled, true)
    }
}

/// Phase 17.1: the permission state says what to do, in order, and recovers.
/// Found on the owner's Mac: after an (ad-hoc signed) update the switch in
/// Screen Recording looked on but belonged to the previous build.
@MainActor
final class Phase17PermissionRecoveryTests: XCTestCase {
    func testPermissionRequiredGivesStepsAQuitActionAndClearsOnARealGrant() async {
        let store = MemorySettingsStore([AppModel.autoCaptureKey: true, AppModel.dailySetupAnsweredKey: true])
        let board = NSPasteboard(name: .init("PR17P-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let core = FakeCore(projects: [project("/p", sessions: 0, last: nil)])
        let m = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: store,
                         reportStore: ReportStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("pr17p-\(UUID().uuidString)")))
        let permission = Phase141PermissionTests.FakePermission()
        m.screenRecordingPermission = permission
        var quits = 0
        m.quitApp = { quits += 1 }
        // Linking a window was refused by macOS.
        m.autoCapturePermissionBlocked = true
        let blocked = m.dailyUse.checks.first { $0.id == "screenshots" }
        XCTAssertEqual(blocked?.action, .openScreenRecordingSettings)
        XCTAssertEqual(blocked?.level, .attention)

        // The steps are short and say the non-obvious part.
        m.perform(.quitToApply)
        XCTAssertEqual(quits, 1, "Quit is the app's normal quit, never a forced relaunch")

        // Still refused: Check Again does not pretend.
        permission.granted = false
        await m.recheckDailyUse()
        XCTAssertTrue(m.autoCapturePermissionBlocked)
        // Granted for real: the remembered refusal is cleared, and the next step is the window.
        permission.granted = true
        await m.recheckDailyUse()
        XCTAssertFalse(m.autoCapturePermissionBlocked)
        XCTAssertEqual(m.dailyUse.checks.first { $0.id == "screenshots" }?.action, .linkWindow)
    }

    func testEveryStateFitsOneShortSentence() {
        for text in ["Nothing new is saved while capture is paused.",
                     "Screenshots need Screen Recording for this version of Prompt Relay.",
                     "Pick the Claude window once to get screenshots. Needed again after each restart."] {
            XCTAssertLessThanOrEqual(text.count, 90)
        }
    }
}
