import AppKit
import Foundation
import Observation

/// The single presentation model. The menu-bar panel, the main window and the
/// notch surface all observe this one object, so there is one source of truth
/// and no second UI system.
@MainActor
@Observable
public final class AppModel {
    public enum CopyKind: String, Sendable {
        case response = "Response", context = "Review Pack", image = "Image", responseWithImages = "Response and images"
    }

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
    /// Set when a Review Pack found likely secrets; the UI asks before copying.
    public var pendingSensitiveContext: PendingSensitiveCopy?

    /// A Review Pack held back because it may contain secrets.
    public struct PendingSensitiveCopy: Equatable, Sendable {
        public let text: String
        public let sensitiveFindings: [SensitiveFinding]
        public let ref: ReportRef
    }

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
    /// Load `readyAnswer` on every refresh (one extra Core call per refresh;
    /// refreshes happen only when history changes). On by default: the app
    /// opens on the newest answer across all captured projects.
    public var tracksReadyAnswers = true {
        didSet { if tracksReadyAnswers && !oldValue { refresh() } }
    }
    /// Follow the newest answer automatically. Turned off when the user picks
    /// another project, session or answer; on again once they pick the newest
    /// one or every surface is closed.
    public private(set) var followsLatest = true
    private var lastFollowedAt: String?
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
    /// `reportStore` keeps imported reports and attachments (nil: imports
    /// are unavailable, e.g. in most tests).
    public init(core: CoreProviding, clipboard: ClipboardService, dataDirectory: URL?,
                stateDefaults: UserDefaults? = nil, reportStore: ReportStore? = nil) {
        self.core = core
        self.clipboard = clipboard
        self.dataDirectory = dataDirectory
        self.stateDefaults = stateDefaults
        self.reportStore = reportStore
        lastSeenAt = stateDefaults?.string(forKey: Self.lastSeenKey)
        imports = reportStore?.imports() ?? []
        copyHistory = Self.decode([CopyRecord].self, stateDefaults?.data(forKey: Self.copiesKey)) ?? []
        pinned = Self.decode([ReportRef].self, stateDefaults?.data(forKey: Self.pinsKey)) ?? []
    }

    public let reportStore: ReportStore?

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private var lastSeenAt: String? {
        didSet { stateDefaults?.set(lastSeenAt, forKey: Self.lastSeenKey) }
    }
    private var lastAnnouncedAt: String?

