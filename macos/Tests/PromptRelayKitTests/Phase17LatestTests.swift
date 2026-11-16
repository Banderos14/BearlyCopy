import AppKit
import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 17: Quick Peek opens on the newest completed answer of any agent,
/// project and conversation. Reproductions of the owner's "an older answer
/// shows after reopening" first, then the fifteen selection scenarios.
/// Fake Core, in-memory settings, a pinned clock: no real history.
@Suite(.serialized)
@MainActor
struct Phase17LatestTests {
    // MARK: Fixtures

    nonisolated static let baseline = "2026-11-01T00:00:00.000000Z"
    static func t(_ minute: Int, _ second: Int = 0) -> String {
        String(format: "2026-11-12T10:%02d:%02d.000000Z", minute, second)
    }

    final class World {
        let core: FakeCore
        let defaults: MemorySettingsStore
        var projects: [String: String] = [:]          // path → last event
        var sessions: [String: (project: String, last: String, answeredAt: String?, turns: [Turn], status: String, running: Bool)] = [:]
        var lastCompletion: [String: String] = [:]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PromptRelay17-\(UUID().uuidString)")

        init(defaults: MemorySettingsStore = MemorySettingsStore()) {
            core = FakeCore(projects: [])
            self.defaults = defaults
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            core.showResult = { [unowned core] key, i in
                .success(CoreResult(data: ShowData(session: try! core.session(key), turn: turn(i, text: "\(key)#\(i)")), warnings: []))
            }
        }

        /// A final answer `index` in `key` at `at` (earlier turns are kept).
        func answer(_ key: String, project: String, turn index: Int, at: String) {
            var entry = sessions[key] ?? (project, at, nil, [], "stop_received", false)
            entry.turns.removeAll { $0.index == index }
            entry.turns.append(turn(index, request: "task \(index)", at: at, completion: "answer"))
            entry.turns.sort { $0.index < $1.index }
            entry.last = max(entry.last, at); entry.answeredAt = at; entry.status = "stop_received"; entry.running = false
            sessions[key] = entry
            lastCompletion[key] = "answer"
            publish()
        }

        /// A later tool event: the session's activity moves, its answers do not.
        func toolEvent(_ key: String, at: String) {
            sessions[key]?.last = at
            publish()
        }

        /// A new prompt without an answer yet (the agent is working).
        func prompt(_ key: String, project: String, turn index: Int, at: String) {
            var entry = sessions[key] ?? (project, at, nil, [], "awaiting_response", true)
            entry.turns.append(turn(index, status: "awaiting_response", preview: nil, request: "task \(index)"))
            entry.last = at; entry.status = "awaiting_response"; entry.running = true
            sessions[key] = entry
            lastCompletion[key] = nil
            publish()
        }

        /// A Stop that reports background work (not a final answer).
        func intermediate(_ key: String, project: String, turn index: Int, at: String) {
            var entry = sessions[key] ?? (project, at, nil, [], "stop_received", false)
            entry.turns.removeAll { $0.index == index }
            entry.turns.append(turn(index, request: "task \(index)", at: at, completion: "intermediate", continuedIn: index + 1))
            entry.last = at; entry.status = "stop_received"; entry.running = false
            sessions[key] = entry
            lastCompletion[key] = "intermediate"
            publish()
        }

