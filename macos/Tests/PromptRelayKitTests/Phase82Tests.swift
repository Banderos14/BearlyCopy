import AppKit
import SwiftUI
import Testing
@testable import PromptRelayKit

@Suite(.serialized)
@MainActor
struct Phase82Tests {
    private func command(_ text: String?, kind: String = "test", exit: Int = 0, withheld: String? = nil) throws -> ObservedCommand {
        var fields: [String: Any] = ["at": "2026-11-03T10:00:00Z", "kind": kind, "exit_code": exit,
                                     "outcome": exit == 0 ? "ok" : "failed", "compound": false,
                                     "background": false, "after_stop": false]
        fields["command"] = text; fields["command_withheld"] = withheld
        return try JSONDecoder().decode(ObservedCommand.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func diagnosticFactsAndTaskExcerpt() throws {
        let noMatch = try command("grep missing file", kind: "shell", exit: 1)
        let failed = try command("swift build", kind: "build", exit: 1)
        let passed = try command("swift test")
        let hidden = try command("secret", withheld: "sensitive")
        #expect(!CommandFilter.failed.includes(noMatch))
        #expect(CommandFilter.failed.includes(failed))
        #expect(CommandFilter.builds.includes(failed))
        #expect(CommandFilter.tests.includes(passed))
        #expect(CommandDiagnostics.safeText(hidden) == nil)
        #expect(CommandDiagnostics.output(passed) == "Not captured")
        #expect(CommandDiagnostics.summary([noMatch, failed, passed]).contains("1 failed"))
        #expect(TaskExcerpt.text("# PROMPT RELAY — Phase 8\n\nFix Clipboard height") == "Fix Clipboard height")
        #expect(TaskExcerpt.text("# Title") == "# Title")
        #expect(TaskExcerpt.text("Introduction\n**Цель:** исправить высоту\nDetails").hasPrefix("**Цель:**"))
    }

    @Test func exactPreviewAndPersistentTransfer() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelayTests.p82.snapshot.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        let board = NSPasteboard(name: .init(suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { board.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: root) }
        let model = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        if let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_P82_RENDERS"] {
            model.route = .activity
            let commands = IslandHost(model: model, maxContentHeight: 341)
            try commands.png("\(dir)/commands-341.png")
            commands.close(); model.route = .home
        }
        let settings = NotchSettings(defaults: defaults)
        settings.animation = .reduced; settings.mascotEnabled = false
        let clock = ManualScheduler()
        let controller = NotchController(model: model, settings: settings, actions: SurfaceActions(quit: {}),
                                         screens: FakeScreens([builtInScreen()]), scheduler: clock,
                                         center: NotificationCenter(), workspaceCenter: NotificationCenter(),
                                         makeHotKey: { nil }, neighbors: FakeNeighbors(), pointerEvents: FakePointerEvents())
        controller.start()
        defer { controller.stop() }
        for route in [AppModel.IslandRoute.settings, .clipboard, .history] {
            controller.interaction.pointerEntered(); clock.advance(0.2)
            controller.interaction.focus()
            try await Task.sleep(nanoseconds: 30_000_000)
            model.navigate(to: route); model.goBack()
            controller.interaction.pointerExited(); clock.advance(0.1)
            #expect(controller.interaction.phase == .compact)
        }
        _ = model.importReport(text: "Original **answer**", task: "Original request", projectPath: "/a", sessionLabel: nil)
        let ref = try #require(model.currentRef)
        let file = root.appendingPathComponent("notes.md")
        try Data("# Notes".utf8).write(to: file)
        let store = try #require(model.reportStore)
        try store.addFile(from: file, to: ref, source: .you, displayPath: "notes.md")
        model.attachmentsVersion += 1
        let attachment = try #require(model.attachments(for: ref).first)
        await model.openPackPreview()
        guard case .ready(let snapshot)? = model.packPreview else { Issue.record("Preview missing"); return }
        if let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_P82_RENDERS"] {
            let preview = IslandHost(model: model, maxContentHeight: 448)
            try preview.png("\(dir)/preview-448.png"); preview.close()
        }
        try ClipboardService(pasteboard: board).copy("sentinel")
        model.setSelected(attachment, false)
        await model.copyPreviewedPack()
        #expect(board.string(forType: .string) == "sentinel", "Never silently rebuild a changed preview")
        model.setSelected(attachment, true)
        await model.copyPreviewedPack()
        #expect(board.string(forType: .string) == snapshot.text)
        #expect(model.activeHandoff?.text == snapshot.text)
        controller.interaction.pointerEntered(); clock.advance(0.2)
        controller.interaction.focus(); controller.interaction.pointerExited(); clock.advance(0.1)
        #expect(model.activeHandoff?.text == snapshot.text)
        controller.interaction.pointerEntered(); clock.advance(0.2)
        #expect(model.activeHandoff?.ref == ref)
        _ = model.importReport(text: "Another answer", task: "Other task", projectPath: "/a", sessionLabel: nil)
        #expect(model.activeHandoff == nil)
        model.open(ref)
        #expect(model.activeHandoff?.text == snapshot.text)
        model.copyObservedCommand(try command("private", withheld: "sensitive"))
        #expect(board.string(forType: .string) == snapshot.text)
        model.copyObservedCommand(try command("swift test"))
        #expect(board.string(forType: .string) == "swift test")
    }

