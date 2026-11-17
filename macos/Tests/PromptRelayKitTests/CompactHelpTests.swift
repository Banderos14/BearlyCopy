import AppKit
import SwiftUI
import Testing
@testable import PromptRelayKit

@Suite(.serialized)
@MainActor
struct CompactHelpTests {
    @Test
    func rapidSwitchingAndDismissal() async throws {
        let tips = IslandTooltips()
        let first = UUID(), second = UUID()
        tips.enter(first, text: "Copy the original answer", anchor: .zero)
        #expect(tips.tip == nil)
        // Other offscreen suites pump the main run loop for layout. Wait for
        // the state, rather than assuming their work leaves a timer deadline free.
        for _ in 0..<100 {
            if tips.tip?.owner == first { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(tips.tip?.owner == first)
        tips.leave(first)
        #expect(tips.tip?.owner == first, "Leaving starts a grace period")
        tips.enter(second, text: "Customize BearlyCopy", anchor: .zero)
        #expect(tips.tip?.owner == second)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(tips.tip?.owner == second, "The old dismissal must not hide the new owner")
        tips.leave(second)
        for _ in 0..<100 {
            if tips.tip == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(tips.tip == nil)
        tips.enter(first, text: "History", anchor: .zero)
        tips.hideAll()
        try await Task.sleep(nanoseconds: 230_000_000)
        #expect(tips.tip == nil)
        #expect(IslandTooltips.animation(reduceMotion: true) == nil)
        #expect(IslandTooltips.animation(reduceMotion: false) != nil)
    }

    @Test
    func layoutStates() async throws {
        let suite = "PromptRelayTests.compactHelp.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.named(suite))
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            board.releaseGlobally()
            removeTestDefaults(suite)
            try? FileManager.default.removeItem(at: root)
        }
        _ = NSApplication.shared
        let model = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        var metrics: [[String: Any]] = []
        let baseline = ProcessInfo.processInfo.environment["COMPACT_HELP_BASELINE"] == "1"
        for height: CGFloat in [268, 341, 448] {
            for surface in [NotchPresentation.Surface.expanded, .peek] {
                let island = IslandHost(model: model, surface: surface, maxContentHeight: height)
                defer { island.close() }
                let frames = island.presentation.layoutFrames
                let actionID = surface == .expanded ? "home.actions" : "peek.actions"
                let actions = try #require(frames[actionID])
                metrics.append(["height": height, "surface": surface == .expanded ? "details" : "peek",
                                "panel": island.height, "footerBottom": actions.maxY,
                                "bottomSpace": island.height - actions.maxY,
                                "answerHeight": frames["card.response"]?.height ?? frames["peek.preview"]?.height ?? 0])
                if baseline { continue }
                for reduceMotion in [false, true] {
                    island.presentation.reduceMotion = reduceMotion
                    for text in ["Copy the original answer", "Preview exactly what will be copied",
                                 String(repeating: "A longer explanation with ordinary words. ", count: 3),
                                 "Copy the original answer"] {
                        let control = try #require(island.tips.controls.first)
                        island.tips.show(control.key, text: text, anchor: control.value.anchor)
                        island.settle()
                        let help = try #require(island.presentation.layoutFrames["tooltip"])
                        #expect(island.contains(help))
                        #expect(island.height == (metrics.last?["panel"] as? CGFloat ?? 0) + help.height + 6)
                        #expect(help.height <= 28)
                        if text.hasPrefix("A longer") { #expect(help.height > 18) }
                        for id in ["card.task", "card.response", "card.handoff", "card.attachments", actionID, "peek.header", "peek.preview", "peek.facts"] {
                            if let rect = island.presentation.layoutFrames[id] {
                                #expect(!help.intersects(rect), "\(id) overlaps help at \(height), Reduce Motion \(reduceMotion)")
                            }
                        }
                        if text == "Copy the original answer" {
                            #expect(help.height < 18)
                            #expect(help.width < 180)
                            #expect(island.presentation.layoutFrames[actionID] == actions)
                        }
                    }
                    island.tips.hideAll()
                    island.settle()
                    #expect(island.presentation.helpTextHeight == 0)
                    #expect(island.presentation.layoutFrames[actionID] == actions)
                }
                if let dir = ProcessInfo.processInfo.environment["COMPACT_HELP_OUTPUT"] {
                    let name = surface == .expanded ? "details" : "peek"
                    try island.png("\(dir)/\(name)-\(Int(height))-hidden.png")
                    island.tips.show(UUID(), text: "Copy the original answer", anchor: .zero)
                    try island.png("\(dir)/\(name)-\(Int(height))-short.png")
                    island.tips.show(UUID(), text: String(repeating: "A longer explanation with ordinary words. ", count: 3), anchor: .zero)
                    try island.png("\(dir)/\(name)-\(Int(height))-two-lines.png")
                    island.tips.hideAll()
                }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["COMPACT_HELP_OUTPUT"] {
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: "\(dir)/\(baseline ? "before" : "after").json"))
        }
    }
}
