import AppKit
import Foundation
import Observation

/// The single presentation model. The menu-bar panel, the main window and the
/// notch surface all observe this one object, so there is one source of truth
/// and no second UI system.
@MainActor
@Observable
public final class AppModel {
    public enum CopyKind: String, Sendable { case response = "Response", context = "Context" }

    public enum CopyFeedback: Equatable {
        case idle
        case working(CopyKind)
        case copied(CopyKind, characters: Int)
        case failed(String)
    }

    public enum RefreshMode: Equatable {
        /// FSEvents on the data dir; changes trigger a refresh.
        case watching
        /// The data dir is missing or FSEvents failed: a slow timer runs
        /// while the UI is visible, and Refresh always works.
        case polling(seconds: Int)
    }

    // MARK: Data
    public private(set) var projects: LoadState<[ProjectInfo]> = .idle
    public private(set) var sessions: LoadState<[SessionSummary]> = .idle
    public private(set) var turns: LoadState<[Turn]> = .idle
    public private(set) var detail: LoadState<ShowData> = .idle
    public private(set) var detailWarnings: [APIWarning] = []
    public private(set) var doctor: LoadState<DoctorData> = .idle
    public private(set) var lastRefresh: Date?
    public private(set) var refreshMode: RefreshMode = .polling(seconds: AppModel.pollSeconds)

    // MARK: Selection
    public private(set) var selectedProjectPath: String?
    public private(set) var selectedSessionKey: String?
    public private(set) var selectedTurnIndex: Int?

    // MARK: Copy
    public private(set) var copyFeedback: CopyFeedback = .idle
    /// Set when Copy Context found likely secrets; the UI asks before copying.
    public var pendingSensitiveContext: ContextData?

    // MARK: Ready answer (notch indicator, notifications)

    /// The newest answer Claude Code finished in any captured project, from
    /// the sessions' `last_turn` (the Core's correlation, not re-derived).
    public struct ReadyAnswer: Equatable, Sendable {
        public let sessionKey: String
        public let projectPath: String?
        public let projectName: String
        public let turnIndex: Int
        public let status: TurnStatus
        public let at: String
    }

    public private(set) var readyAnswer: ReadyAnswer?
    /// A newer answer arrived since the user last opened a surface.
    public private(set) var hasUnseenAnswer = false
    /// Load `readyAnswer` on every refresh (one extra Core call). On only
    /// while the notch or notifications are enabled.
    public var tracksReadyAnswers = false {
        didSet { if tracksReadyAnswers && !oldValue { refresh() } }
    }
    /// Called once per newly arrived answer (for an optional notification).
    public var onNewAnswer: ((ReadyAnswer) -> Void)?

    public static let pollSeconds = 30
    static let lastSeenKey = "answers.lastSeenAt"
    private let stateDefaults: UserDefaults?

    private let core: CoreProviding
    private let clipboard: ClipboardService
    private let dataDirectory: URL?
    private var watcher: StoreWatcher?
    private var pollTimer: Timer?
    private var refreshing = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var feedbackReset: Task<Void, Never>?
    private var visibleSurfaces = 0

    /// `stateDefaults` remembers which answer was last seen, so a restart
    /// does not announce old answers again (nil in tests: nothing persisted).
    public init(core: CoreProviding, clipboard: ClipboardService, dataDirectory: URL?,
                stateDefaults: UserDefaults? = nil) {
        self.core = core
        self.clipboard = clipboard
        self.dataDirectory = dataDirectory
        self.stateDefaults = stateDefaults
        lastSeenAt = stateDefaults?.string(forKey: Self.lastSeenKey)
    }

    private var lastSeenAt: String? {
        didSet { stateDefaults?.set(lastSeenAt, forKey: Self.lastSeenKey) }
    }
    private var lastAnnouncedAt: String?

