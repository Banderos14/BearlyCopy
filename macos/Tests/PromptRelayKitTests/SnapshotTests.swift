import AppKit
import SwiftUI
import XCTest
@testable import PromptRelayKit

/// Renders the real surfaces offscreen (NSHostingView in a borderless
/// window, so AppKit-backed lists and the text view draw too) and writes PNGs
/// in light and dark appearance. Opt-in: runs only when
/// PROMPT_RELAY_SNAPSHOT_DIR is set; with PROMPT_RELAY_SNAPSHOT_LIVE=1 it uses
/// the real Core and the user's own history (read-only).
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderSurfaces() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("set PROMPT_RELAY_SNAPSHOT_DIR to render screenshots")
        }
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PromptRelaySnapshots-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let live = ProcessInfo.processInfo.environment["PROMPT_RELAY_SNAPSHOT_LIVE"] == "1"
        let model: AppModel
        if live {
            var env = ProcessInfo.processInfo.environment
            env["PROMPT_RELAY_CLI"] = env["PROMPT_RELAY_CLI"] ?? Repo.cli
            let locator = CoreLocator(processEnvironment: env, bundleResourceURL: nil, defaults: { _ in nil })
            model = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(pasteboard: pasteboard),
                             dataDirectory: locator.dataDirectory)
        } else {
            model = AppModel(core: Self.demoCore(), clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
        }
        await model.refreshNow()
        let deadline = Date().addingTimeInterval(10)
        while model.selectedResponseText == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        model.loadDoctor()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await model.copySelectedResponse()

        let actions = SurfaceActions(openWindow: {}, openStatus: {}, quit: {})
        let prefix = live ? "live" : "demo"
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try render(MainWindowView(model: model, actions: actions), size: NSSize(width: 1040, height: 640),
                       appearance: appearance, to: "\(dir)/\(prefix)-window-\(name).png")
            try render(MenuPanelView(model: model, actions: actions), size: NSSize(width: 420, height: 560),
                       appearance: appearance, to: "\(dir)/\(prefix)-menu-\(name).png")
            try render(ConnectionStatusView(model: model), size: NSSize(width: 520, height: 600),
                       appearance: appearance, to: "\(dir)/\(prefix)-status-\(name).png")
        }
        for (expanded, indicator, name) in [(true, false, "expanded"), (false, true, "compact-ready"), (false, false, "resting")] {
            let presentation = NotchPresentation()
            presentation.notchSize = CGSize(width: 185, height: 32)
            presentation.islandWidth = NotchLayout.expandedWidth
            presentation.isExpanded = expanded
            presentation.showsIndicator = indicator
            let interaction = NotchInteraction(scheduler: MainQueueScheduler())
            for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                // First pass lets the island measure its content; the second draws at that height.
                for _ in 0..<2 {
                    let height = expanded ? 32 + presentation.contentHeight + NotchLayout.shadowInset : 32
                    let width = expanded ? NotchLayout.expandedWidth + NotchLayout.shadowInset * 2 : 185 + 2 * NotchLayout.earWidth + 40
                    try render(NotchRootView(model: model, presentation: presentation, interaction: interaction, actions: actions),
                               size: NSSize(width: width, height: height), appearance: appearance,
                               to: "\(dir)/\(prefix)-notch-\(name)-\(theme).png", clear: true)
                }
            }
        }
        let empty = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
        await empty.refreshNow()
        try render(MenuPanelView(model: empty, actions: actions), size: NSSize(width: 420, height: 420),
                   appearance: .aqua, to: "\(dir)/empty-menu-light.png")
        let failing = FakeCore(projects: [])
        failing.projectsResult = .failure(.pythonMissing(searched: ["/opt/homebrew/bin/python3"]))
        let broken = AppModel(core: failing, clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
        await broken.refreshNow()
        try render(MenuPanelView(model: broken, actions: actions), size: NSSize(width: 420, height: 420),
                   appearance: .darkAqua, to: "\(dir)/error-menu-dark.png")
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to path: String,
                                 clear: Bool = false) throws {
        // The notch is drawn over a mid-grey "desktop" so its shape is visible.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(clear ? Color.gray.opacity(0.5) : Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        window.close()
    }

    static func demoCore() -> FakeCore {
        let core = FakeCore(projects: [project("/Users/me/code/prompt-relay", sessions: 2, last: "2026-10-29T16:13:51.000000Z"),
                                       project("/Users/me/code/website", sessions: 1, last: "2026-10-28T09:00:00.000000Z")])
        core.sessionsByProject["/Users/me/code/prompt-relay"] = [
            sessionSummary("1aac4f95-88cc-4017-aef3-8b6e268c9cb7", project: "/Users/me/code/prompt-relay", last: "2026-10-29T16:13:51.000000Z"),
            sessionSummary("d8365e27-9b63-41ae-b93a-008c5687f834", project: "/Users/me/code/prompt-relay", last: "2026-10-29T12:43:18.000000Z"),
        ]
        let answer = """
        Готово. Я добавил экран состояния и кнопку копирования.

        ```swift
        try clipboard.copy(text)
        ```

        Тесты: 38 пройдено, 0 ошибок. 🚀
        """
        core.turnsBySession["1aac4f95-88cc-4017-aef3-8b6e268c9cb7"] = [
            turn(1, preview: "Привет из плагина 🚀", chars: 19),
            turn(2, status: "api_error", preview: nil),
            turn(3, preview: String(answer.prefix(200)), chars: answer.unicodeScalars.count),
        ]
        core.showResult = { key, index in
            .success(CoreResult(data: ShowData(session: try! core.session(key),
                                               turn: turn(index, preview: String(answer.prefix(200)), chars: answer.unicodeScalars.count, text: answer)),
                                warnings: []))
        }
        return core
    }
}
