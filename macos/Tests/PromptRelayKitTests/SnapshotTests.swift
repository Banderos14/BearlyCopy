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
            let store = ReportStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("pr-snap-\(UUID().uuidString)"))
            model = AppModel(core: Self.demoCore(), clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil,
                             reportStore: store)
        }
        await model.refreshNow()
        if !live {
            model.importReport(text: ReportFixture.report(sections: 2), task: "Redesign the notch and send screenshots",
                               projectPath: "/Users/me/code/a-project-with-a-really-quite-long-name-for-testing", sessionLabel: "cse_01")
            model.openProject("/Users/me/code/prompt-relay")
        }
        let deadline = Date().addingTimeInterval(10)
        while model.selectedResponseText == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        model.loadDoctor()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await model.copySelectedResponse()
        if !live { await model.copyResponse(sessionKey: "1aac4f95-88cc-4017-aef3-8b6e268c9cb7", turn: 1) }

        let actions = SurfaceActions(quit: {})
        let prefix = live ? "live" : "demo"
        let settings = NotchSettings(defaults: TestDefaults.named("PromptRelaySnapshots-\(UUID().uuidString)")!)

        // Resting (with Relay the bear), with a new answer, and Quick Peek.
        for (name, expanded, indicator) in [("resting", false, false), ("resting-new", false, true), ("peek", true, false)] {
            let p = presentation(expanded: expanded, surface: .peek, indicator: indicator)
            let interaction = NotchInteraction(scheduler: MainQueueScheduler())
            for (background, theme) in [(Color(white: 0.86), "light"), (Color(white: 0.22), "dark")] {
                for _ in 0..<2 {
                    let size = expanded ? NSSize(width: NotchLayout.peekWidth, height: 32 + p.contentHeight)
                                        : NSSize(width: 185 + 2 * NotchLayout.earWidth, height: 32)
                    try render(NotchRootView(model: model, presentation: p, interaction: interaction, actions: actions, settings: settings),
                               size: size, background: background, to: "\(dir)/\(prefix)-\(name)-\(theme).png")
                }
            }
        }
        // Every view of the expanded island, at its measured height.
        for route in AppModel.IslandRoute.allCases {
            model.route = .home
            model.navigate(to: route)
            try await Task.sleep(nanoseconds: 500_000_000)
            try renderIsland(model, actions: actions, settings: settings, to: "\(dir)/\(prefix)-island-\(route.rawValue).png")
        }
        model.route = .home
        if !live, let report = model.imports.first, let store = model.reportStore {
            model.selectImport(report.id)
            try renderIsland(model, actions: actions, settings: settings, to: "\(dir)/demo-island-home-import.png")
            // Phase 5: a document, an image and a mockup with partly captured states.
            let src = store.root.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let md = src.appendingPathComponent("PHASE5_PROPOSAL.md")
            try Data("# Phase 5\n".utf8).write(to: md)
            try store.addFile(from: md, to: report.ref, source: .claude, displayPath: "docs/PHASE5_PROPOSAL.md")
            let png = src.appendingPathComponent("Screenshot 14.03.png")
            try TypedAttachmentTests.png(.systemTeal).write(to: png)
            try store.addFile(from: png, to: report.ref, source: .clipboard)
            var mockup = try store.addMaterial(ReportMaterial(
                id: "m", reportKey: report.ref.key, kind: .mockup, title: "Prompt Relay Phase 5 Island",
                url: "https://claude.ai/artifact/x", audience: "owner", sourcePath: "…/scratchpad/phase5-island.html", version: nil,
                addedAt: "t", provenance: "Published by Claude in this turn (Artifact tool)", selected: true,
                states: ["Resting", "Quick Peek", "Details", "Project and session", "Observed work", "Transfer", "Clipboard images"]
                    .map { MockupState(id: AppModel.slug($0), title: $0, summary: nil, interactive: [], status: .namedOnly,
                                       attachmentID: nil, failure: nil, selected: true) }))
            for (i, color) in [NSColor.systemTeal, .systemPurple, .systemOrange].enumerated() {
                let shot = src.appendingPathComponent("state-\(i).png")
                try TypedAttachmentTests.png(color).write(to: shot)
                mockup = try store.setStateImage(from: shot, mockupID: mockup.id, stateID: mockup.states[i].id)
            }
            model.openMockup(mockup)
            try await Task.sleep(nanoseconds: 300_000_000)
            try renderIsland(model, actions: actions, settings: settings, to: "\(dir)/demo-island-mockup-states.png")
            model.route = .home
            try await Task.sleep(nanoseconds: 300_000_000)
            try renderIsland(model, actions: actions, settings: settings, to: "\(dir)/demo-island-home-attachments.png")
            let peek = presentation(expanded: true, surface: .peek)
            try render(NotchRootView(model: model, presentation: peek, interaction: NotchInteraction(scheduler: MainQueueScheduler()),
                                     actions: actions, settings: settings),
                       size: NSSize(width: NotchLayout.peekWidth, height: 32 + peek.contentHeight), background: Color(white: 0.22),
                       to: "\(dir)/demo-peek-attachments.png")
        }
        let empty = AppModel(core: FakeCore(projects: []), clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
        await empty.refreshNow()
        try renderIsland(empty, actions: actions, to: "\(dir)/empty-island.png")
        let failing = FakeCore(projects: [])
        failing.projectsResult = .failure(.pythonMissing(searched: ["/opt/homebrew/bin/python3"]))
        let broken = AppModel(core: failing, clipboard: ClipboardService(pasteboard: pasteboard), dataDirectory: nil)
        await broken.refreshNow()
        try renderIsland(broken, actions: actions, to: "\(dir)/error-island.png")
    }

    private func presentation(expanded: Bool, surface: NotchPresentation.Surface, indicator: Bool = false) -> NotchPresentation {
        let p = NotchPresentation()
        p.notchSize = CGSize(width: 185, height: 32)
        p.islandWidth = surface == .peek ? NotchLayout.peekWidth : NotchLayout.expandedWidth
        p.isExpanded = expanded
        p.surface = surface
        p.showsIndicator = indicator
        p.showsMascot = true
        // A 14-inch MacBook: 38 % of 982 pt, minus the band.
        p.maxContentHeight = (982 * NotchLayout.maxScreenShare).rounded() - 32
        return p
    }

    private func renderIsland(_ model: AppModel, actions: SurfaceActions, settings: NotchSettings? = nil, to path: String) throws {
        let p = presentation(expanded: true, surface: .expanded)
        let interaction = NotchInteraction(scheduler: MainQueueScheduler())
        // First passes let the island measure its content; the last draws at that height.
        for _ in 0..<3 {
            try render(NotchRootView(model: model, presentation: p, interaction: interaction, actions: actions, settings: settings),
                       size: NSSize(width: NotchLayout.expandedWidth, height: 32 + p.contentHeight),
                       background: Color(white: 0.86), to: path)
        }
    }

    /// Draws over a plain "desktop" color so the island's edges are visible.
    private func render<V: View>(_ view: V, size: NSSize, background: Color, to path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(background))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        window.close()
    }

    static func demoCore() -> FakeCore {
        let core = FakeCore(projects: [project("/Users/me/code/prompt-relay", sessions: 2, last: "2026-10-29T16:13:51.000000Z"),
                                       project("/Users/me/code/website", sessions: 1, last: "2026-10-28T09:00:00.000000Z", enabled: false),
                                       project("/Users/me/code/a-project-with-a-really-quite-long-name-for-testing", sessions: 0, last: nil)])
        core.sessionsByProject["/Users/me/code/prompt-relay"] = [
            sessionSummary("1aac4f95-88cc-4017-aef3-8b6e268c9cb7", project: "/Users/me/code/prompt-relay", last: "2026-10-29T16:13:51.000000Z", lastTurn: 3),
            sessionSummary("d8365e27-9b63-41ae-b93a-008c5687f834", project: "/Users/me/code/prompt-relay", last: "2026-10-29T12:43:18.000000Z"),
        ]
        let answer = ReportFixture.report(sections: 8)
        core.turnsBySession["1aac4f95-88cc-4017-aef3-8b6e268c9cb7"] = [
            turn(1, preview: "Привет из плагина 🚀", chars: 19),
            turn(2, status: "api_error", preview: nil),
            turn(3, preview: String(answer.prefix(200)), chars: answer.unicodeScalars.count,
                 request: "Перепиши интерфейс чёлки: единый островок, Copy Response, Review Pack, история. Проверь тесты и пришли отчёт."),
        ]
        core.showResult = { key, index in
            .success(CoreResult(data: ShowData(session: try! core.session(key),
                                               turn: turn(index, preview: String(answer.prefix(200)), chars: answer.unicodeScalars.count, text: answer)),
                                warnings: []))
        }
        return core
    }
}
