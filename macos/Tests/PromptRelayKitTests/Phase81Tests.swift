import AppKit
import SwiftUI
import Testing
@testable import PromptRelayKit

@Suite(.serialized)
@MainActor
struct Phase81Tests {
    @Test
    func helpNeverCoversContent() async throws {
        let suite = "PromptRelayTests.p81.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        _ = NSApplication.shared
        let model = await Phase8Fixture.model(defaults: defaults, board: board, root: root)
        for height: CGFloat in [268, 341, 448] {
            for surface in [NotchPresentation.Surface.expanded, .peek] {
                let island = IslandHost(model: model, surface: surface, maxContentHeight: height)
                defer { island.close() }
                let controls = island.tips.controls
                let before = island.presentation.layoutFrames
                let protected = surface == .expanded
                    ? ["details.header", "card.task", "card.response", "card.handoff", "card.attachments", "home.actions"]
                    : ["peek.header", "peek.preview", "peek.facts", "peek.actions"]
                for (owner, control) in controls {
                    island.tips.show(owner, text: control.text, anchor: control.anchor)
                    island.settle()
                    let frames = island.presentation.layoutFrames
                    let help = try #require(frames["tooltip"])
                    #expect(island.contains(help), "Help stays within island at \(height)")
                    for id in protected {
                        if let content = frames[id] {
                            #expect(!help.intersects(content), "\(control.text) overlaps \(id) at \(height)")
                            if help.height < 18 {
                                #expect(content == before[id], "Single-line help must not move \(id)")
                            }
                        }
                    }
                    for other in island.tips.controls.values {
                        #expect(!help.intersects(other.anchor), "Help covers \(other.text) at \(height)")
                    }
                }
                island.tips.show(UUID(), text: String(repeating: "Long command explanation ", count: 100), anchor: .zero)
                island.settle()
                let longHelp = try #require(island.presentation.layoutFrames["tooltip"])
                #expect(island.contains(longHelp), "Long help must stay bounded at \(height)")
                let actions = try #require(island.presentation.layoutFrames[surface == .expanded ? "home.actions" : "peek.actions"])
                #expect(!longHelp.intersects(actions))
                if surface == .expanded, height == 341 || height == 448,
                   let directory = ProcessInfo.processInfo.environment["PROMPT_RELAY_VISUALS"] {
                    for (name, prefix) in [("full", "Read the complete answer"), ("copy", Labels.copyAnswerHelp)] {
                        let control = try #require(controls.first { $0.value.text.hasPrefix(prefix) })
                        island.tips.show(control.key, text: control.value.text, anchor: control.value.anchor)
                        try island.png("\(directory)/p81-details-\(Int(height))-tip-\(name).png")
                    }
                }
            }
        }

        // The widest resumed transfer footer must leave the same help space.
        _ = model.importReport(text: String(repeating: "Answer. ", count: 100), task: "Task", projectPath: "/a", sessionLabel: nil)
        let ref = try #require(model.currentRef)
        let store = try #require(model.reportStore)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.md", "b.md", "c.md"] {
            let file = root.appendingPathComponent(name)
            try Data("# Test".utf8).write(to: file)
            try store.addFile(from: file, to: ref, source: .you, displayPath: name)
        }
        model.attachmentsVersion += 1
        await model.copySelectedContext()
        model.suspendHandoffs()
        #expect(model.activeHandoff != nil)
        for height: CGFloat in [268, 341, 448] {
            for surface in [NotchPresentation.Surface.expanded, .peek] {
                let island = IslandHost(model: model, surface: surface, maxContentHeight: height)
                defer { island.close() }
                for (owner, control) in island.tips.controls {
                    island.tips.show(owner, text: control.text, anchor: control.anchor)
                    island.settle()
                    let help = try #require(island.presentation.layoutFrames["tooltip"])
                    let footer = try #require(island.presentation.layoutFrames[surface == .expanded ? "details.handoff" : "peek.handoff"])
                    #expect(!help.intersects(footer), "Help covers transfer footer at \(height)")
                    #expect(island.contains(help))
                }
                let panelHeight = island.height
                island.tips.show(UUID(), text: String(repeating: "Transfer the selected files to another app. ", count: 3), anchor: .zero)
                island.settle()
                let help = try #require(island.presentation.layoutFrames["tooltip"])
                let footer = try #require(island.presentation.layoutFrames[surface == .expanded ? "details.handoff" : "peek.handoff"])
                #expect(help.height > 18 && help.height <= 28)
                #expect(!help.intersects(footer))
                #expect(island.contains(help) && island.contains(footer))
                #expect(island.height >= panelHeight && island.height <= panelHeight + 32)
                if let directory = ProcessInfo.processInfo.environment["COMPACT_HELP_OUTPUT"] {
                    let name = surface == .expanded ? "details" : "peek"
                    try island.png("\(directory)/\(name)-\(Int(height))-transfer-help.png")
                }
            }
        }
    }
}