    /// The live app: the CLI adapter, the general pasteboard, the default data dir.
    public static func live() -> AppModel {
        let locator = CoreLocator()
        return AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(),
                        dataDirectory: locator.dataDirectory, stateDefaults: .standard,
                        reportStore: ReportStore.live(dataDirectory: locator.dataDirectory))
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
        if visibleSurfaces == 0 {
            stopPolling()
            followsLatest = true   // nobody is browsing: the next answer may take over
        }
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
            if await loadProjectList() {
                if tracksReadyAnswers { await loadReadyAnswer() }
                await loadSessions()
            }
        } while refreshAgain
        refreshing = false
        lastRefresh = Date()
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Returns false when the Core could not list projects (error is shown).
    private func loadProjectList() async -> Bool {
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
            return false
        }
        return true
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
        allSessions = result.data.sessions.sorted {
            (Wording.date($0.lastEventAt) ?? .distantPast) > (Wording.date($1.lastEventAt) ?? .distantPast)
        }
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
        // At launch and for each newer answer: select it, unless the user is
        // looking at something else right now.
        if followsLatest, lastFollowedAt != at {
            lastFollowedAt = at
            select(answer)
        }
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
        followsLatest = true
        lastFollowedAt = answer.at
        select(answer)
        await loadSessions()
    }

    /// Points the selection at `answer` without loading (the caller loads).
    private func select(_ answer: ReadyAnswer) {
        selectedImportID = nil
        // The session's project, or the enabled root it lives under.
        if let match = projectPath(containing: answer.projectPath), match != selectedProjectPath {
            selectedProjectPath = match
            sessions = .idle
        }
        let sessionChanged = selectedSessionKey != answer.sessionKey
        selectedSessionKey = answer.sessionKey
        selectedTurnIndex = answer.turnIndex
        if sessionChanged { turns = .idle; detail = .idle }
    }

    /// A manual pick keeps the selection until the user returns to the newest answer.
    private func noteManualSelection() {
        guard let answer = readyAnswer else { followsLatest = true; return }
        followsLatest = selectedSessionKey == answer.sessionKey
            && (selectedTurnIndex == nil || selectedTurnIndex == answer.turnIndex)
    }

    // MARK: Selection

    public func selectProject(_ path: String?) {
        selectedImportID = nil
        guard path != selectedProjectPath else { return }
        selectedProjectPath = path
        selectedSessionKey = nil
        selectedTurnIndex = nil
        followsLatest = false
        sessions = .idle; turns = .idle; detail = .idle
        Task { await loadSessions() }
    }

    public func selectSession(_ key: String?) {
        selectedImportID = nil
        guard key != selectedSessionKey else { return }
        selectedSessionKey = key
        selectedTurnIndex = nil
        noteManualSelection()
        turns = .idle; detail = .idle
        Task { await loadTurns() }
    }

    public func selectTurn(_ index: Int?) {
        selectedImportID = nil
        guard index != selectedTurnIndex else { return }
        selectedTurnIndex = index
        noteManualSelection()
        Task { await loadDetail() }
    }

    // MARK: Island navigation

    /// Views of the one island. Home is the answer; the others open inside
    /// the island over it and lead back to Home. One navigation state for
    /// every host (the notch and the floating fallback).
    public enum IslandRoute: String, CaseIterable, Identifiable, Sendable {
        case home, projects, copies, history, importReport, settings, reader
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .home: return "Answer"
            case .projects: return "Projects"
            case .copies: return "Recent Copies"
            case .history: return "History"
            case .importReport: return "Import Report"
            case .settings: return "Settings"
            case .reader: return "Full Report"
            }
        }
    }

    public var route: IslandRoute = .home {
        didSet {
            if route == .home { backRoute = .home }
        }
    }
    /// Where Back (and Esc) leads from the current view.
    public private(set) var backRoute: IslandRoute = .home

    /// Opens a view inside the island; Back returns to the view it came from.
    public func navigate(to destination: IslandRoute) {
        let from = route
        route = destination
        backRoute = from == destination ? .home : from
    }

    public func goBack() {
        let target = backRoute
        backRoute = .home
        route = target
    }

    /// A system dialog started from the island (folder picker) is open: the
    /// island must not fold while it is.
    public var isPresentingSystemDialog = false

    /// Projects → a project: show its newest answer on Home.
    public func openProject(_ path: String) {
        selectProject(path)
        route = .home
    }

    /// History / the reader → an answer of the selected session.
    public func openAnswer(turn index: Int) {
        selectTurn(index)
        route = .home
    }

    /// The newest unseen answer belongs to this project (or a folder inside it).
    public func hasNewAnswer(inProject path: String?) -> Bool {
        guard hasUnseenAnswer, let path, let answerPath = readyAnswer?.projectPath else { return false }
        return Self.path(answerPath, isInside: path)
    }

    static func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The enabled project (exact, or the longest enabled root) a session's folder belongs to.
    func projectPath(containing path: String?) -> String? {
        guard let path else { return nil }
        let paths = (projects.value ?? []).compactMap(\.path)
        return paths.first { $0 == path } ?? paths.filter { Self.path(path, isInside: $0) }.max { $0.count < $1.count }
    }

    // MARK: All sessions (All Responses, Recent)

    /// Every session across captured projects, newest first: the result of
    /// the same `sessions` call that finds the ready answer (no extra call).
    public private(set) var allSessions: [SessionSummary] = []

    /// Sessions grouped by project for All Responses, projects by recent activity.
    public var sessionsByProject: [(project: String, name: String, sessions: [SessionSummary])] {
        var groups: [String: [SessionSummary]] = [:]
        var names: [String: String] = [:]
        for session in allSessions {
            let key = projectPath(containing: session.project.path) ?? session.project.path ?? "?"
            groups[key, default: []].append(session)
            names[key] = (projects.value ?? []).first { $0.path == key }.map(Wording.projectName) ?? Wording.projectName(session.project)
        }
        return groups.map { (project: $0.key, name: names[$0.key] ?? $0.key, sessions: $0.value) }
            .sorted { (Wording.date($0.sessions.first?.lastEventAt) ?? .distantPast) > (Wording.date($1.sessions.first?.lastEventAt) ?? .distantPast) }
    }

    /// Show a session from All Responses: its project and its newest answer
    /// become the selection (turns load for it).
    public func focusSession(_ session: SessionSummary) {
        selectedImportID = nil
        guard session.sessionKey != selectedSessionKey else { return }
        if let path = projectPath(containing: session.project.path), path != selectedProjectPath {
            selectedProjectPath = path
            sessions = .idle
        }
        selectedSessionKey = session.sessionKey
        selectedTurnIndex = nil
        noteManualSelection()
        turns = .idle; detail = .idle
        Task { await loadSessions() }
    }

    // MARK: Opening a report by reference

    /// Shows a report (from Recent Copies, a pin or a search hit) on Home.
    public func open(_ ref: ReportRef) {
        switch ref {
        case .imported(let id):
            selectImport(id)
        case .local(let key, let turn):
            selectedImportID = nil
            if let session = allSessions.first(where: { $0.sessionKey == key }),
               let path = projectPath(containing: session.project.path), path != selectedProjectPath {
                selectedProjectPath = path
                sessions = .idle
            }
            let sessionChanged = selectedSessionKey != key
            selectedSessionKey = key
            selectedTurnIndex = turn
            noteManualSelection()
            if sessionChanged { turns = .idle; detail = .idle }
            Task { await loadSessions() }
        }
        route = .home
    }

    /// The report still exists (captured history or an import).
    public func isAvailable(_ ref: ReportRef) -> Bool {
        switch ref {
        case .imported(let id): return imports.contains { $0.id == id }
        case .local(let key, _): return allSessions.isEmpty || allSessions.contains { $0.sessionKey == key }
        }
    }

    // MARK: Turn cache (History search)

    /// Turns per session, kept while the session is unchanged. Filled only
    /// when History searches; navigation itself never starts the Core.
    private var turnCache: [String: (lastEventAt: String?, turns: [Turn])] = [:]

    private func cachedTurns(_ session: SessionSummary) async -> [Turn] {
        if let hit = turnCache[session.sessionKey], hit.lastEventAt == session.lastEventAt { return hit.turns }
        guard let turns = try? await core.turns(sessionKey: session.sessionKey).data.turns else { return [] }
        turnCache[session.sessionKey] = (session.lastEventAt, turns)
        return turns
    }

    // MARK: History (all captured and imported reports)

    /// One row of History search.
    public struct HistoryHit: Identifiable, Equatable, Sendable {
        public let ref: ReportRef
        public let source: ReportSource
        public let projectName: String
        public let title: String
        public let at: String?
        public var id: String { ref.key }
    }

    public var historyQuery = "" {
        didSet { if historyQuery != oldValue { scheduleSearch() } }
    }
    public private(set) var historyHits: LoadState<[HistoryHit]> = .idle
    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { historyHits = .idle; return }
        historyHits = historyHits.reloading
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // typing pause
            guard let self, !Task.isCancelled else { return }
            let hits = await self.search(query)
            guard !Task.isCancelled else { return }
            self.historyHits = .loaded(hits)
        }
    }

    /// Searches imports in full and local reports by their Core previews
    /// (the first 200 characters of each request and answer), plus project
    /// and session names. Newest first.
    func search(_ query: String) async -> [HistoryHit] {
        func has(_ text: String?) -> Bool { text?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var hits: [HistoryHit] = []
        for report in imports where has(report.text) || has(report.task) || has(report.projectName) || has(report.sessionLabel) {
            hits.append(HistoryHit(ref: report.ref, source: .cloudManualImport, projectName: report.projectName ?? "Cloud import",
                                   title: Self.oneLine(report.task ?? report.text), at: report.importedAt))
        }
        for session in allSessions {
            let name = Wording.projectName(session.project)
            let sessionMatches = has(name) || has(session.sessionID)
            for turn in await cachedTurns(session) where turn.finalResponse != nil {
                guard sessionMatches || has(turn.request?.preview) || has(turn.finalResponse?.preview) else { continue }
                hits.append(HistoryHit(ref: .local(sessionKey: session.sessionKey, turn: turn.index), source: .localClaudeCode,
                                       projectName: name, title: Self.oneLine(turn.request?.preview ?? turn.finalResponse?.preview ?? ""),
                                       at: turn.finalResponse?.receivedAt))
            }
        }
        return hits.sorted { (Wording.date($0.at) ?? .distantPast) > (Wording.date($1.at) ?? .distantPast) }
    }

    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.prefix(160))
    }

    // MARK: Pins

    static let pinsKey = "reports.pinned"
    public private(set) var pinned: [ReportRef] = [] {
        didSet { stateDefaults?.set(try? JSONEncoder().encode(pinned), forKey: Self.pinsKey) }
    }

    public func isPinned(_ ref: ReportRef) -> Bool { pinned.contains(ref) }

    public func togglePin(_ ref: ReportRef) {
        if let i = pinned.firstIndex(of: ref) { pinned.remove(at: i) } else { pinned.insert(ref, at: 0) }
    }

    // MARK: Imported reports (Cloud, manual)

    public private(set) var imports: [ImportedReport] = []
    /// The import shown on Home, when an import is selected instead of a local turn.
    public private(set) var selectedImportID: String?
    public var selectedImport: ImportedReport? { imports.first { $0.id == selectedImportID } }

    /// The report Home shows.
    public var currentRef: ReportRef? {
        if let id = selectedImportID { return .imported(id: id) }
        guard let key = selectedSessionKey, let turn = selectedTurnIndex else { return nil }
        return .local(sessionKey: key, turn: turn)
    }

    public enum ImportOutcome: Equatable { case added, alreadyImported, failed(String) }

    /// Explicit import of a report the user pasted (for example from a
    /// cloud session). Stored verbatim and shown at once; repeating the same
    /// import shows the existing record.
    @discardableResult
    public func importReport(text: String, task: String?, projectPath: String?, sessionLabel: String?) -> ImportOutcome {
        guard let store = reportStore else { return .failed("Imports are not available.") }
        let name = projectPath.map { path in projectRows.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent }
        do {
            let result = try store.importReport(text: text, task: task, projectPath: projectPath, projectName: name,
                                                sessionLabel: sessionLabel)
            imports = store.imports()
            selectImport(result.report.id)
            route = .home
            return result.isDuplicate ? .alreadyImported : .added
        } catch ReportStoreError.empty {
            return .failed("There is nothing to import: the text is empty.")
        } catch {
            return .failed("The report could not be saved.")
        }
    }

    public func selectImport(_ id: String) {
        guard imports.contains(where: { $0.id == id }) else { return }
        selectedImportID = id
        followsLatest = false
    }

    /// Removes an import and its attachments (the user's explicit choice).
    public func deleteImport(_ id: String) {
        reportStore?.deleteImport(id)
        imports = reportStore?.imports() ?? []
        pinned.removeAll { $0 == .imported(id: id) }
        if selectedImportID == id { selectedImportID = nil }
        attachmentsVersion += 1
    }

    // MARK: Attachments

    /// Bumped on every change so views showing attachments refresh.
    public private(set) var attachmentsVersion = 0
    public private(set) var attachmentMessage: String?

    public func attachments(for ref: ReportRef?) -> [ReportAttachment] {
        _ = attachmentsVersion
        guard let ref, let store = reportStore else { return [] }
        return store.attachments(for: ref)
    }

    public func attachmentURL(_ attachment: ReportAttachment) -> URL? { reportStore?.fileURL(for: attachment) }

    /// Images the user chose in the file picker, copied into Prompt Relay's
    /// private folder for the current report. Nothing else is read.
    public func addAttachments(_ urls: [URL]) {
        guard let ref = currentRef, let store = reportStore else { return }
        var problems: [String] = []
        for url in urls {
            do { try store.addAttachment(from: url, to: ref) } catch ReportStoreError.notAnImage(let name) {
                problems.append("\(name) is not an image")
            } catch ReportStoreError.tooLarge(let name) {
                problems.append("\(name) is larger than 50 MB")
            } catch {
                problems.append("\(url.lastPathComponent) could not be read")
            }
        }
        attachmentMessage = problems.isEmpty ? nil : problems.joined(separator: "; ")
        attachmentsVersion += 1
    }

    public func removeAttachment(_ attachment: ReportAttachment) {
        reportStore?.removeAttachment(attachment.id)
        attachmentsVersion += 1
    }

    /// Copies one attachment as an image.
    public func copyAttachment(_ attachment: ReportAttachment) {
        guard let url = attachmentURL(attachment) else { finishCopy(.failed("The image file is missing.")); return }
        do {
            try clipboard.copyImage(at: url)
            finishCopy(.copied(.image, characters: 0))
        } catch {
            finishCopy(.failed("The image could not be copied."))
        }
    }

    /// Text and images in one clipboard write. Whether a paste carries the
    /// images depends on the destination app (see docs/MACOS_APP.md).
    public func copyResponseWithImages() async {
        guard let ref = currentRef else { return }
        let urls = attachments(for: ref).compactMap(attachmentURL)
        guard let text = await fullText(for: ref) else { return }
        do {
            try clipboard.copy(text, images: urls)
            finishCopy(.copied(.responseWithImages, characters: text.unicodeScalars.count))
            record(.response, ref: ref, characters: text.unicodeScalars.count)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    // MARK: Recent Copies

    static let copiesKey = "copies.recent"
    public static let copyHistoryLimit = 5
    /// The last copies made in Prompt Relay, newest first. References only.
    public private(set) var copyHistory: [CopyRecord] = [] {
        didSet { stateDefaults?.set(try? JSONEncoder().encode(copyHistory), forKey: Self.copiesKey) }
    }

    private func record(_ kind: CopyRecord.Kind, ref: ReportRef, characters: Int) {
        let (project, label) = describe(ref)
        let entry = CopyRecord(id: UUID().uuidString, ref: ref, kind: kind, projectName: project, label: label,
                               at: ReportStore.now(), characters: characters)
        copyHistory = Array(([entry] + copyHistory.filter { !($0.ref == ref && $0.kind == kind) }).prefix(Self.copyHistoryLimit))
    }

    func describe(_ ref: ReportRef) -> (project: String, label: String) {
        switch ref {
        case .imported(let id):
            let report = imports.first { $0.id == id }
            return (report?.projectName ?? "Cloud import", "Cloud import · " + Wording.absolute(report?.importedAt))
        case .local(let key, let turn):
            let session = allSessions.first { $0.sessionKey == key } ?? sessions.value?.first { $0.sessionKey == key }
            let project = session.map { Wording.projectName($0.project) } ?? selectedProject.map(Wording.projectName) ?? "Claude Code"
            let title = session.map(Wording.sessionTitle) ?? "Session"
            return (project, "\(title) · #\(turn)")
        }
    }

    /// Copies the same thing again, fetched fresh from its source.
    public func copyAgain(_ record: CopyRecord) async {
        guard isAvailable(record.ref) else {
            finishCopy(.failed("This report is no longer in Prompt Relay's history."))
            return
        }
        switch record.kind {
        case .response: await copyResponse(record.ref)
        case .reviewPack: await copyReviewPack(record.ref)
        }
    }

    public func clearCopyHistory() { copyHistory = [] }

    // MARK: Capture per project (Settings → Projects)

    /// One row of the Projects list: what the Core reports, plus folders the
    /// user added in the app but has not enabled yet (the Core does not know
    /// those until they are enabled or have history).
    public struct ProjectRow: Identifiable, Equatable, Sendable {
        public let path: String
        public let name: String
        public let captureEnabled: Bool
        /// Enabled for this folder itself (not only through a parent folder).
        public let explicitlyEnabled: Bool
        public let sessionCount: Int
        public let lastEventAt: String?
        /// Only in the app's list (no history, never enabled): removable.
        public let isAddedOnly: Bool
        public var id: String { path }
    }

    public enum CaptureChange: Equatable {
        case working(path: String)
        case done(path: String, message: String)
        case failed(path: String, message: String)
    }

    static let addedProjectsKey = "projects.added"
    public private(set) var captureChange: CaptureChange?
    private var addedProjects: [String] {
        get { stateDefaults?.stringArray(forKey: Self.addedProjectsKey) ?? memoryAddedProjects }
        set { memoryAddedProjects = newValue; stateDefaults?.set(newValue, forKey: Self.addedProjectsKey) }
    }
    private var memoryAddedProjects: [String] = []

    public var projectRows: [ProjectRow] {
        let core = (projects.value ?? []).compactMap { p -> ProjectRow? in
            guard let path = p.path else { return nil }
            return ProjectRow(path: path, name: Wording.projectName(p), captureEnabled: p.captureEnabled,
                              explicitlyEnabled: p.explicitlyEnabled, sessionCount: p.sessionCount,
                              lastEventAt: p.lastEventAt, isAddedOnly: false)
        }
        let known = Set(core.map(\.path))
        let added = addedProjects.filter { !known.contains($0) }.map {
            ProjectRow(path: $0, name: ($0 as NSString).lastPathComponent, captureEnabled: false,
                       explicitlyEnabled: false, sessionCount: 0, lastEventAt: nil, isAddedOnly: true)
        }
        return (core + added).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds a folder to the list with capture **off**. Only the path is used;
    /// nothing inside the folder is read.
    public func addProject(_ url: URL) {
        let path = Self.realPath(url.path)
        guard !projectRows.contains(where: { $0.path == path }) else { return }
        addedProjects = addedProjects + [path]
        captureChange = .done(path: path, message: "Added. Capture is off until you enable it.")
    }

    /// Removes a folder that only exists in the app's list. History is never touched.
    public func removeAddedProject(_ path: String) {
        addedProjects = addedProjects.filter { $0 != path }
    }

    /// `prompt-relay enable|disable`, then refresh the lists and the status.
    public func setCapture(_ enabled: Bool, for path: String) async {
        captureChange = .working(path: path)
        do {
            let message = try await core.setCapture(enabled, path: path)
            captureChange = .done(path: path, message: message.isEmpty ? (enabled ? "Capture on." : "Capture off.") : message)
        } catch {
            captureChange = .failed(path: path, message: Self.message(for: error))
        }
        await refreshNow()
        loadDoctor()
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
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

    /// The complete original text of a report: the Core's
    /// `final_response.text` (via `show`) or the imported text. Never a preview.
    func fullText(for ref: ReportRef) async -> String? {
        switch ref {
        case .imported(let id):
            guard let text = imports.first(where: { $0.id == id })?.text, !text.isEmpty else {
                finishCopy(.failed("This report is no longer in Prompt Relay's history."))
                return nil
            }
            return text
        case .local(let key, let index):
            if let shown = detail.value, shown.session.sessionKey == key, shown.turn.index == index,
               let full = shown.turn.finalResponse?.text {
                if full.isEmpty { finishCopy(.failed("The final response is empty.")); return nil }
                return full
            }
            do {
                let result = try await core.show(sessionKey: key, turn: index)
                guard let full = result.data.turn.finalResponse?.text else {
                    finishCopy(.failed("This turn has no final response."))
                    return nil
                }
                guard !full.isEmpty else { finishCopy(.failed("The final response is empty.")); return nil }
                return full
            } catch {
                finishCopy(.failed(Self.message(for: error)))
                return nil
            }
        }
    }

    /// Copy Response for the report on Home: the exact original text.
    public func copySelectedResponse() async {
        guard let ref = currentRef else { return }
        await copyResponse(ref)
    }

    /// Copy Response for any turn (list rows). Always the full text.
    public func copyResponse(sessionKey: String, turn index: Int) async {
        await copyResponse(.local(sessionKey: sessionKey, turn: index))
    }

    public func copyResponse(_ ref: ReportRef) async {
        copyFeedback = .working(.response)
        guard let text = await fullText(for: ref) else { return }
        do {
            try clipboard.copy(text)
            finishCopy(.copied(.response, characters: text.unicodeScalars.count))
            record(.response, ref: ref, characters: text.unicodeScalars.count)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    /// Review Pack for the report on Home.
    public func copySelectedContext() async {
        guard let ref = currentRef else { return }
        await copyReviewPack(ref)
    }

    /// Review Pack: the Core's packet for a local report, the app's for an
    /// import, plus the attachments' names. Likely secrets stop the copy
    /// until the user confirms (the same rule as `copy-context`).
    public func copyReviewPack(_ ref: ReportRef) async {
        copyFeedback = .working(.context)
        let attached = attachments(for: ref)
        let text: String, findings: [SensitiveFinding]
        switch ref {
        case .imported(let id):
            guard let report = imports.first(where: { $0.id == id }) else {
                finishCopy(.failed("This report is no longer in Prompt Relay's history."))
                return
            }
            text = ReviewPack.render(imported: report, attachments: attached, exportedAt: ReportStore.now())
            findings = SecretScanner.scan(report.task ?? "", section: "request") + SecretScanner.scan(report.text, section: "response")
        case .local(let key, let index):
            do {
                let result = try await core.context(sessionKey: key, turn: index)
                text = ReviewPack.render(local: result.data.text, attachments: attached)
                findings = result.data.sensitiveFindings
            } catch {
                finishCopy(.failed(Self.message(for: error)))
                return
            }
        }
        if !findings.isEmpty {
            pendingSensitiveContext = PendingSensitiveCopy(text: text, sensitiveFindings: findings, ref: ref)
            copyFeedback = .idle
            return
        }
        do {
            try clipboard.copy(text)
            finishCopy(.copied(.context, characters: text.unicodeScalars.count))
            record(.reviewPack, ref: ref, characters: text.unicodeScalars.count)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    /// The user reviewed the findings and still wants the pack copied. It is
    /// not added to Recent Copies: a pack with possible secrets is never kept
    /// for one-click re-copying.
    public func confirmSensitiveContextCopy() {
        guard let pending = pendingSensitiveContext else { return }
        pendingSensitiveContext = nil
        do {
            try clipboard.copy(pending.text)
            finishCopy(.copied(.context, characters: pending.text.unicodeScalars.count))
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