    /// The live app: the CLI adapter, the general pasteboard, the default data dir.
    public static func live() -> AppModel {
        let locator = CoreLocator()
        return AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(),
                        dataDirectory: locator.dataDirectory, stateDefaults: .standard)
    }

    // MARK: Derived

    public var selectedProject: ProjectInfo? {
        projects.value?.first { $0.path == selectedProjectPath }
    }

    public var selectedSession: SessionSummary? {
        sessions.value?.first { $0.sessionKey == selectedSessionKey }
    }

    public var selectedTurn: Turn? {
        turns.value?.first { $0.index == selectedTurnIndex }
    }

    /// Newest first, as people read history.
    public var turnsNewestFirst: [Turn] { (turns.value ?? []).reversed() }

    /// The full verbatim text of the selected turn, once `show` has loaded it.
    public var selectedResponseText: String? {
        guard let show = detail.value, show.turn.index == selectedTurnIndex,
              show.session.sessionKey == selectedSessionKey else { return nil }
        return show.turn.finalResponse?.text
    }

    /// Why Copy Response is unavailable for a turn, or nil when it can copy.
    nonisolated public static func copyBlocker(for turn: Turn) -> String? {
        switch turn.status {
        case .apiError: return "The turn ended with an API error; there is no answer to copy."
        case .awaitingResponse: return "Claude has not answered yet."
        case .noMatchedResponse: return "No answer was captured for this request."
        case .stopReceivedWithoutText: return "Claude stopped without text."
        default: break
        }
        guard let response = turn.finalResponse else { return "No final response." }
        if response.charCount == 0 { return "The final response is empty." }
        return nil
    }

    // MARK: Lifecycle

    /// Called when a surface (menu panel, window) appears or disappears. The
    /// fallback timer only runs while something is visible.
    public func surfaceAppeared() {
        visibleSurfaces += 1
        if visibleSurfaces == 1 {
            startWatching()
            // With FSEvents running the data is already current: opening a
            // surface does not start Python again.
            if refreshMode != .watching || lastRefresh == nil { refresh() }
            if doctor.value == nil { loadDoctor() }
        }
    }

    /// For the always-present compact notch: keep history current through
    /// FSEvents without making any surface "visible", so no fallback timer
    /// runs in the background.
    public func startBackgroundObservation() {
        startWatching(allowPolling: false)
        if lastRefresh == nil { refresh() }
    }

    public func surfaceDisappeared() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
        if visibleSurfaces == 0 { stopPolling() }
    }

    func startWatching(allowPolling: Bool = true) {
        guard watcher?.state != .watching else { return }
        if let dir = dataDirectory {
            let watcher = StoreWatcher(directory: dir) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            self.watcher = watcher
            if watcher.start() == .watching {
                refreshMode = .watching
                stopPolling()
                return
            }
        }
        refreshMode = .polling(seconds: Self.pollSeconds)
        if allowPolling { startPolling() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Self.pollSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The data dir may have been created meanwhile: try FSEvents again.
                self.startWatching()
                self.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Refresh

    /// Reloads projects → sessions → turns → detail, keeping the selection
    /// when it still exists. Concurrent requests coalesce into one rerun.
    public func refresh() {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        Task { await performRefresh() }
    }

    /// Awaitable refresh: returns once data is current, including when a
    /// refresh was already running (it then waits for that one and its rerun).
    public func refreshNow() async {
        if refreshing {
            refreshAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true
        await performRefresh()
    }

    private func performRefresh() async {
        repeat {
            refreshAgain = false
            await loadProjects()
            if tracksReadyAnswers { await loadReadyAnswer() }
        } while refreshAgain
        refreshing = false
        lastRefresh = Date()
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func loadProjects() async {
        projects = projects.reloading
        do {
            let result = try await core.projects()
            // Projects with history first (newest activity), then enabled ones without history.
            let list = result.data.projects.sorted { a, b in
                let da = Wording.date(a.lastEventAt) ?? .distantPast, db = Wording.date(b.lastEventAt) ?? .distantPast
                if da != db { return da > db }
                return Wording.projectName(a) < Wording.projectName(b)
            }
            projects = .loaded(list)
            if selectedProjectPath == nil || !list.contains(where: { $0.path == selectedProjectPath }) {
                selectedProjectPath = list.first(where: { $0.sessionCount > 0 })?.path ?? list.first?.path
            }
        } catch {
            projects = projects.failing(Self.coreError(error))
            return
        }
        await loadSessions()
    }

    private func loadSessions() async {
        guard let project = selectedProjectPath else {
            sessions = .loaded([]); turns = .idle; detail = .idle
            selectedSessionKey = nil; selectedTurnIndex = nil
            return
        }
        sessions = sessions.reloading
        do {
            let result = try await core.sessions(project: project)
            guard project == selectedProjectPath else { return }  // selection changed meanwhile
            let list = result.data.sessions
            sessions = .loaded(list)
            if selectedSessionKey == nil || !list.contains(where: { $0.sessionKey == selectedSessionKey }) {
                selectedSessionKey = list.first?.sessionKey
                selectedTurnIndex = nil
            }
        } catch {
            sessions = sessions.failing(Self.coreError(error))
            return
        }
        await loadTurns()
    }

    private func loadTurns() async {
        guard let key = selectedSessionKey else {
            turns = .idle; detail = .idle; selectedTurnIndex = nil
            return
        }
        turns = turns.reloading
        do {
            let result = try await core.turns(sessionKey: key)
            guard key == selectedSessionKey else { return }
            let list = result.data.turns
            turns = .loaded(list)
            if selectedTurnIndex == nil || !list.contains(where: { $0.index == selectedTurnIndex }) {
                // Default: the newest turn that has a copyable answer, else the newest turn.
                selectedTurnIndex = list.last(where: { Self.copyBlocker(for: $0) == nil })?.index ?? list.last?.index
            }
        } catch {
            turns = turns.failing(Self.coreError(error))
            return
        }
        await loadDetail()
    }

    private func loadDetail() async {
        guard let key = selectedSessionKey, let index = selectedTurnIndex,
              let turn = selectedTurn else { detail = .idle; detailWarnings = []; return }
        // A turn without a final response has nothing more to show than its summary.
        guard Self.copyBlocker(for: turn) == nil else { detail = .idle; detailWarnings = []; return }
        // Keep the loaded text when nothing about the turn changed (history is append-only).
        if let shown = detail.value, shown.session.sessionKey == key, shown.turn.index == index,
           shown.turn.finalResponse?.receivedAt == turn.finalResponse?.receivedAt,
           shown.turn.responseEventCount == turn.responseEventCount, !detail.isLoading {
            return
        }
        generation += 1
        let token = generation
        detail = .loading(previous: nil)
        do {
            let result = try await core.show(sessionKey: key, turn: index)
            guard token == generation else { return }
            detail = .loaded(result.data)
            detailWarnings = result.warnings
        } catch {
            guard token == generation else { return }
            detail = .failed(Self.coreError(error), previous: nil)
            detailWarnings = []
        }
    }

    private func loadReadyAnswer() async {
        guard let result = try? await core.sessions(project: nil) else { return }
        let ready = result.data.sessions
            .filter { session in
                guard let status = session.lastTurn?.status else { return false }
                return status == .stopReceived || status == .stopReceivedBackgroundTasksPending
            }
            .max { (Wording.date($0.lastEventAt) ?? .distantPast) < (Wording.date($1.lastEventAt) ?? .distantPast) }
        guard let session = ready, let last = session.lastTurn, let at = session.lastEventAt else {
            readyAnswer = nil
            return
        }
        let answer = ReadyAnswer(sessionKey: session.sessionKey, projectPath: session.project.path,
                                 projectName: Wording.projectName(session.project), turnIndex: last.index,
                                 status: last.status, at: at)
        readyAnswer = answer
        guard let seen = lastSeenAt else {
            // First run: everything already captured counts as seen.
            lastSeenAt = at
            return
        }
        if Self.isNewer(at, than: seen) {
            hasUnseenAnswer = true
            if lastAnnouncedAt != at {
                lastAnnouncedAt = at
                onNewAnswer?(answer)
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let da = Wording.date(a), let db = Wording.date(b) else { return a > b }
        return da > db
    }

    /// The user looked at the newest answer (opened the notch or a window).
    public func acknowledgeReadyAnswer() {
        hasUnseenAnswer = false
        if let at = readyAnswer?.at { lastSeenAt = at }
    }

    /// Select the newest ready answer in every list, then load it.
    public func revealReadyAnswer() async {
        guard let answer = readyAnswer else { return }
        acknowledgeReadyAnswer()
        if let path = answer.projectPath {
            let projectPaths = (projects.value ?? []).compactMap(\.path)
            // The session's project, or the enabled root it lives under.
            let match = projectPaths.first { $0 == path }
                ?? projectPaths.filter { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
            if let match, match != selectedProjectPath {
                selectedProjectPath = match
                sessions = .idle
            }
        }
        let sessionChanged = selectedSessionKey != answer.sessionKey
        selectedSessionKey = answer.sessionKey
        selectedTurnIndex = answer.turnIndex
        if sessionChanged { turns = .idle; detail = .idle }
        await loadSessions()
    }

    // MARK: Selection

    public func selectProject(_ path: String?) {
        guard path != selectedProjectPath else { return }
        selectedProjectPath = path
        selectedSessionKey = nil
        selectedTurnIndex = nil
        sessions = .idle; turns = .idle; detail = .idle
        Task { await loadSessions() }
    }

    public func selectSession(_ key: String?) {
        guard key != selectedSessionKey else { return }
        selectedSessionKey = key
        selectedTurnIndex = nil
        turns = .idle; detail = .idle
        Task { await loadTurns() }
    }

    public func selectTurn(_ index: Int?) {
        guard index != selectedTurnIndex else { return }
        selectedTurnIndex = index
        Task { await loadDetail() }
    }

    // MARK: Diagnostics

    public func loadDoctor() {
        doctor = doctor.reloading
        Task {
            do {
                doctor = .loaded(try await core.doctor().data)
            } catch {
                doctor = doctor.failing(Self.coreError(error))
            }
        }
    }

    // MARK: Copy

    /// Copy Response for the selected turn: the exact `final_response.text`.
    public func copySelectedResponse() async {
        guard let key = selectedSessionKey, let index = selectedTurnIndex else { return }
        await copyResponse(sessionKey: key, turn: index)
    }

    /// Copy Response for any turn (row buttons). Always fetches the full text
    /// from `show`, so a preview is never copied.
    public func copyResponse(sessionKey: String, turn index: Int) async {
        copyFeedback = .working(.response)
        do {
            let text: String
            if let shown = detail.value, shown.session.sessionKey == sessionKey, shown.turn.index == index,
               let full = shown.turn.finalResponse?.text {
                text = full
            } else {
                let result = try await core.show(sessionKey: sessionKey, turn: index)
                guard let full = result.data.turn.finalResponse?.text else {
                    finishCopy(.failed("This turn has no final response."))
                    return
                }
                text = full
            }
            guard !text.isEmpty else { finishCopy(.failed("The final response is empty.")); return }
            try clipboard.copy(text)
            finishCopy(.copied(.response, characters: text.unicodeScalars.count))
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    /// Copy Context: the Core's Markdown packet. Likely secrets stop the copy
    /// until the user confirms (the same rule as `copy-context`).
    public func copySelectedContext() async {
        guard let key = selectedSessionKey, let index = selectedTurnIndex else { return }
        copyFeedback = .working(.context)
        do {
            let result = try await core.context(sessionKey: key, turn: index)
            if !result.data.sensitiveFindings.isEmpty {
                pendingSensitiveContext = result.data
                copyFeedback = .idle
                return
            }
            try clipboard.copy(result.data.text)
            finishCopy(.copied(.context, characters: result.data.text.unicodeScalars.count))
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    /// The user reviewed the findings and still wants the context copied.
    public func confirmSensitiveContextCopy() {
        guard let context = pendingSensitiveContext else { return }
        pendingSensitiveContext = nil
        do {
            try clipboard.copy(context.text)
            finishCopy(.copied(.context, characters: context.text.unicodeScalars.count))
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    public func cancelSensitiveContextCopy() {
        pendingSensitiveContext = nil
    }

    private func finishCopy(_ feedback: CopyFeedback) {
        copyFeedback = feedback
        feedbackReset?.cancel()
        feedbackReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copyFeedback = .idle
        }
    }

    // MARK: Errors

    static func coreError(_ error: Error) -> CoreError {
        if let core = error as? CoreError { return core }
        return .launchFailed(String(describing: type(of: error)))
    }

    static func message(for error: Error) -> String {
        if let clip = error as? ClipboardError {
            switch clip {
            case .writeFailed: return "The clipboard refused the text."
            case .verificationFailed: return "The clipboard content differs from the answer; nothing was confirmed."
            }
        }
        let core = coreError(error)
        return core.title + ": " + core.detail
    }
}