@Suite(.serialized)
@MainActor
struct Phase81ReadyTests {
    @Test
    func readingOneSessionPreservesOtherUnreadAcrossRestartAndNewPrompt() async throws {
        let suite = "PromptRelayTests.p81.ready.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        let t0 = "2026-10-31T10:00:00.000000Z"
        let t1 = "2026-10-31T10:01:00.000000Z"
        let t2 = "2026-10-31T10:02:00.000000Z"
        let core = FakeCore(projects: [project("/a", sessions: 2, last: t0)])
        core.showResult = { [weak core] key, index in
            guard let core, let session = try? core.session(key) else {
                return .failure(.api(code: "not_found", message: "test session missing"))
            }
            return .success(CoreResult(data: ShowData(session: session, turn: turn(index, text: "answer")), warnings: []))
        }
        core.sessionsByProject["/a"] = [sessionSummary("a", project: "/a", last: t0)]
        core.turnsBySession["a"] = [turn(1, at: t0)]
        func makeModel() -> AppModel {
            AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        }
        let model = makeModel()
        await model.refreshNow()
        core.sessionsByProject["/a"] = [sessionSummary("a", project: "/a", last: t1, lastTurn: 2,
                                                       status: "stop_received_background_tasks_pending"),
                                        sessionSummary("b", project: "/a", last: t2)]
        core.turnsBySession["a"] = [turn(1, at: t0), turn(2, status: "stop_received_background_tasks_pending", at: t1)]
        core.turnsBySession["b"] = [turn(1, at: t2)]
        await model.refreshNow()
        #expect(model.readyIndicator == .ready(sessions: 2, automated: false, backgroundPending: false))
        let successfulShow = core.showResult
        core.showResult = { _, _ in .failure(.timedOut(seconds: 1)) }
        await model.revealReadyAnswer()
        #expect(model.readyIndicator == .ready(sessions: 2, automated: false, backgroundPending: false),
                "a failed load must not acknowledge either report")
        core.showResult = successfulShow
        await model.revealReadyAnswer()
        #expect(model.selectedSessionKey == "b")
        #expect(model.readyIndicator == .ready(sessions: 1, automated: false, backgroundPending: true))
        let restarted = makeModel()
        await restarted.refreshNow()
        #expect(restarted.readyIndicator == .ready(sessions: 1, automated: false, backgroundPending: true))
        // A new prompt in a must not erase its previous unread answer.
        core.sessionsByProject["/a"] = [sessionSummary("a", project: "/a", last: "2026-10-31T10:03:00.000000Z", lastTurn: 3,
                                                       status: "awaiting_response"),
                                        sessionSummary("b", project: "/a", last: t2)]
        core.turnsBySession["a", default: []].append(turn(3, status: "awaiting_response", preview: nil))
        await restarted.refreshNow()
        #expect(restarted.readyIndicator == .ready(sessions: 1, automated: false, backgroundPending: true))
        await restarted.revealReadyAnswer()
        #expect(restarted.selectedSessionKey == "a")
        #expect(restarted.selectedTurnIndex == 2)
        #expect(!restarted.hasUnseenAnswer)
    }

    @Test
    func openingNewestTurnLeavesEarlierTurnUnreadInSameSession() async throws {
        let suite = "PromptRelayTests.p81.turns.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        let t0 = "2026-10-31T10:00:00.000000Z"
        let t1 = "2026-10-31T10:01:00.000000Z"
        let t2 = "2026-10-31T10:02:00.000000Z"
        let core = FakeCore(projects: [project("/a", sessions: 1, last: t0)])
        core.sessionsByProject["/a"] = [sessionSummary("a", project: "/a", last: t0)]
        core.turnsBySession["a"] = [turn(1, at: t0)]
        core.showResult = { [weak core] key, index in
            guard let core, let session = try? core.session(key) else {
                return .failure(.api(code: "not_found", message: "test session missing"))
            }
            return .success(CoreResult(data: ShowData(session: session, turn: turn(index, text: "answer")), warnings: []))
        }
        func makeModel() -> AppModel {
            AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        }
        let model = makeModel()
        await model.refreshNow()
        core.sessionsByProject["/a"] = [sessionSummary("a", project: "/a", last: t2, lastTurn: 3)]
        core.turnsBySession["a"] = [turn(1, at: t0), turn(2, at: t1), turn(3, at: t2)]
        await model.refreshNow()
        await model.revealReadyAnswer()
        #expect(model.selectedTurnIndex == 3)
        #expect(model.hasUnseenAnswer, "turn 2 was not opened")
        let restarted = makeModel()
        await restarted.refreshNow()
        #expect(restarted.hasUnseenAnswer)
        await restarted.revealReadyAnswer()
        #expect(restarted.selectedTurnIndex == 2)
        #expect(!restarted.hasUnseenAnswer)
        core.sessionsByProject["/a"] = [sessionSummary("a", project: "/a", last: "2026-10-31T10:04:00.000000Z", lastTurn: 3)]
        await restarted.refreshNow()
        #expect(!restarted.hasUnseenAnswer, "background activity does not create another report")
    }

    @Test
    func pinnedSessionDoesNotAcknowledgeAnUnopenedAnswer() async throws {
        let suite = "PromptRelayTests.p81.pinned.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        let core = FakeCore(projects: [project("/a", sessions: 2, last: "2026-10-31T10:00:00.000000Z")])
        let first = sessionSummary("a", project: "/a", last: "2026-10-31T10:00:00.000000Z")
        core.sessionsByProject["/a"] = [first]
        core.turnsBySession["a"] = [turn(1)]
        let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: nil, stateDefaults: defaults)
        model.staysOnChosenSession = true   // Phase 9.3: pinning is explicit
        await model.refreshNow()
        model.open(.local(sessionKey: "a", turn: 1))
        #expect(model.sessionPinned)
        core.sessionsByProject["/a"] = [first, sessionSummary("b", project: "/a", last: "2026-10-31T11:00:00.000000Z")]
        core.turnsBySession["b"] = [turn(1)]
        await model.refreshNow()
        await model.revealReadyAnswer()
        #expect(model.selectedSessionKey == "a")
        #expect(model.hasUnseenAnswer)
        model.acknowledgeReadyAnswer()
        #expect(model.hasUnseenAnswer, "acknowledging a cannot acknowledge b")
    }
}