    @Test func pointerLifecycle() {
        let clock = ManualScheduler()
        let interaction = NotchInteraction(scheduler: clock)
        interaction.setAvailable(true)
        for _ in 0..<3 {
            interaction.pointerEntered(); clock.advance(0.2)
            interaction.focus() // Settings/Clipboard/History, then Back keeps focus.
            interaction.pointerExited(); clock.advance(0.1)
            #expect(interaction.phase == .compact)
        }
        interaction.pointerEntered(); clock.advance(0.2)
        interaction.focus(); interaction.isDragging = true
        interaction.pointerExited(); clock.advance(1)
        #expect(interaction.phase.isExpanded)
        interaction.isDragging = false; clock.advance(0.1)
        #expect(interaction.phase == .compact)
        interaction.pointerEntered(); clock.advance(0.2)
        interaction.isPinned = true; interaction.pointerExited(); clock.advance(1)
        #expect(interaction.phase.isExpanded)
        interaction.isPinned = false; interaction.focus(); clock.advance(0.1)
        #expect(interaction.phase == .compact, "Restoring focus after a picker must not cancel pointer exit")
        interaction.toggle() // Keyboard-only opening; no pointer entered.
        interaction.isPinned = true; interaction.isPinned = false; interaction.focus()
        clock.advance(1)
        #expect(interaction.phase == .expanded(focused: true), "Keyboard-only navigation remains available")
    }

    @Test func clipboardAndDynamicHelp() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelayTests.p82.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        let board = NSPasteboard(name: .init(suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { board.releaseGlobally(); removeTestDefaults(suite); try? FileManager.default.removeItem(at: root) }
        let model = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let history = ClipboardImageHistory(folder: root.appendingPathComponent("images"), pasteboard: board)
        history.setEnabled(true)
        defer { history.setEnabled(false) }
        for color in [NSColor.red, .green, .blue, .yellow, .purple] {
            board.clearContents(); board.setData(TypedAttachmentTests.png(color), forType: .png); history.poll()
        }
        model.clipboardImages = history
        #expect(history.items.count == 5)
        for i in 0..<5 {
            _ = model.importReport(text: "Answer \(i)", task: "Task", projectPath: "/a", sessionLabel: nil)
            await model.copySelectedResponse()
        }
        model.route = .clipboard
        let host = IslandHost(model: model, maxContentHeight: 448)
        defer { host.close() }
        model.clipboardTab = .images; host.settle()
        let directHeight = host.height
        for tab in [AppModel.ClipboardTab.text, .images, .text, .images] {
            // Reproduce a focused/hovered segmented control while changing tabs.
            host.tips.show(UUID(), text: "Your recent copied text and images", anchor: .zero)
            host.settle()
            model.clipboardTab = tab; host.settle()
            if tab == .images { #expect(abs(host.height - directHeight) < 1) }
        }
        if let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_P82_RENDERS"] {
            try host.png("\(dir)/clipboard-images-after-tabs.png")
        }
        let thumbs = try history.items.map { try #require(host.presentation.layoutFrames["clipboard.thumb.\($0.id)"]) }
        for (i, rect) in thumbs.enumerated() {
            for other in thumbs.dropFirst(i + 1) { #expect(!rect.intersects(other)) }
        }
        model.route = .home
        for height: CGFloat in [268, 341, 448] {
            for surface in [NotchPresentation.Surface.expanded, .peek] {
                let island = IslandHost(model: model, surface: surface, maxContentHeight: height)
                defer { island.close() }
                let base = island.height
                let id = surface == .peek ? "peek.actions" : "home.actions"
                let footer = try #require(island.presentation.layoutFrames[id])
                for reduced in [false, true] {
                    island.presentation.reduceMotion = reduced
                    for text in ["Copy the original answer", String(repeating: "Explain this action clearly. ", count: 8), "Customize Prompt Relay"] {
                        island.tips.show(UUID(), text: text, anchor: footer); island.settle()
                        let help = try #require(island.presentation.layoutFrames["tooltip"])
                        #expect(island.height > base)
                        #expect(island.height <= base + 34)
                        #expect(island.presentation.layoutFrames[id] == footer)
                        #expect(!help.intersects(footer) && island.contains(help))
                        #expect(help.height <= 28)
                        if !reduced, let dir = ProcessInfo.processInfo.environment["PROMPT_RELAY_P82_RENDERS"] {
                            let name = surface == .peek ? "peek" : "details"
                            let lines = help.height > 18 ? "two" : "one"
                            try island.png("\(dir)/\(name)-\(Int(height))-\(lines).png")
                        }
                    }
                    island.tips.hideAll(); island.settle()
                    #expect(island.height == base)
                }
            }
        }
    }
}
