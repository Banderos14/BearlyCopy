import AppKit
import XCTest
@testable import PromptRelayKit

/// Phase 17: every stored setting, from the Swift sources — its default on a
/// fresh install, a change, and the value after a "restart" (a new object
/// over the same in-memory store). No real preferences are read or written.
/// The inventory with what each setting does is in docs/PHASE17.md.
@MainActor
final class Phase17SettingsTests: XCTestCase {
    private func model(_ store: MemorySettingsStore) -> AppModel {
        let board = NSPasteboard(name: .init("PR17Set-\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        return AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: store)
    }

    func testIslandSettingsDefaultsChangesAndRestart() {
        let store = MemorySettingsStore()
        let fresh = NotchSettings(defaults: store)
        // Defaults of a new installation.
        XCTAssertTrue(fresh.notchEnabled)
        XCTAssertFalse(fresh.notifyWhenReady)
        XCTAssertFalse(fresh.notifyNeedsInput)
        XCTAssertEqual(fresh.animation, .system, "Motion follows the system's Reduce Motion")
        XCTAssertTrue(fresh.yieldToOtherNotchApps)
        XCTAssertTrue(fresh.mascotEnabled)
        XCTAssertEqual(fresh.theme, .warmCocoa)
        XCTAssertEqual(fresh.relayMotion, .subtle)
        XCTAssertTrue(fresh.relayIdle && fresh.relayFollowsPointer && fresh.relayWithoutNotch)
        XCTAssertEqual(fresh.display, .automatic)
        XCTAssertTrue(fresh.enabledShortcuts.isEmpty, "global shortcuts are off until chosen")
        XCTAssertEqual(fresh.shortcutModifiers, .controlOptionCommand)

        // Every control changed away from its default.
        fresh.notchEnabled = false
        fresh.notifyWhenReady = true
        fresh.notifyNeedsInput = true
        fresh.animation = .reduced
        fresh.yieldToOtherNotchApps = false
        fresh.mascotEnabled = false
        let otherTheme = IslandTheme.allCases.first { $0 != .warmCocoa }!
        fresh.theme = otherTheme
        fresh.relayMotion = .off
        fresh.relayIdle = false
        fresh.relayFollowsPointer = false
        fresh.relayWithoutNotch = false
        fresh.display = .display(42)
        fresh.setShortcut(.openInbox, enabled: true)
        let otherModifiers = ShortcutModifiers.allCases.first { $0 != .controlOptionCommand }!
        fresh.shortcutModifiers = otherModifiers

        let restarted = NotchSettings(defaults: store)
        XCTAssertFalse(restarted.notchEnabled)
        XCTAssertTrue(restarted.notifyWhenReady && restarted.notifyNeedsInput)
        XCTAssertEqual(restarted.animation, .reduced)
        XCTAssertFalse(restarted.yieldToOtherNotchApps)
        XCTAssertFalse(restarted.mascotEnabled)
        XCTAssertEqual(restarted.theme, otherTheme)
        XCTAssertEqual(restarted.relayMotion, .off)
        XCTAssertFalse(restarted.relayIdle || restarted.relayFollowsPointer || restarted.relayWithoutNotch)
        XCTAssertEqual(restarted.display, .display(42))
        XCTAssertEqual(restarted.enabledShortcuts, [.openInbox])
        XCTAssertEqual(restarted.shortcutModifiers, otherModifiers)

        // Back to automatic removes the stored display.
        restarted.display = .automatic
        XCTAssertEqual(NotchSettings(defaults: store).display, .automatic)
    }

    func testBehaviourAndHandoffSettingsDefaultsChangesAndRestart() {
        let store = MemorySettingsStore()
        let fresh = model(store)
        XCTAssertFalse(fresh.staysOnChosenSession)
        XCTAssertTrue(fresh.followsLatest)
        XCTAssertTrue(fresh.autoSelectResultAttachments)
        XCTAssertTrue(fresh.autoSelectPreparedAttachments)
        XCTAssertFalse(fresh.autoCaptureFinalWindow)
        XCTAssertFalse(fresh.autoScreenshotsInHandoff)
        XCTAssertFalse(fresh.clipboardHistoryEnabled)
        XCTAssertEqual(fresh.workspaceMode, .byProject)
        XCTAssertFalse(fresh.dailySetupAnswered)

        fresh.staysOnChosenSession = true
        fresh.autoSelectResultAttachments = false
        fresh.autoSelectPreparedAttachments = false
        fresh.autoCaptureFinalWindow = true
        fresh.autoScreenshotsInHandoff = true
        fresh.workspaceMode = .byAgent
        fresh.setProfileLabel(ProfileKey(provider: .claudeCode, profileID: "cc-default"), "Personal")
        fresh.dismissDailyUseSetup()

        let restarted = model(store)
        XCTAssertTrue(restarted.staysOnChosenSession)
        XCTAssertFalse(restarted.autoSelectResultAttachments)
        XCTAssertFalse(restarted.autoSelectPreparedAttachments)
        XCTAssertTrue(restarted.autoCaptureFinalWindow)
        XCTAssertTrue(restarted.autoScreenshotsInHandoff)
        XCTAssertEqual(restarted.workspaceMode, .byAgent)
        XCTAssertEqual(restarted.profileLabels.values.sorted(), ["Personal"])
        XCTAssertTrue(restarted.dailySetupAnswered)
        XCTAssertTrue(restarted.autoCaptureBindings.isEmpty, "window links are never stored (ADR-028)")

        // Interaction: turning screenshots off drops the links; the hand-off
        // preference is remembered for when it is turned on again.
        restarted.autoCaptureBindings.append(WindowBinding(key: CaptureSourceKey(provider: .claudeCode, profileID: "p", host: .claudeDesktop, projectPath: "/p"),
                                                           sessionKey: nil, window: PickedWindow(handle: "h", label: "w"), createdAt: Date()))
        restarted.autoCaptureFinalWindow = false
        XCTAssertTrue(restarted.autoCaptureBindings.isEmpty)
        XCTAssertTrue(restarted.autoScreenshotsInHandoff)
        XCTAssertNil(restarted.autoCaptureStatus(for: .local(sessionKey: "s", turn: 1)), "off: no screenshot status is shown")

        // Interaction: Follow Latest wins over Stay — it turns the pin off, visibly.
        restarted.followLatestNow()
        XCTAssertFalse(restarted.staysOnChosenSession)
        XCTAssertFalse(model(store).staysOnChosenSession)
    }

    /// Every toggle has words: the titles and explanations shown in Settings
    /// name what happens, and the privacy-relevant ones say where data stays.
    func testSettingsCopySaysWhatHappens() throws {
        let source = try String(contentsOfFile: Repo.root.appendingPathComponent("macos/Sources/PromptRelayKit/Notch/IslandSettingsView.swift").path, encoding: .utf8)
        for title in ["Open on hover", "Stay on the conversation I open", "Attach result files automatically", "Select attached files for handoff",
                      "Automatic final screenshots", "Include auto screenshots in handoff", "Keep the last 10 copied images",
                      "Notify when an answer is ready", "Notify when an agent needs input", "Open at login", "Daily Use"] {
            XCTAssertTrue(source.contains("\"\(title)\""), "missing control: \(title)")
        }
        XCTAssertTrue(source.contains("never saved, never copied, never sent"), "screenshots: where the data stays")
        XCTAssertTrue(source.contains("Text from other apps is never read"), "clipboard: what is not read")
        // Each toggle(...) call carries a detail sentence.
        let toggles = source.components(separatedBy: "toggle(\"").dropFirst()
        XCTAssertGreaterThan(toggles.count, 12)
        for call in toggles { XCTAssertTrue(call.prefix(200).contains("detail:"), "a toggle without an explanation: \(call.prefix(40))") }
    }
}
