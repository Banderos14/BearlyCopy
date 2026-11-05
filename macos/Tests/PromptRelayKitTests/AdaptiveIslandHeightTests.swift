import AppKit
import SwiftUI
import Testing
@testable import PromptRelayKit

@Suite(.serialized)
@MainActor
struct AdaptiveIslandHeightTests {
    /// The pre-change layout path, without the adaptive viewport. Compare
    /// actual current content, not historical screenshots with older padding.
    private func ordinaryPeekHeight(model: AppModel, presentation: NotchPresentation) -> CGFloat {
        var measured: CGFloat = 0
        let size = CGSize(width: presentation.islandWidth, height: 600)
        let host = NSHostingView(rootView:
            HeightBudget(maxHeight: presentation.notchSize.height + presentation.maxContentHeight) {
                PeekContent(model: model, presentation: presentation,
                            interaction: NotchInteraction(scheduler: MainQueueScheduler()))
            }
            .frame(width: size.width)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured = $0 }
            .frame(width: size.width, height: size.height, alignment: .top))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return measured.rounded(.up)
    }

    @Test func severalBlocksAndScreenLimit() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelayTests.adaptiveStack.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: .init(suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            board.releaseGlobally(); removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let history = ClipboardImageHistory(folder: root.appendingPathComponent("images"), pasteboard: board)
        model.clipboardImages = history
        defer { history.setEnabled(false) }
        _ = model.importReport(text: String(repeating: "Answer. ", count: 100), task: "Task", projectPath: "/a", sessionLabel: nil)
        let ref = try #require(model.currentRef)
        let store = try #require(model.reportStore)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("report.md")
        try Data("Report".utf8).write(to: file)
        try store.addFile(from: file, to: ref, source: .you, displayPath: "report.md")
        model.attachmentsVersion += 1
        await model.copySelectedContext()
        #expect(model.activeHandoff != nil)
        model.clipboardNoticeVisible = true
        for height: CGFloat in [268, 341, 448] {
            for limited in [false, true] {
                model.finishCopy(.failed("Temporary copy warning. Please try again."))
                let island = IslandHost(model: model, maxContentHeight: height,
                                        availableHeight: limited ? height : height + 300)
                defer { island.close() }
                island.presentation.reduceMotion = true
                island.settle()
                #expect(island.height <= 32 + island.presentation.maxVisibleContentHeight)
                #expect(island.presentation.temporaryContentHeight > 70)
                let footer = try #require(island.presentation.layoutFrames["details.footer"])
                let notice = try #require(island.presentation.layoutFrames["clipboard.notice"])
                #expect(!notice.intersects(footer))
                if limited, let directory = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] {
                    try island.png("\(directory)/stack-\(Int(height))-limited-top.png")
                }
                if !limited {
                    #expect(island.contains(footer.insetBy(dx: 1, dy: 1)))
                } else {
                    func scrolls(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
                    }
                    let outer = try #require(scrolls(island.host).first)
                    if let document = outer.documentView, document.frame.height > outer.contentView.bounds.height + 1 {
                        outer.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - outer.contentView.bounds.height))
                        outer.reflectScrolledClipView(outer.contentView)
                        island.settle()
                        let revealed = try #require(island.presentation.layoutFrames["details.footer"])
                        #expect(island.contains(revealed.insetBy(dx: 1, dy: 1)), "Scroll must reveal the complete footer")
                    } else {
                        #expect(island.contains(footer.insetBy(dx: 1, dy: 1)))
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] {
                    try island.png("\(directory)/stack-\(Int(height))-limited-\(limited).png")
                }
            }
        }
    }

    @Test func heightReportsConvergeAndFramesKeepTopAndCenter() throws {
        let presentation = NotchPresentation()
        presentation.maxContentHeight = 341
        presentation.maxVisibleContentHeight = 500
        presentation.temporaryContentHeight = 90
        var requests: [CGFloat] = []
        presentation.onContentHeight = { requests.append($0) }
        presentation.reportBodyHeight(431)
        presentation.reportBodyHeight(430.9)
        #expect(requests == [431])
        presentation.temporaryContentHeight = 0
        presentation.reportBodyHeight(341)
        #expect(requests == [431, 341])
        presentation.reduceMotion = true
        #expect(presentation.resizeAnimation == nil)
        let layout = try #require(NotchLayout(screen: builtInScreen()))
        let base = layout.expandedFrame(contentHeight: 341)
        let grown = layout.expandedFrame(contentHeight: 431, extraHeight: 90)
        #expect(base.maxY == grown.maxY && base.midX == grown.midX && base.width == grown.width)
        let screen = ScreenDescriptor(displayID: 10, name: "Dock", isBuiltIn: false,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), safeAreaTop: 0,
            auxiliaryTopLeft: nil, auxiliaryTopRight: nil, visibleFrame: CGRect(x: 0, y: 80, width: 800, height: 496))
        let floating = NotchLayout(floatingOn: screen)
        #expect(floating.expandedFrame(contentHeight: 2000, extraHeight: 2000).minY >= 80)
    }

    @Test func bannersAndDismissal() async throws {
        _ = NSApplication.shared
        let suite = "PromptRelayTests.adaptive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: .init(suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            board.releaseGlobally()
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        let history = ClipboardImageHistory(folder: root.appendingPathComponent("images"), pasteboard: board)
        model.clipboardImages = history
        defer { history.setEnabled(false) }
        let directory = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"]
        func render(_ island: IslandHost, _ name: String) throws {
            if let directory { try island.png("\(directory)/\(name).png") }
        }
        for height: CGFloat in [268, 341, 448] {
            for reduced in [false, true] {
                model.clipboardNoticeVisible = false
                let island = IslandHost(model: model, maxContentHeight: height, availableHeight: height + 240)
                defer { island.close() }
                island.presentation.reduceMotion = reduced
                island.settle()
                let baseline = island.height
                #expect(baseline == height + 32, "Ordinary Details keeps the established height")
                let baselineAnswer = island.presentation.layoutFrames["card.response"]
                let responder = island.window.firstResponder
                #expect(island.presentation.temporaryContentHeight == 0)
                try render(island, "details-\(Int(height))-base-\(reduced)")
                for keepOn in [true, false] {
                    model.clipboardNoticeVisible = true
                    island.settle()
                    let notice = try #require(island.presentation.layoutFrames["clipboard.notice"])
                    #expect(island.height > baseline)
                    #expect(abs(island.height - baseline - notice.height - IslandMetrics.of(island.presentation).spacing) <= 2)
                    #expect(island.window.firstResponder === responder)
                    island.assertNoOverlap(["details.header", "clipboard.notice", "card.task", "card.response", "home.actions"])
                    #expect(island.presentation.layoutFrames["card.response"]?.height == baselineAnswer?.height)
                    try render(island, "details-\(Int(height))-banner-\(reduced)")
                    let settled = island.height
                    island.settle()
                    #expect(island.height == settled, "Measurement must converge")
                    model.answerClipboardNotice(keepOn: keepOn)
                    island.settle()
                    #expect(island.height == baseline)
                    #expect(island.presentation.temporaryContentHeight == 0)
                    try render(island, "details-\(Int(height))-\(keepOn ? "ok" : "off")-\(reduced)")
                }
                if reduced {
                    island.presentation.maxVisibleContentHeight = height
                    model.clipboardNoticeVisible = true
                    island.settle()
                    #expect(island.height <= height + 32)
                    func outerScroll(_ view: NSView) -> NSScrollView? {
                        if let scroll = view as? NSScrollView { return scroll }
                        return view.subviews.compactMap(outerScroll).first
                    }
                    let scroll = try #require(outerScroll(island.host))
                    if let document = scroll.documentView {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    island.settle()
                    let actions = try #require(island.presentation.layoutFrames["home.actions"])
                    #expect(island.contains(actions.insetBy(dx: 1, dy: 1)), "Both Copy buttons remain reachable")
                    try render(island, "details-\(Int(height))-limited-copy")
                    model.answerClipboardNotice(keepOn: true)
                    island.settle()
                    #expect(island.height == baseline)
                }
            }
            var requests: [CGFloat] = []
            let peek = IslandHost(model: model, surface: .peek, maxContentHeight: height, availableHeight: height + 240,
                                  onHeightRequest: { requests.append($0) })
            let baseline = peek.height
            #expect(requests.allSatisfy { $0 + 32 <= baseline }, "First layout must not flash at the maximum height")
            #expect(baseline == ordinaryPeekHeight(model: model, presentation: peek.presentation),
                    "Quick Peek retains the pre-change layout size")
            model.clipboardNoticeVisible = true
            peek.settle()
            #expect(peek.height == baseline)
            peek.assertNoOverlap(["peek.header", "peek.preview", "peek.actions"])
            try render(peek, "peek-\(Int(height))")
            peek.close()
            model.clipboardNoticeVisible = false
        }
    }
}