        private func publish() {
            var byProject: [String: [SessionSummary]] = [:]
            for (key, s) in sessions {
                let last = s.turns.last
                var lastTurn: [String: Any] = ["index": last?.index ?? 1, "status": s.status]
                if let completion = lastCompletion[key] { lastTurn["completion"] = completion }
                if s.status != "awaiting_response", let at = last?.finalResponse?.receivedAt { lastTurn["answered_at"] = at }
                let json: [String: Any] = [
                    "session_id": key, "session_key": key, "project": ["path": s.project, "name": (s.project as NSString).lastPathComponent],
                    "first_event_at": s.last, "last_event_at": s.last, "event_count": 2, "turn_count": s.turns.count, "cwds": [s.project],
                    "last_turn": lastTurn, "integrity": ["corrupt_lines": 0, "unsupported_lines": 0, "foreign_lines": 0],
                    "answered_count": s.turns.filter { $0.finalResponse != nil }.count, "running": s.running,
                    "source": ["provider": "claude_code", "host": "unknown", "native_session_id": "n-" + key, "capture": "hooks",
                               "capabilities": ["prompt", "final_response"]],
                ]
                byProject[s.project, default: []].append(try! JSONDecoder().decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json)))
                core.turnsBySession[key] = s.turns
            }
            for key in byProject.keys {
                byProject[key]?.sort { ($0.lastEventAt ?? "") > ($1.lastEventAt ?? "") }
            }
            core.sessionsByProject = byProject
            core.projectsList = byProject.map { path, list in
                project(path, sessions: list.count, last: list.first?.lastEventAt)
            }
        }

        @MainActor func model(seenBaseline: String? = Phase17LatestTests.baseline) -> AppModel {
            if let seenBaseline, defaults.string(forKey: AppModel.lastSeenKey) == nil {
                defaults.set(seenBaseline, forKey: AppModel.lastSeenKey)
            }
            let board = NSPasteboard(name: .init("PromptRelay17-\(UUID().uuidString)"))
            // A real (empty) data dir: FSEvents is live as in the installed
            // app, so opening the island starts no refresh of its own.
            let model = AppModel(core: core, clipboard: ClipboardService(pasteboard: board), dataDirectory: directory, stateDefaults: defaults)
            model.startBackgroundObservation()
            return model
        }
    }

    /// What the notch controller does when the island opens and closes.
    static func open(_ model: AppModel) async {
        model.surfaceAppeared()
        if model.hasUnseenAnswer { await model.revealReadyAnswer() }
        await settle(model)
    }
    /// Bounded wait for a condition (never an endless loop).
    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
    /// Lets the loads started by an action finish (no refresh of its own).
    static func settle(_ model: AppModel) async {
        for _ in 0..<400 {
            await Task.yield()
            if !model.sessions.isLoading, !model.turns.isLoading, !model.detail.isLoading,
               model.selectedSessionKey == nil
                || (model.detail.value?.session.sessionKey == model.selectedSessionKey
                    && model.detail.value?.turn.index == model.selectedTurnIndex) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func close(_ model: AppModel) async {
        model.surfaceDisappeared()
        await settle(model)
    }
    static func shown(_ model: AppModel) -> String {
        "\(model.selectedSessionKey ?? "-")#\(model.selectedTurnIndex.map(String.init) ?? "-")"
    }

    // MARK: The owner's reports

    /// Reproduction 1: an older answer in a conversation that was never
    /// opened ("unseen") replaced the newest answer on every reopen.
    @Test func reopeningNeverPrefersAnOlderUnopenedAnswerOverTheNewest() async {
        let world = World()
        world.answer("old-b", project: "/b", turn: 1, at: Self.t(5))
        world.answer("old-c", project: "/c", turn: 1, at: Self.t(6))
        world.answer("new-a", project: "/a", turn: 1, at: Self.t(10))
        let model = world.model()
        await model.refreshNow()
        #expect(model.refreshMode == .watching)
        #expect(Self.shown(model) == "new-a#1")
        for round in 1...3 {
            await Self.open(model)
            #expect(Self.shown(model) == "new-a#1", "reopen \(round): the newest answer, not an older unopened one")
            #expect(model.selectedResponseText == "new-a#1")
            await Self.close(model)
        }
        // The older ones stay discoverable as unread, they are not lost.
        #expect(model.unseenAnswers.map(\.sessionKey).sorted() == ["old-b", "old-c"])
    }

    /// Reproduction 2 (the owner's data held seven of these): a hand-off
    /// whose "Done" was never pressed kept its old report across every
    /// close and blocked Latest for good.
    @Test func aForgottenHandoffNoLongerPinsAnOldAnswer() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        let model = world.model()
        await model.refreshNow()
        await Self.open(model)
        // Saved by an earlier version: no start time.
        model.handoffs[ReportRef.local(sessionKey: "a", turn: 1).key] =
            AppModel.HandoffStep(ref: .local(sessionKey: "a", turn: 1), text: "pack", attachmentIDs: ["x"], resumed: true)
        await Self.close(model)
        world.answer("b", project: "/b", turn: 1, at: Self.t(2))
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "b#1", "the newest answer, although a#1 has an unfinished hand-off")
        #expect(model.handoffs.count == 1, "the hand-off itself is kept and resumes when a#1 is opened")
    }

    /// A hand-off just started (text copied, files still to drag) keeps its
    /// report while the user pastes elsewhere — for a bounded time.
    @Test func aFreshHandoffHoldsItsReportOnlyForItsWindow() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        let model = world.model()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        model.clock = { now }
        await model.refreshNow()
        await Self.open(model)
        model.handoffs[ReportRef.local(sessionKey: "a", turn: 1).key] =
            AppModel.HandoffStep(ref: .local(sessionKey: "a", turn: 1), text: "pack", attachmentIDs: ["x"], startedAt: now)
        await Self.close(model)
        world.answer("b", project: "/b", turn: 1, at: Self.t(2))
        await model.refreshNow()
        #expect(Self.shown(model) == "a#1")
        #expect(model.deferredLatest?.sessionKey == "b")
        now += 60
        await Self.open(model)
        #expect(Self.shown(model) == "a#1", "back from pasting: the files are still to drag")
        #expect(model.isOffLatest && model.readyAnswer?.sessionKey == "b", "Jump to Latest is offered")
        await Self.close(model)
        now += AppModel.handoffHoldWindow
        await Self.open(model)
        #expect(Self.shown(model) == "b#1", "the window is over: Latest")
    }

    // MARK: The fifteen scenarios

    /// 1–3: one session, five answers, a sixth, close and reopen.
    @Test func oneSessionFollowsItsNewestAnswerAcrossReopens() async {
        let world = World()
        for i in 1...5 { world.answer("a", project: "/a", turn: i, at: Self.t(i)) }
        let model = world.model()
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "a#5")                                  // 1
        world.answer("a", project: "/a", turn: 6, at: Self.t(6))
        await model.refreshNow()
        #expect(Self.shown(model) == "a#5", "never replaced while it is being read")
        #expect(model.deferredLatest?.turnIndex == 6)
        #expect(model.readyAnswer?.turnIndex == 6)                           // 2
        await Self.close(model)
        #expect(Self.shown(model) == "a#6")
        for _ in 1...2 {                                                     // 3
            await Self.open(model)
            #expect(Self.shown(model) == "a#6")
            #expect(model.selectedResponseText == "a#6")
            await Self.close(model)
        }
        // The same while the island is closed the whole time.
        world.answer("a", project: "/a", turn: 7, at: Self.t(7))
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "a#7")
    }

    /// 4–7: a new conversation, another project, and a later tool event in
    /// an older conversation that must not reorder final answers.
    @Test func newConversationsAndProjectsBecomeLatestAndToolEventsDoNotReorder() async {
        let world = World()
        for i in 1...3 { world.answer("a", project: "/a", turn: i, at: Self.t(i)) }
        let model = world.model()
        await model.refreshNow()
        world.answer("b", project: "/a", turn: 1, at: Self.t(10))            // 4: new conversation, same project
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "b#1")
        await Self.close(model)
        await Self.open(model)
        #expect(Self.shown(model) == "b#1")                                  // 5
        await Self.close(model)
        world.answer("c1", project: "/c", turn: 1, at: Self.t(20))           // 6: another project
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "c1#1")
        #expect(model.selectedProjectPath == "/c")
        await Self.close(model)
        world.toolEvent("a", at: Self.t(30))                                 // 7
        world.prompt("b", project: "/a", turn: 2, at: Self.t(31))            // b is working, no final text yet
        await model.refreshNow()
        #expect(model.readyAnswer?.sessionKey == "c1", "activity is not an answer")
        await Self.open(model)
        #expect(Self.shown(model) == "c1#1")
        #expect(model.readyIndicator == .working(sessions: 1) || model.allSessions.contains { $0.running == true },
                "the working conversation is shown as working, separately")
    }

    /// 8: an intermediate Stop is not an answer; its continuation is.
    @Test func backgroundContinuationBecomesLatestOnlyWhenFinal() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        let model = world.model()
        await model.refreshNow()
        world.intermediate("d", project: "/d", turn: 1, at: Self.t(5))
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "a#1", "waiting for background work is not a final answer")
        await Self.close(model)
        world.answer("d", project: "/d", turn: 2, at: Self.t(9))
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "d#2")
    }

    /// 9: two finals a moment apart, and at the very same instant.
    @Test func nearlySimultaneousFinalsHaveOneStableWinner() async {
        let world = World()
        world.answer("x", project: "/x", turn: 1, at: "2026-11-12T10:00:00.000100Z")
        world.answer("y", project: "/y", turn: 1, at: "2026-11-12T10:00:00.000200Z")
        let model = world.model()
        await model.refreshNow()
        #expect(model.readyAnswer?.sessionKey == "y", "the later completion, even by 100 µs")
        world.answer("m", project: "/m", turn: 1, at: Self.t(40))
        world.answer("k", project: "/k", turn: 1, at: Self.t(40))
        var winners: Set<String> = []
        for _ in 1...5 {
            await model.refreshNow()
            await Self.open(model)
            winners.insert(Self.shown(model))
            await Self.close(model)
        }
        #expect(winners == ["k#1"], "equal times: one stable winner, no flicker")
    }

    /// 10: a restart opens on the newest answer; an ordinary pick made
    /// before quitting is not a pin.
    @Test func restartRestoresLatestAndAnOrdinaryPickIsNotAPin() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        world.answer("b", project: "/b", turn: 1, at: Self.t(2))
        let first = world.model()
        await first.refreshNow()
        await Self.open(first)
        first.focusSession(try! world.core.session("a"))                    // an ordinary manual selection
        await Self.settle(first)
        #expect(Self.shown(first) == "a#1")
        #expect(!first.sessionPinned)
        #expect(world.defaults.object(forKey: AppModel.selectionKey) == nil, "nothing persistent was written")
        await Self.close(first)
        #expect(Self.shown(first) == "b#1", "closing returns to Latest")
        let second = world.model()
        await second.refreshNow()
        await Self.open(second)
        #expect(Self.shown(second) == "b#1")
        #expect(second.followsLatest && !second.sessionPinned)
    }

    /// 11–13: an explicit pin persists, shows what is new elsewhere, and
    /// Jump to Latest / Follow Latest lead back.
    @Test func explicitPinPersistsAndLatestStaysOneClickAway() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        world.answer("b", project: "/b", turn: 1, at: Self.t(2))
        let model = world.model()
        await model.refreshNow()
        await Self.open(model)
        model.focusSession(try! world.core.session("a"))
        await Self.settle(model)
        model.stayOnThisConversation()                                       // the deliberate action
        #expect(model.sessionPinned && model.staysOnChosenSession)
        await Self.close(model)
        world.answer("c", project: "/c", turn: 1, at: Self.t(3))
        await model.refreshNow()
        await Self.open(model)
        #expect(Self.shown(model) == "a#1")                                  // 11
        #expect(model.newAnswerElsewhere?.sessionKey == "c")                 // 12
        #expect(model.isOffLatest && model.readyAnswer?.sessionKey == "c")
        await Self.close(model)
        // 11, after a restart.
        let restarted = world.model()
        await restarted.refreshNow()
        await Self.open(restarted)
        #expect(Self.shown(restarted) == "a#1")
        #expect(restarted.sessionPinned)
        // A new answer inside the pinned conversation is followed.
        world.answer("a", project: "/a", turn: 2, at: Self.t(4))
        await Self.close(restarted)
        await restarted.refreshNow()
        await Self.open(restarted)
        #expect(Self.shown(restarted) == "a#2")
        // 13
        world.answer("c", project: "/c", turn: 2, at: Self.t(5))
        await restarted.refreshNow()
        restarted.followLatestNow()
        await Self.settle(restarted)
        #expect(Self.shown(restarted) == "c#2")
        #expect(!restarted.sessionPinned && !restarted.staysOnChosenSession && restarted.followsLatest)
        #expect(world.defaults.object(forKey: AppModel.selectionKey) == nil)
        await Self.close(restarted)
        world.answer("b", project: "/b", turn: 2, at: Self.t(6))
        await restarted.refreshNow()
        await Self.open(restarted)
        #expect(Self.shown(restarted) == "b#2", "following again")
    }

    /// 13, without a pin: Jump to Latest ends a browsing hold.
    @Test func jumpToLatestEndsABrowsingHold() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        world.answer("a", project: "/a", turn: 2, at: Self.t(2))
        let model = world.model()
        await model.refreshNow()
        await Self.open(model)
        model.selectTurn(1)
        await Self.settle(model)
        #expect(model.isOffLatest && !model.followsLatest)
        model.jumpToLatest()
        await Self.settle(model)
        #expect(Self.shown(model) == "a#2")
        #expect(model.followsLatest && !model.isOffLatest && !model.sessionPinned)
    }

    /// 14: Details stays on the report being read — while open, and across
    /// an accidental close for a short grace only.
    @Test func detailsReadingIsStableWhileOpenAndForAShortGrace() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        world.answer("a", project: "/a", turn: 2, at: Self.t(2))
        let model = world.model()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        model.clock = { now }
        await model.refreshNow()
        model.detailsPreferred = true
        await Self.open(model)
        model.selectTurn(1)
        await Self.settle(model)
        world.answer("b", project: "/b", turn: 1, at: Self.t(3))
        await model.refreshNow()
        #expect(Self.shown(model) == "a#1", "reading: not replaced")
        #expect(model.newAnswerElsewhere?.sessionKey == "b", "and the new answer is announced")
        await Self.close(model)                                              // the pointer slipped off
        now += 20
        model.detailsPreferred = true
        await Self.open(model)
        #expect(Self.shown(model) == "a#1", "still there a moment later")
        await Self.close(model)
        now += AppModel.readingGrace + 1
        await Self.open(model)
        #expect(Self.shown(model) == "b#1", "later, reopening shows Latest")
    }

    /// 15: a late answer of the Core for an old selection never lands on a
    /// newer one.
    @Test func aStaleLoadNeverOverwritesANewerSelection() async {
        let world = World()
        world.answer("b", project: "/b", turn: 1, at: Self.t(1))
        world.answer("a", project: "/a", turn: 1, at: Self.t(2))
        let gate = Gate()
        world.core.showGate = { key, _ in if key == "a" { await gate.wait() } }
        let model = world.model()
        let loading = Task { await model.refreshNow() }                      // show(a, 1) hangs
        #expect(await Self.eventually { world.core.showCalls.contains { $0.0 == "a" } })
        model.surfaceAppeared()
        model.focusSession(try! world.core.session("b"))                     // the user moves on meanwhile
        #expect(await Self.eventually { model.detail.value?.session.sessionKey == "b" })
        await gate.open()                                                    // the old answer arrives last
        await loading.value
        await Self.settle(model)
        #expect(Self.shown(model) == "b#1")
        #expect(model.detail.value?.session.sessionKey == "b")
        #expect(model.selectedResponseText == "b#1")
    }

    /// No refresh loop: an idle open/close cycle asks the Core for nothing.
    @Test func openingAndClosingOnLatestStartsNoCoreCalls() async {
        let world = World()
        world.answer("a", project: "/a", turn: 1, at: Self.t(1))
        let model = world.model()
        await model.refreshNow()
        await Self.open(model)
        await Self.close(model)
        let calls = (world.core.sessionsCalls, world.core.turnsCalls, world.core.showCalls.count)
        for _ in 1...5 { await Self.open(model); await Self.close(model) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect((world.core.sessionsCalls, world.core.turnsCalls, world.core.showCalls.count) == calls)
    }
}

/// A one-shot gate for controlled scheduling.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
