import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 15.2: real-user audit fixes. See docs/PHASE15_2_PRODUCT_AUDIT.md.
@MainActor
@Suite struct Phase152Tests {
    let harness = Phase14CaptureTests()

    // MARK: R1 — a failed capture drops a link only when the window is gone

    @Test func aMinimizedOrHiddenWindowKeepsItsLinkAndIsNeverReplaced() async throws {
        let claude = Phase14CaptureTests.session("claude", last: Phase14CaptureTests.ago(400))
        let w = await harness.world([claude]); defer { harness.cleanup(w) }
        w.model.selectSession("claude"); w.model.chooseAutoCaptureWindow()
        w.capture.failing["h1"] = .failed
        w.capture.offscreen.insert("h1")                                  // minimized / another Space
        await harness.finish(w, claude, at: Phase14CaptureTests.ago(5), turns: 2)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "claude", turn: 2)) == .windowNotCapturable)
        #expect(w.model.autoCaptureBindings.map(\.window.handle) == ["h1"], "the link is kept")
        #expect(w.capture.forgotten.isEmpty)
        #expect(w.model.attachments(for: .local(sessionKey: "claude", turn: 2)).isEmpty, "no other window is captured instead")
        // Restored: the next answer is captured through the same link.
        w.capture.failing["h1"] = nil
        w.capture.offscreen.remove("h1")
        await harness.finish(w, claude, at: Phase14CaptureTests.ago(2), turns: 3)
        #expect(w.model.attachments(for: .local(sessionKey: "claude", turn: 3)).count == 1)
    }

    @Test func anOnScreenWindowWithATransientErrorKeepsItsLink() async throws {
        let claude = Phase14CaptureTests.session("claude", last: Phase14CaptureTests.ago(400))
        let w = await harness.world([claude]); defer { harness.cleanup(w) }
        w.model.selectSession("claude"); w.model.chooseAutoCaptureWindow()
        w.capture.failing["h1"] = .noImage
        await harness.finish(w, claude, at: Phase14CaptureTests.ago(5), turns: 2)
        #expect(w.model.autoCaptureStatus(for: .local(sessionKey: "claude", turn: 2)) == .failed)
        #expect(w.model.autoCaptureBindings.count == 1)
    }

    @Test func anUnknownPresenceNeverCountsAsClosed() async throws {
        // Phase141's FakeCapture reports `.unknown` by default (no window number).
        let fake = Phase141PermissionTests.FakeCapture()
        fake.captureResult = .failure(WindowCaptureError.failed)
        let claude = Phase14CaptureTests.session("claude", last: Phase14CaptureTests.ago(400))
        let w = await harness.world([claude]); defer { harness.cleanup(w) }
        w.model.windowCapture = fake
        w.model.selectSession("claude"); w.model.chooseAutoCaptureWindow()
        let binding = try #require(w.model.autoCaptureBindings.first)
        #expect(w.model.afterCaptureFailure(.failed, binding: binding) == .windowNotCapturable)
        #expect(w.model.autoCaptureBindings.count == 1)
        #expect(w.model.afterCaptureFailure(.noSource, binding: binding) == .windowUnavailable, "no source held: link unusable")
        #expect(w.model.autoCaptureBindings.isEmpty)
    }

    @Test func windowPresenceIsReadFromTheWindowListOnly() {
        let on: [[String: Any]] = [[kCGWindowNumber as String: NSNumber(value: 42), kCGWindowIsOnscreen as String: NSNumber(value: true)]]
        let off: [[String: Any]] = [[kCGWindowNumber as String: NSNumber(value: 42)]]
        #expect(WindowCapture.presence(windowInfo: on, windowID: 42) == .present(onScreen: true))
        #expect(WindowCapture.presence(windowInfo: off, windowID: 42) == .present(onScreen: false), "minimized: listed, not on screen")
        #expect(WindowCapture.presence(windowInfo: [], windowID: 42) == .gone)
        #expect(WindowCapture.presence(windowInfo: nil, windowID: 42) == .unknown)
        #expect(WindowCapture.presence(windowInfo: on, windowID: 7) == .gone, "another window's entry is not this one")
    }

    // MARK: Open Screen Recording Settings is always reachable

    @Test func everyNoScreenshotStateOffersScreenRecordingSettings() {
        for status: AutoCaptureStatus in [.windowNotBound, .windowUnavailable, .windowNotCapturable, .failed,
                                          .associationRequired, .permissionRequired, .restartRequired] {
            #expect(status.offersSettingsShortcut || status.offersPermissionRecovery, "\(status)")
        }
        for status: AutoCaptureStatus in [.pending, .captured, .superseded] { #expect(!status.offersSettingsShortcut) }
        // Link Window / Capture Now stay offered where a link can help.
        for status: AutoCaptureStatus in [.windowNotBound, .windowUnavailable, .windowNotCapturable, .failed] { #expect(status.offersLink) }
    }

    @Test func windowNotLinkedExplainsLinkingAndCaptureNow() throws {
        let detail = try #require(AutoCaptureStatus.windowNotBound.detail)
        #expect(detail.contains("Links end when BearlyCopy quits"))
        #expect(detail.contains("Capture Now"))
        #expect(AutoCaptureStatus.windowUnavailable.title == "Window closed")
        #expect(AutoCaptureStatus.windowNotCapturable.detail?.contains("link is kept") == true)
    }

    @Test func theSettingsLinkOpensScreenRecordingNeverAudioOnly() {
        // Verified on this Mac (2026-11-08): in SecurityPrivacyExtension's search
        // terms, Privacy_ScreenCapture = "Allow applications to record your
        // screen"; Privacy_AudioCapture = system audio only.
        let urls = LiveScreenRecordingPermission.settingsURLs
        #expect(urls.first?.hasSuffix("?Privacy_ScreenCapture") == true)
        #expect(!urls.contains { $0.contains("AudioCapture") || $0.contains("Microphone") })
    }

    // MARK: Plugin version next to the app's

    @Test func pluginVersionNotesAreActionable() throws {
        #expect(AppBuild.pluginNote(plugin: "0.6.0", app: "0.6.0") == nil)
        let older = try #require(AppBuild.pluginNote(plugin: "0.4.1", app: "0.6.0"))
        #expect(older.contains("compatible") && older.contains("claude plugin update prompt-relay@prompt-relay"))
        let tooOld = try #require(AppBuild.pluginNote(plugin: "0.3.0", app: "0.6.0"))
        #expect(tooOld.contains("missing newer signals"))
        #expect(AppBuild.pluginNote(plugin: "0.7.0", app: "0.6.0")?.contains("Newer than this app") == true)
        #expect(AppBuild.pluginNote(plugin: nil, app: "0.6.0") == nil)
        #expect(AppBuild.pluginNote(plugin: "dev", app: "0.6.0") == nil, "unparseable: say nothing rather than guess")
    }

    @Test func theDebugPermissionHintNamesTheRebuildPitfall() {
        #expect(AutoCaptureStatus.debugBuildPermissionHint.contains("“BearlyCopy Dev”"), "the Debug app's CFBundleDisplayName")
        #expect(AutoCaptureStatus.debugBuildPermissionHint.contains("turn it off and on again"))
    }
}
