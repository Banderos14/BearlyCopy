import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The single presentation model. The menu-bar panel, the main window and the
/// notch surface all observe this one object, so there is one source of truth
/// and no second UI system.
@MainActor
@Observable
public final class AppModel {
    public enum CopyKind: String, Sendable {
        case response = "Answer", context = "Copy with Context", image = "Image", responseWithImages = "Response and images"
        case files = "Files", task = "Task"
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
    public private(set) var selectedProjectPath: String? { didSet { dropStaleHandoff() } }
    public private(set) var selectedSessionKey: String? { didSet { dropStaleHandoff() } }
    public private(set) var selectedTurnIndex: Int? { didSet { dropStaleHandoff() } }

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

    /// The newest answer any connected agent (Claude Code, Codex) finished in
    /// any captured project, from the sessions' `last_turn` (the Core's
    /// correlation, not re-derived). Phase 9.3: `at` is when the final
    /// response was stored (completion), not the session's latest activity,
    /// and `projectPath` is the logical project (Git root, enabled project).
    public struct ReadyAnswer: Equatable, Sendable {
        public let sessionKey: String
        public let projectPath: String?
        public let projectName: String
        public let turnIndex: Int
        public let status: TurnStatus
        public let at: String
        public var provider: AgentProvider = .claudeCode
        /// "Codex · Xcode · This Mac"; the host stays Unknown unless recorded.
        public var sourceLabel: String = "Claude Code · Unknown · This Mac"
        /// Phase 9.4: `.waitingBackground` here means the wait expired with
        /// no continuation — shown, but never announced as ready.
        public var completion: Completion = .answer
    }

    public private(set) var readyAnswer: ReadyAnswer?
    /// A newer answer arrived since the user last opened a surface.
    public var hasUnseenAnswer: Bool { !unseenAnswers.isEmpty }
    private var finishedAnswers: [ReadyAnswer] = []
    private var unseenAnswers: [ReadyAnswer] {
        finishedAnswers.filter { answer in
            // Phase 9.4: only a final result lights the ready dot.
            guard answer.completion.isFinal, let baseline = lastSeenAt, Self.isNewer(answer.at, than: baseline) else { return false }
            let key = ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex).key
            // Later background events can change lastEventAt without creating a report.
            return seenAnswers[key] == nil
        }
    }
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
    /// Phase 9.3, Behavior → "Stay on the session I choose". Off (default):
    /// Quick Peek follows the newest answer of any agent; a pick only holds
    /// while the island is open. On: a pick pins its session (Phase 5 R7)
    /// and newer answers elsewhere wait behind "New in …". Existing users
    /// with a saved pin are migrated to On, so their pin is kept, never
    /// silently changed; Settings shows it and offers Follow Latest.
    public var staysOnChosenSession = false {
        didSet {
            guard staysOnChosenSession != oldValue else { return }
            stateDefaults?.set(staysOnChosenSession, forKey: Self.staysKey)
            if staysOnChosenSession {
                if selectedSessionKey != nil { pinSelection() }
            } else if sessionPinned {
                unpinSession()
            }
        }
    }
    static let staysKey = "behavior.staysOnChosenSession"
    private var lastFollowedAt: String?
    /// The user chose this project/session (Project → Session → Turn). A new
    /// answer in another session never replaces it: it shows as
    /// `newAnswerElsewhere`. Kept across launches (`selectionKey`).
    public private(set) var sessionPinned = false {
        didSet { saveSelection() }
    }
    /// The newest answer finished in a session other than the pinned one,
    /// until the user opens it or dismisses the chip.
    public var newAnswerElsewhere: ReadyAnswer? {
        // Pinned, reading another report while the island is open, or holding
        // an unfinished file transfer (Phase 9.3).
        guard holdsSelection, let answer = readyAnswer,
              answer.sessionKey != selectedSessionKey || selectedImportID != nil,
              answer.at != elsewhereAcknowledgedAt else { return nil }
        if let seen = pinnedAt, !Self.isNewer(answer.at, than: seen) { return nil }
        return answer
    }
    private var elsewhereAcknowledgedAt: String?
    /// When the pin was set: answers older than that are not "new".
    private var pinnedAt: String?
    static let selectionKey = "selection.pinned"
    /// Called once per newly arrived answer (for an optional notification).
    public var onNewAnswer: ((ReadyAnswer) -> Void)?

    public static let pollSeconds = 30
    static let lastSeenKey = "answers.lastSeenAt"
    static let seenAnswersKey = "answers.seenReports"
    let stateDefaults: UserDefaults?

    private let core: CoreProviding
    let clipboard: ClipboardService
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
        autoSelectResultAttachments = stateDefaults?.object(forKey: "attachments.autoSelectResults") as? Bool ?? true
        lastSeenAt = stateDefaults?.string(forKey: Self.lastSeenKey)
        seenAnswers = stateDefaults?.dictionary(forKey: Self.seenAnswersKey) as? [String: String] ?? [:]
        handoffs = reportStore.map(Self.loadHandoffs) ?? [:]
        imports = reportStore?.imports() ?? []
        copyHistory = Self.decode([CopyRecord].self, stateDefaults?.data(forKey: Self.copiesKey)) ?? []
        pinned = Self.decode([ReportRef].self, stateDefaults?.data(forKey: Self.pinsKey)) ?? []
        let saved = Self.decode(SavedSelection.self, stateDefaults?.data(forKey: Self.selectionKey))
        if let explicit = stateDefaults?.object(forKey: Self.staysKey) as? Bool {
            staysOnChosenSession = explicit
        } else {
            // Migration (Phase 9.3): before this setting every pick pinned.
            // A saved pin keeps that behaviour; nothing saved: Follow Latest.
            staysOnChosenSession = saved != nil
            if let defaults = stateDefaults, saved != nil { defaults.set(true, forKey: Self.staysKey) }
        }
        if let saved, staysOnChosenSession {
            selectedProjectPath = saved.projectPath
            selectedSessionKey = saved.sessionKey
            pinnedAt = saved.pinnedAt
            restoringPin = true
            sessionPinned = true
            restoringPin = false
            followsLatest = true
        }
    }

    struct SavedSelection: Codable {
        let projectPath: String?
        let sessionKey: String?
        let pinnedAt: String?
    }
    private var restoringPin = false

    private func saveSelection() {
        guard !restoringPin, let defaults = stateDefaults else { return }
        if sessionPinned, let data = try? JSONEncoder().encode(SavedSelection(projectPath: selectedProjectPath,
                                                                                sessionKey: selectedSessionKey,
                                                                                pinnedAt: pinnedAt)) {
            defaults.set(data, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }

    /// Pins the current project and session (a manual pick), when the user
    /// chose "Stay on the session I choose". Otherwise the pick only holds
    /// while a surface is open; `pinnedAt` still marks what is "new" since.
    private func pinSelection() {
        pinnedAt = readyAnswer?.at ?? pinnedAt
        guard staysOnChosenSession else { return }
        if sessionPinned { saveSelection() } else { sessionPinned = true }
    }

    public var autoSelectResultAttachments: Bool = true {
        didSet { stateDefaults?.set(autoSelectResultAttachments, forKey: "attachments.autoSelectResults") }
    }
    public let reportStore: ReportStore?
    /// The optional clipboard image history (off by default; Settings).
    public var clipboardImages: ClipboardImageHistory?
    static let clipboardHistoryKey = "clipboard.imagesEnabled"

    public var clipboardHistoryEnabled: Bool {
        get { clipboardImages?.isEnabled ?? false }
        set {
            clipboardImages?.setEnabled(newValue)
            stateDefaults?.set(newValue, forKey: Self.clipboardHistoryKey)
            if !newValue { clipboardImages?.clearAll() }
        }
    }

    // MARK: Clipboard (Text / Images)

    public enum ClipboardTab: String, CaseIterable, Sendable { case text = "Text", images = "Images" }
    /// The Clipboard view's tab; kept while the island is open.
    public var clipboardTab: ClipboardTab = .text

    public func openClipboard(_ tab: ClipboardTab) {
        clipboardTab = tab
        navigate(to: .clipboard)
    }

    static let clipboardNoticeKey = "clipboard.noticeAcknowledged"
    /// The one-time notice about the image history: shown until the user
    /// answers it. Images are kept by default, but only from the moment
    /// this notice has been shown (never silently); Turn Off clears them.
    public internal(set) var clipboardNoticeVisible = false

    /// The notice is on screen: the history starts (unless already decided).
    public func clipboardNoticeAppeared() {
        guard clipboardNoticeVisible, stateDefaults?.object(forKey: Self.clipboardHistoryKey) == nil else { return }
        clipboardHistoryEnabled = true
    }

    public func answerClipboardNotice(keepOn: Bool) {
        if !keepOn { clipboardHistoryEnabled = false }
        clipboardNoticeVisible = false
        stateDefaults?.set(true, forKey: Self.clipboardNoticeKey)
    }

    /// Copies chosen clipboard images as files under readable names.
    public func copyClipboardImages(_ items: [ClipboardImageHistory.Item]) {
        guard let history = clipboardImages else { return }
        let urls = history.exportFiles(items)
        guard urls.count == items.count, !urls.isEmpty else { finishCopy(.failed("The images could not be prepared.")); return }
        do {
            try clipboard.copyFiles(urls)
            finishCopy(.copied(.files, characters: urls.count), token: Self.clipboardImagesToken)
        } catch {
            finishCopy(.failed("The images could not be copied."))
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private var lastSeenAt: String? {
        didSet { stateDefaults?.set(lastSeenAt, forKey: Self.lastSeenKey) }
    }
    private var seenAnswers: [String: String] {
        didSet { stateDefaults?.set(seenAnswers, forKey: Self.seenAnswersKey) }
    }
    private var lastAnnouncedAt: String?

    /// The live app: the CLI adapter, the general pasteboard, the default data dir.
    public static func live() -> AppModel {
        let locator = CoreLocator()
        let model = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(),
                             dataDirectory: locator.dataDirectory, stateDefaults: .standard,
                             reportStore: ReportStore.live(dataDirectory: locator.dataDirectory))
        let history = ClipboardImageHistory.live(dataDirectory: locator.dataDirectory)
        model.clipboardImages = history
        if UserDefaults.standard.bool(forKey: clipboardHistoryKey) { history.setEnabled(true) }
        model.clipboardNoticeVisible = UserDefaults.standard.object(forKey: clipboardHistoryKey) == nil
            && !UserDefaults.standard.bool(forKey: clipboardNoticeKey)
        return model
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
        islandOpened()
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
            // Phase 9.3, Follow Latest: the next Quick Peek opens on the newest
            // answer again — unless the user pinned, or a hand-off of the
            // report shown is unfinished (it must still be there on return).
            if !staysOnChosenSession, !sessionPinned, handoffStep == nil, isOffLatest, let answer = readyAnswer {
                lastFollowedAt = answer.at
                select(answer)
                Task { await loadSessions() }
            }
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
            rawProjects = result.data.projects
            // Projects with history first (newest activity), then enabled ones without history.
            let list = Self.logicalProjects(result.data.projects).sorted { a, b in
                let da = Wording.date(a.lastEventAt) ?? .distantPast, db = Wording.date(b.lastEventAt) ?? .distantPast
                if da != db { return da > db }
                return Wording.projectName(a) < Wording.projectName(b)
            }
            projects = .loaded(list)
            // A saved folder (for example `<repo>/macos`) now belongs to its
            // logical project: keep the pick, under its new row.
            if let saved = selectedProjectPath, !list.contains(where: { $0.path == saved }),
               let owner = list.first(where: { $0.memberPaths.contains(saved) })?.path {
                selectedProjectPath = owner
                if sessionPinned { saveSelection() }
            }
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
            // The Core matches folders by prefix; a nested project of its own
            // (another enabled folder or repository) is not this one.
            let list = result.data.sessions.filter { projectPath(for: $0).map { $0 == project } ?? true }
            sessions = .loaded(list)
            if selectedSessionKey == nil || !list.contains(where: { $0.sessionKey == selectedSessionKey }) {
                selectedSessionKey = list.first?.sessionKey
                selectedTurnIndex = nil
                if sessionPinned { saveSelection() }
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
            if visibleSurfaces > 0 { acknowledgeReadyAnswer() }
            return
        }
        generation += 1
        let token = generation
        detail = .loading(previous: nil)
        do {
            let result = try await core.show(sessionKey: key, turn: index)
            guard token == generation else { return }
            detail = .loaded(result.data)
            prepareResultAttachments(result.data)
            detailWarnings = result.warnings
            if visibleSurfaces > 0 { acknowledgeReadyAnswer() }
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
        finishedAnswers = await latestFinishedAnswers(in: allSessions)
        guard let answer = finishedAnswers.first else {
            readyAnswer = nil
            return
        }
        let at = answer.at
        readyAnswer = answer
        // At launch and for each newer answer: select it, unless the user is
        // looking at something else right now.
        // A pinned session is followed only within itself: an answer from
        // another session waits behind the "New in …" chip. Phase 9.3: the
        // provider does not matter — a Claude Code answer after a Codex one
        // (or the reverse) becomes Latest the same way.
        // An unfinished hand-off of the report shown keeps it (Phase 9.3).
        if followsLatest, handoffStep == nil || currentRef == ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex),
           lastFollowedAt != at, !sessionPinned || answer.sessionKey == selectedSessionKey {
            lastFollowedAt = at
            select(answer)
        }
        guard let seen = lastSeenAt else {
            // First run: everything already captured counts as seen.
            lastSeenAt = at
            return
        }
        if Self.isNewer(at, than: seen), unseenAnswers.contains(answer) {
            if lastAnnouncedAt != at {
                lastAnnouncedAt = at
                onNewAnswer?(answer)
            }
        }
    }

    /// Finished reports, newest first. A waiting prompt retains the preceding
    /// answer. Changed sessions with several turns also load earlier unread
    /// reports; these reads use the existing cache while the session is unchanged.
    private func latestFinishedAnswers(in sessions: [SessionSummary]) async -> [ReadyAnswer] {
        // Phase 9.4: only a final result counts. A Stop that reported work in
        // flight is intermediate (kept in History) until a later turn settles
        // it; after `backgroundWaitLimit` with no continuation it is shown
        // with an unknown completion, never as a ready answer.
        func eligible(_ completion: Completion, at: String?) -> Bool {
            completion.isFinal || (completion == .waitingBackground && Self.waitExpired(at))
        }
        var answers: [ReadyAnswer] = []
        for session in sessions {
            guard let last = session.lastTurn, let lastAt = session.lastEventAt else { continue }
            var candidate: ReadyAnswer?
            if eligible(last.completion, at: last.answeredAt ?? lastAt) {
                // Completion time when the Core reports it (Phase 9.3); a later
                // tool event of the same session does not make it "newer".
                candidate = readyAnswer(session, turn: last.index, status: last.status, at: last.answeredAt ?? lastAt,
                                        completion: last.completion)
            } else if last.index > 1,
                      let turn = await cachedTurns(session).last(where: {
                          eligible($0.completion, at: $0.finalResponse?.receivedAt) && $0.finalResponse != nil }),
                      let at = turn.finalResponse?.receivedAt {
                candidate = readyAnswer(session, turn: turn.index, status: turn.status, at: at, completion: turn.completion)
            }
            if let candidate {
                answers.append(candidate)
                // Several reports can arrive before the island opens. Keep
                // earlier unread turns too, using the existing session cache.
                if let baseline = lastSeenAt, Self.isNewer(lastAt, than: baseline), candidate.turnIndex > 1 {
                    for turn in await cachedTurns(session) where turn.index < candidate.turnIndex && turn.completion.isFinal {
                        guard let at = turn.finalResponse?.receivedAt, Self.isNewer(at, than: baseline) else { continue }
                        answers.append(readyAnswer(session, turn: turn.index, status: turn.status, at: at, completion: turn.completion))
                    }
                }
            }
        }
        // Newest completion first; equal times keep a stable order (no flicker).
        return answers.sorted {
            if $0.at != $1.at { return Self.isNewer($0.at, than: $1.at) }
            return ($0.sessionKey, $0.turnIndex) < ($1.sessionKey, $1.turnIndex)
        }
    }

    /// Phase 9.4: how long a Stop with work in flight is shown as "waiting"
    /// without a continuation. Long test runs fit; a forgotten server does
    /// not keep the island waiting forever.
    static let backgroundWaitLimit: TimeInterval = 2 * 60 * 60
    static func waitExpired(_ at: String?, now: Date = Date()) -> Bool {
        guard let date = Wording.date(at) else { return true }
        return now.timeIntervalSince(date) >= backgroundWaitLimit
    }

    private func readyAnswer(_ session: SessionSummary, turn: Int, status: TurnStatus, at: String,
                             completion: Completion) -> ReadyAnswer {
        let path = projectPath(for: session) ?? session.project.path
        let name = (projects.value ?? []).first { $0.path == path && path != nil }.map(Wording.projectName)
            ?? session.logicalProject?.name ?? Wording.projectName(session.project)
        return ReadyAnswer(sessionKey: session.sessionKey, projectPath: path, projectName: name, turnIndex: turn,
                           status: status, at: at, provider: session.provider, sourceLabel: session.sourceLabel,
                           completion: completion)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let da = Wording.date(a), let db = Wording.date(b) else { return a > b }
        return da > db
    }

    /// Phase 8: what the notch's right ear shows. `Stop` means Claude
    /// stopped answering, not that the task succeeded, so nothing here says
    /// "done" or "success": only that an answer is there and not yet seen,
    /// or that Claude is still working on a prompt.
    public enum ReadyIndicator: Equatable, Sendable {
        case none
        /// A prompt is waiting for Claude in this many sessions (recently active).
        case working(sessions: Int)
        /// Phase 9.4: the agent stopped while work it started (tests, builds)
        /// was still running, in this many sessions; a follow-up is expected.
        case waitingBackground(sessions: Int)
        /// Unseen answers: how many sessions have one; whether the newest was
        /// a turn Claude Code started itself (not your request) — known only
        /// when its turns are loaded, otherwise false; whether background
        /// work was still running when it stopped.
        case ready(sessions: Int, automated: Bool, backgroundPending: Bool)
        /// Phase 9.3: capture cannot be read (the Core failed): a warning,
        /// never the green "answer available" dot.
        case attention
    }

    /// A waiting prompt older than this is not shown as work (an interrupted
    /// turn never gets a Stop and would otherwise look busy forever).
    static let workingWindow: TimeInterval = 20 * 60

    public var readyIndicator: ReadyIndicator {
        if projects.error != nil, projects.value == nil { return .attention }
        let unseen = unseenAnswers
        if let answer = unseen.first {
            let turns = answer.sessionKey == selectedSessionKey ? turns.value : turnCache[answer.sessionKey]?.turns
            // The follow-up of background work arrives in a turn the harness
            // started; it is the result of the user's task, not a side event.
            let continuesWork = turns?.contains { $0.continuedInTurn == answer.turnIndex && $0.completion == .intermediate } ?? false
            let automated = !continuesWork && turns?.first { $0.index == answer.turnIndex }?.requestOrigin == .automated
            return .ready(sessions: Set(unseen.map(\.sessionKey)).count, automated: automated,
                          backgroundPending: answer.completion == .answerBackgroundRunning)
        }
        let now = Date()
        let working = allSessions.filter {
            $0.lastTurn?.status == .awaitingResponse
                && (Wording.date($0.lastEventAt).map { now.timeIntervalSince($0) < Self.workingWindow } ?? false)
        }
        if !working.isEmpty { return .working(sessions: working.count) }
        let waiting = allSessions.filter {
            $0.lastTurn?.completion == .waitingBackground && !Self.waitExpired($0.lastTurn?.answeredAt ?? $0.lastEventAt, now: now)
        }
        return waiting.isEmpty ? .none : .waitingBackground(sessions: waiting.count)
    }

    /// Acknowledge only the selected report. The launch/migration baseline
    /// stays fixed: viewing one session must not mark another session seen.
    public func acknowledgeReadyAnswer() {
        guard selectedImportID == nil,
              let answer = finishedAnswers.first(where: {
                  $0.sessionKey == selectedSessionKey && $0.turnIndex == selectedTurnIndex
              }) else { return }
        let key = ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex).key
        if seenAnswers[key] == nil { seenAnswers[key] = answer.at }
    }

    /// Open the newest unseen answer, respecting a pinned session. Only
    /// acknowledge after the requested report actually loaded successfully.
    public func revealReadyAnswer() async {
        guard let answer = unseenAnswers.first ?? readyAnswer else { return }
        if sessionPinned, answer.sessionKey != selectedSessionKey { return }
        followsLatest = true
        lastFollowedAt = answer.at
        select(answer)
        if sessionPinned { pinnedAt = answer.at; saveSelection() }
        await loadSessions()
        if let shown = detail.value, shown.session.sessionKey == answer.sessionKey,
           shown.turn.index == answer.turnIndex { acknowledgeReadyAnswer() }
    }

    /// The "New in …" chip: open the other session's newest answer and pin it.
    public func openNewAnswerElsewhere() {
        guard let answer = newAnswerElsewhere else { return }
        elsewhereAcknowledgedAt = answer.at
        followsLatest = true
        lastFollowedAt = answer.at
        select(answer)
        pinnedAt = answer.at
        pinSelection()
        route = .home
        Task {
            await loadSessions()
            if let shown = detail.value, shown.session.sessionKey == answer.sessionKey,
               shown.turn.index == answer.turnIndex { acknowledgeReadyAnswer() }
        }
    }

    public func dismissNewAnswerElsewhere() {
        elsewhereAcknowledgedAt = newAnswerElsewhere?.at
    }

    /// Back to following the newest answer of any session (Settings or the chip menu).
    public func unpinSession() {
        sessionPinned = false
        pinnedAt = nil
        followsLatest = true
        lastFollowedAt = nil   // the current Latest is shown at once
        refresh()
    }

    /// Phase 9.3: what keeps the shown report from following Latest: a pin,
    /// browsing while a surface is open, an import, or an unfinished
    /// hand-off of this report (Persistent Handoff must not be taken away).
    public var holdsSelection: Bool {
        sessionPinned || !followsLatest || selectedImportID != nil || handoffStep != nil
    }

    /// Phase 9.3: the selection is not the newest answer (pinned or browsing).
    public var isOffLatest: Bool {
        guard let answer = readyAnswer else { return false }
        return selectedImportID != nil || answer.sessionKey != selectedSessionKey || answer.turnIndex != selectedTurnIndex
    }

    /// "Jump to Latest": open the newest answer of any agent. With "Stay on
    /// the session I choose" on, its session becomes the pinned one (the
    /// user chose it); otherwise Prompt Relay follows Latest again.
    public func jumpToLatest() {
        guard let answer = readyAnswer else { return }
        elsewhereAcknowledgedAt = answer.at
        followsLatest = true
        lastFollowedAt = answer.at
        select(answer)
        pinnedAt = answer.at
        if staysOnChosenSession { pinSelection() }
        route = .home
        Task {
            await loadSessions()
            if let shown = detail.value, shown.session.sessionKey == answer.sessionKey,
               shown.turn.index == answer.turnIndex { acknowledgeReadyAnswer() }
        }
    }

    /// Settings → Follow Latest: turn pinning off and show the newest answer.
    public func followLatestNow() {
        staysOnChosenSession = false
        if sessionPinned { unpinSession() }
        jumpToLatest()
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
        pinSelection()
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
        pinSelection()
        sessions = .idle; turns = .idle; detail = .idle
        Task { await loadSessions() }
    }

    public func selectSession(_ key: String?) {
        selectedImportID = nil
        guard key != selectedSessionKey else { if key != nil { pinSelection() }; return }
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
        /// Capture switches and Add Project (Settings → Capture).
        case capture
        /// Observed work of the current turn.
        case activity
        /// States of the open mockup.
        case mockup
        /// The optional clipboard image history.
        case clipboard
        /// The real Copy with Context text, before copying.
        case packagePreview
        /// One attachment (image, text document, PDF) opened from Details.
        case attachmentPreview
        /// The whole request of the answer (View Full Task).
        case taskReader
        /// Evidence Check, Artifact Completeness and the Review Checklist.
        case evidence
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .home: return "Answer"
            case .projects: return "Project and Session"
            case .capture: return "Capture"
            case .activity: return "Observed Work"
            case .mockup: return "Mockup States"
            case .clipboard: return "Clipboard"
            case .packagePreview: return "Preview"
            case .attachmentPreview: return "Attachment"
            case .copies: return "Recent Copies"
            case .history: return "History"
            case .importReport: return Labels.importAIResult
            case .settings: return "Settings"
            case .reader: return "Full Report"
            case .taskReader: return "Full Task"
            case .evidence: return "Evidence & Review"
            }
        }
    }

    public var route: IslandRoute = .home {
        didSet {
            // Recent Copies is the Text tab of Clipboard now (Phase 6).
            if route == .copies { clipboardTab = .text; route = .clipboard }
            // History opens with the session being read expanded.
            if route == .history, oldValue != .history { historyExpandedKey = selectedImportID == nil ? selectedSessionKey : nil }
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

    /// A system dialog started from the island (a file or folder picker) is
    /// open. The island steps aside for it and keeps its state meanwhile.
    public private(set) var isPresentingSystemDialog = false {
        didSet { if oldValue != isPresentingSystemDialog { onSystemDialog?(isPresentingSystemDialog) } }
    }
    /// Called synchronously when a dialog opens or closes, before it shows,
    /// so the island is out of the way first (set by `NotchController`).
    @ObservationIgnored var onSystemDialog: ((Bool) -> Void)?
    /// The user pressed Done on a hand-off (Relay's satisfied reaction).
    @ObservationIgnored public var onHandoffDone: (() -> Void)?
    /// Shows the system file picker; calls back with the chosen files, or
    /// nil for Cancel or Esc. Replaceable in tests.
    @ObservationIgnored public var filePicker: @MainActor (FilePickRequest, @escaping @MainActor ([URL]?) -> Void) -> Void
        = LiveFilePicker.present
    /// Brings an open picker forward (the shortcut or the menu bar while it is up).
    @ObservationIgnored public var bringFilePickerForward: @MainActor () -> Void = LiveFilePicker.bringForward

    /// Images for the report shown now. The report is remembered when the
    /// picker opens, so the images go to it even if the island changes
    /// meanwhile. One dialog at a time.
    public func chooseAttachments() {
        guard let ref = currentRef, reportStore != nil else { return }
        presentFilePicker(.images) { [weak self] urls in
            if let urls { self?.addAttachments(urls, to: ref) }
        }
    }

    /// Project folders for the list (capture stays off). Only the paths are used.
    public func chooseProjects() {
        presentFilePicker(.folders) { [weak self] urls in
            urls?.forEach { self?.addProject($0) }
        }
    }

    func presentDialog(_ request: FilePickRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        presentFilePicker(request, completion: completion)
    }

    private func presentFilePicker(_ request: FilePickRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        guard !isPresentingSystemDialog else { return }
        isPresentingSystemDialog = true
        filePicker(request) { [weak self] urls in
            completion(urls)
            self?.isPresentingSystemDialog = false
        }
    }

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
        guard let path else { return false }
        return newAnswerCount(inProject: path) > 0
    }

    /// Unseen answers whose logical project is `path` (Project and Session).
    public func newAnswerCount(inProject path: String?) -> Int {
        guard let path else { return 0 }
        return unseenAnswers.filter { $0.projectPath == path }.count
    }

    static func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The listed project a folder belongs to: exact, a logical project
    /// that merged this folder (Phase 9.3), else the longest listed root.
    func projectPath(containing path: String?) -> String? {
        guard let path else { return nil }
        let list = projects.value ?? []
        let paths = list.compactMap(\.path)
        if paths.contains(path) { return path }
        if let owner = list.first(where: { $0.memberPaths.contains(path) })?.path { return owner }
        return paths.filter { Self.path(path, isInside: $0) }.max { $0.count < $1.count }
    }

    /// The logical project a session belongs to (Phase 9.3): the Core's
    /// `logical_project` when listed, else as before by its folder.
    func projectPath(for session: SessionSummary) -> String? {
        if let logical = session.logicalProject?.path, (projects.value ?? []).contains(where: { $0.path == logical }) {
            return logical
        }
        return projectPath(containing: session.project.path)
    }

    /// Phase 9.3: one row per logical project. Folders the Core reports
    /// separately (`<repo>` and `<repo>/macos`) merge when their
    /// `logical_project` is the same; different repositories never merge.
    /// Raw rows stay in `rawProjects` (Settings → Capture).
    static func logicalProjects(_ raw: [ProjectInfo]) -> [ProjectInfo] {
        var order: [String] = []
        var groups: [String: [ProjectInfo]] = [:]
        var unknown: [ProjectInfo] = []
        for p in raw {
            guard let key = p.logicalProject?.path ?? p.path else { unknown.append(p); continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        let merged = order.map { key -> ProjectInfo in
            let members = groups[key] ?? []
            let own = members.first { $0.path == key }
            let last = members.compactMap(\.lastEventAt).max { a, b in AppModel.isNewer(b, than: a) }
            return ProjectInfo(path: key, name: members.first?.logicalProject?.name ?? own?.name ?? (key as NSString).lastPathComponent,
                               captureEnabled: members.contains { $0.captureEnabled },
                               explicitlyEnabled: own?.explicitlyEnabled ?? false,
                               sessionCount: members.reduce(0) { $0 + $1.sessionCount }, lastEventAt: last,
                               logicalProject: members.first?.logicalProject, memberPaths: members.compactMap(\.path))
        }
        return merged + unknown
    }

    // MARK: All sessions (All Responses, Recent)

    /// Every session across captured projects, newest first: the result of
    /// the same `sessions` call that finds the ready answer (no extra call).
    public private(set) var allSessions: [SessionSummary] = []
    public var providerFilter: AgentProvider? = nil
    public func matchesProvider(_ ref: ReportRef) -> Bool {
        guard let providerFilter else { return true }
        switch ref {
        case .imported: return providerFilter == .imported
        case .local(let key, _): return allSessions.first { $0.sessionKey == key }?.provider == providerFilter
        }
    }
    public func sourceLabel(for ref: ReportRef) -> String {
        switch ref {
        case .imported(let id): return "Imported by you · " + (imports.first { $0.id == id }?.assistantTitle ?? "Unknown")
        case .local(let key, _): return allSessions.first { $0.sessionKey == key }?.sourceLabel ?? "Unknown"
        }
    }


    /// Sessions grouped by project for All Responses, projects by recent activity.
    /// Phase 9.3: grouped by logical project; within a project the newest
    /// activity first (a finished answer moves its session up).
    public var sessionsByProject: [(project: String, name: String, sessions: [SessionSummary])] {
        var groups: [String: [SessionSummary]] = [:]
        var names: [String: String] = [:]
        for session in allSessions where providerFilter == nil || session.provider == providerFilter {
            let key = projectPath(for: session) ?? session.logicalProject?.path ?? session.project.path ?? "?"
            groups[key, default: []].append(session)
            names[key] = (projects.value ?? []).first { $0.path == key }.map(Wording.projectName)
                ?? session.logicalProject?.name ?? Wording.projectName(session.project)
        }
        func activity(_ s: SessionSummary) -> Date {
            [Wording.date(s.lastTurn?.answeredAt), Wording.date(s.lastEventAt)].compactMap { $0 }.max() ?? .distantPast
        }
        return groups.map { key, list in
            (project: key, name: names[key] ?? key, sessions: list.sorted {
                let a = activity($0), b = activity($1)
                return a != b ? a > b : $0.sessionKey < $1.sessionKey
            })
        }
        .sorted { a, b in
            let da = a.sessions.first.map(activity) ?? .distantPast, db = b.sessions.first.map(activity) ?? .distantPast
            return da != db ? da > db : a.name < b.name
        }
    }

    /// Phase 9.3: what a session row says about its state. Stop means the
    /// agent stopped, not that the task succeeded; `0 answers` is never shown
    /// as finished.
    public enum SessionState: Equatable, Sendable { case working, waitingBackground, answered, noAnswer, failed }
    public func sessionState(_ session: SessionSummary) -> SessionState {
        if session.running == true { return .working }
        // Phase 9.4: stopped while its own background work runs.
        if session.lastTurn?.completion == .waitingBackground,
           !Self.waitExpired(session.lastTurn?.answeredAt ?? session.lastEventAt) { return .waitingBackground }
        switch session.lastTurn?.status {
        case .apiError?: return (session.answeredCount ?? 0) > 0 ? .answered : .failed
        default: return (session.answeredCount ?? 0) > 0 ? .answered : .noAnswer
        }
    }

    /// Show a session from All Responses: its project and its newest answer
    /// become the selection (turns load for it).
    public func focusSession(_ session: SessionSummary) {
        selectedImportID = nil
        guard session.sessionKey != selectedSessionKey else { return }
        if let path = projectPath(for: session), path != selectedProjectPath {
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
               let path = projectPath(for: session), path != selectedProjectPath {
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

    /// The session whose answers History shows; nil: all collapsed. Kept by
    /// session key (never a row index), so a refresh of the list neither
    /// opens nor closes anything.
    public private(set) var historyExpandedKey: String?

    /// A click on a session row in History: a closed row opens (and closes
    /// the one open before), the open row closes. Opening also shows that
    /// session, as before.
    public func toggleHistorySession(_ session: SessionSummary) {
        if historyExpandedKey == session.sessionKey {
            historyExpandedKey = nil
        } else {
            historyExpandedKey = session.sessionKey
            focusSession(session)
        }
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
                                       projectName: name, title: Self.oneLine(turn.userRequestPreview ?? turn.finalResponse?.preview ?? ""),
                                       at: turn.finalResponse?.receivedAt))
            }
        }
        return hits.sorted { (Wording.date($0.at) ?? .distantPast) > (Wording.date($1.at) ?? .distantPast) }
    }

    static func oneLine(_ text: String) -> String {
        let text = Wording.requestForDisplay(text).text
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
    public private(set) var selectedImportID: String? { didSet { dropStaleHandoff() } }
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
    public func importReport(text: String, task: String?, projectPath: String?, sessionLabel: String?,
                             assistant: ImportAssistant? = nil, importedAs: String? = nil, host: AgentHost? = nil) -> ImportOutcome {
        guard let store = reportStore else { return .failed("Imports are not available.") }
        let name = projectPath.map { path in projectRows.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent }
        do {
            let result = try store.importReport(text: text, task: task, projectPath: projectPath, projectName: name,
                                                sessionLabel: sessionLabel, assistant: assistant?.rawValue, importedAs: importedAs, host: host)
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

    // MARK: Hand-off (two steps: text, then files)

    /// After Copy with Context with files chosen: the files still to hand
    /// over. Nothing here says the text or the files reached another app.
    /// One per report (project, session and turn are in `ref`), bound to the
    /// exact text copied and to the files chosen at that moment. Phase 7.1:
    /// it outlives closing the island, switching to another answer (it shows
    /// again on return) and a restart; only Done ends it.
    public struct HandoffStep: Codable, Equatable, Sendable {
        public let ref: ReportRef
        /// The package text that was put on the clipboard, for Copy Text Again.
        public let text: String
        public var characters: Int { CharacterCount.of(text) }
        /// The chosen files at the moment of the copy, in hand-off order.
        public let attachmentIDs: [String]
        public var fileCount: Int { attachmentIDs.count }
        /// Set once the files were put on the clipboard (not "sent").
        public var filesCopied = false
        /// The pasteboard's change count right after our text write.
        public var textChangeCount: Int?
        /// The island closed while it was open: shown as "Continue Transfer".
        public var resumed = false
    }
    /// Unfinished hand-offs by `ReportRef.key`.
    public internal(set) var handoffs: [String: HandoffStep] = [:] {
        didSet { if handoffs != oldValue { saveHandoffs() } }
    }
    /// The hand-off of the report shown now.
    public internal(set) var handoffStep: HandoffStep? {
        get { currentRef.flatMap { handoffs[$0.key] } }
        set { if let key = currentRef?.key { handoffs[key] = newValue } }
    }
    /// The Task card is expanded (Details); collapses for another answer.
    public var taskExpanded = false
    /// The attachment open in the attachment preview.
    public internal(set) var previewAttachmentID: String?

    /// The hand-off of the report shown now; nil for any other report.
    public var activeHandoff: HandoffStep? { handoffStep }

    /// The clipboard no longer holds the text of the hand-off shown (another
    /// copy replaced it, here or in another app): offer Copy Text Again.
    public var handoffTextReplaced: Bool {
        guard let step = activeHandoff, let count = step.textChangeCount else { return false }
        _ = clipboardTick
        return clipboard.changeCount != count && !step.filesCopied
    }
    /// Bumped when the island opens, so the clipboard check above is redone.
    var clipboardTick = 0

    /// The files chosen for the report changed after its text was copied:
    /// the old set is not handed over silently.
    public var handoffSelectionChanged: Bool {
        guard let step = activeHandoff else { return false }
        return handoffAttachments(for: step.ref).map(\.id) != step.attachmentIDs
    }

    /// Ends a hand-off that no longer belongs to the report shown.
    func dropStaleHandoff() {
        // Hand-offs of other answers are kept (Phase 7.1) and show again on return.
        if let preview = packPreview, preview.ref != currentRef { packPreview = nil }
        if taskExpanded, lastShownRef != currentRef { taskExpanded = false }
        lastShownRef = currentRef
    }
    @ObservationIgnored private var lastShownRef: ReportRef?
    /// The mockup whose states are open (route `.mockup`).
    public internal(set) var openMockupID: String?

    // MARK: Attachments

    /// Bumped on every change so views showing attachments refresh.
    public internal(set) var attachmentsVersion = 0
    public internal(set) var attachmentMessage: String?

    public func attachments(for ref: ReportRef?) -> [ReportAttachment] {
        _ = attachmentsVersion
        guard let ref, let store = reportStore else { return [] }
        return store.attachments(for: ref)
    }

    public func attachmentURL(_ attachment: ReportAttachment) -> URL? { reportStore?.fileURL(for: attachment) }

    /// Images the user chose in the file picker, copied into Prompt Relay's
    /// private folder for the current report. Nothing else is read.
    public func addAttachments(_ urls: [URL]) {
        guard let ref = currentRef else { return }
        addAttachments(urls, to: ref)
    }

    public func addAttachments(_ urls: [URL], to ref: ReportRef) {
        guard let store = reportStore else { return }
        var problems: [String] = []
        for url in urls {
            do { try store.addAttachment(from: url, to: ref) } catch let error as ReportStoreError {
                problems.append(Self.message(for: error, file: url.lastPathComponent))
            } catch {
                problems.append("\(url.lastPathComponent) could not be read")
            }
        }
        attachmentMessage = problems.isEmpty ? nil : problems.joined(separator: "; ")
        attachmentsVersion += 1
    }

    static func message(for error: ReportStoreError, file: String) -> String {
        switch error {
        case .notAnImage(let name): return "\(name) is not an image"
        case .tooLarge(let name): return "\(name) is larger than 50 MB"
        case .noPermission(let name): return "\(name) could not be read: no permission"
        case .damagedImage(let name): return "\(name) is damaged or not a readable image"
        case .unreadable(let name): return "\(name) could not be read"
        case .writeFailed: return "\(file) could not be saved in Prompt Relay's folder"
        case .removeFailed: return "The image could not be removed"
        case .empty: return "\(file) is empty"
        case .unsupported(let name): return "\(name) is not a document, PDF or image Prompt Relay can keep"
        }
    }

    /// Unlinks one image from the report. The report's text and its other
    /// images stay as they are.
    public func removeAttachment(_ attachment: ReportAttachment) {
        do {
            try reportStore?.removeAttachment(attachment.id)
            attachmentMessage = nil
        } catch {
            attachmentMessage = "\(attachment.originalFilename) could not be removed. Try again."
        }
        attachmentsVersion += 1
    }

    /// Copies one attachment as an image (PNG/TIFF data and its file).
    public func copyAttachment(_ attachment: ReportAttachment) {
        guard let file = handoffFiles([attachment]).first else { finishCopy(.failed("The image file is missing.")); return }
        do {
            try clipboard.copyImage(at: file)
            finishCopy(.copied(.image, characters: 0), token: Self.attachmentToken(attachment.id))
        } catch {
            finishCopy(.failed("The image could not be copied."))
        }
    }

    /// Copies attachments as files (like ⌘C in Finder), under their original
    /// names: for apps that take pasted files rather than image data.
    public func copyAttachmentFiles(_ attachments: [ReportAttachment]) {
        let files = handoffFiles(attachments)
        guard !files.isEmpty else { finishCopy(.failed("The image files are missing.")); return }
        do {
            try clipboard.copyFiles(files)
            finishCopy(.copied(.files, characters: files.count), token: attachments.count == 1 ? Self.attachmentToken(attachments[0].id) : nil)
        } catch {
            finishCopy(.failed("The files could not be copied."))
        }
    }

    /// The report's images in a Finder window, selected, under their
    /// original names: drag them into ChatGPT after pasting the text.
    public func revealAttachmentsForHandoff(_ attachments: [ReportAttachment]) {
        let files = handoffFiles(attachments)
        guard !files.isEmpty else { attachmentMessage = "The image files are missing."; return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// A file URL for dragging one image out (original name), or nil.
    public func dragFile(for attachment: ReportAttachment) -> URL? { handoffFiles([attachment]).first }

    /// Hand-off copies under the original names; missing images are skipped.
    func handoffFiles(_ attachments: [ReportAttachment]) -> [URL] {
        guard let store = reportStore else { return [] }
        do { return try store.handoffFiles(for: attachments) } catch {
            attachmentMessage = "Prompt Relay could not prepare the files."
            return []
        }
    }

    /// Text and images in one clipboard write. Whether a paste carries the
    /// images depends on the destination app (see docs/MACOS_APP.md).
    public func copyResponseWithImages() async {
        guard let ref = currentRef else { return }
        guard let text = await fullText(for: ref) else { return }
        let urls = handoffFiles(attachments(for: ref))
        do {
            try clipboard.copy(text, images: urls)
            finishCopy(.copied(.responseWithImages, characters: text.unicodeScalars.count), token: Self.answerToken(ref))
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

    func record(_ kind: CopyRecord.Kind, ref: ReportRef, characters: Int) {
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
            // The enabled project's name, not the folder Claude ran in (a subfolder).
            let root = session.flatMap { projectPath(containing: $0.project.path) }
            let project = root.flatMap { r in projectRows.first { $0.path == r }?.name }
                ?? session.map { Wording.projectName($0.project) } ?? selectedProject.map(Wording.projectName) ?? "Claude Code"
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

    public func removeCopyRecord(_ record: CopyRecord) { copyHistory.removeAll { $0.id == record.id } }

    /// One line to recognise a copy by: the task (or, for an import without
    /// one, the text), when it is at hand. Display only; nothing is stored.
    public func copyPreview(_ record: CopyRecord) -> String? {
        switch record.ref {
        case .imported(let id):
            return imports.first { $0.id == id }.map { Self.oneLine($0.task ?? $0.text) }
        case .local(let key, let index):
            guard key == selectedSessionKey, let turn = turns.value?.first(where: { $0.index == index }) else { return nil }
            return turn.userRequestPreview.map(Self.oneLine)
        }
    }

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

    /// The Core's rows, one per folder (before logical merging): capture
    /// switches stay per folder.
    public private(set) var rawProjects: [ProjectInfo] = []

    public var projectRows: [ProjectRow] {
        let core = rawProjects.compactMap { p -> ProjectRow? in
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

    /// Checks the Core and capture storage without launching an AI turn.
    /// Stored events are evidence of past capture, not proof of a live subscription.
    public func testIntegrationConnection() async -> String {
        do {
            let result = try await core.doctor().data
            doctor = .loaded(result)
            let sessions = try await core.sessions(project: nil).data.sessions
            // Connection checks must publish the same fresh evidence the status rows use.
            allSessions = sessions.sorted {
                (Wording.date($0.lastEventAt) ?? .distantPast) > (Wording.date($1.lastEventAt) ?? .distantPast)
            }
            let failures = result.findings.filter { $0.level == "error" }.map(\.message)
            if let error = result.capture.configError { return "Capture configuration error: \(error)" }
            if !failures.isEmpty { return failures.joined(separator: "\n") }
            guard result.storage.writable else { return "Capture storage is not writable." }
            let codex = sessions.filter { $0.provider == .codex }.count
            return "Core responds; capture storage is writable. \(result.capture.enabledProjects.count) projects enabled; \(codex) Codex sessions recorded. This checks storage and recorded history, not a new AI turn. See Xcode delivery stages above."
        } catch {
            return "Connection check failed: \(Self.coreError(error).localizedDescription)"
        }
    }

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
            finishCopy(.copied(.response, characters: text.unicodeScalars.count), token: Self.answerToken(ref))
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
        switch await buildPack(ref) {
        case .success(let pack): deliver(pack)
        case .failure(let failure): finishCopy(.failed(failure.message))
        }
    }

    /// Copy with Context, built once: the same text is what Preview shows and
    /// what the copy puts on the clipboard. Git state and the export time are
    /// read when it is built (the Core's `context`), so a copy from Preview
    /// copies that snapshot, not a newer one.
    public struct BuiltPack: Equatable, Sendable {
        public let ref: ReportRef
        public let text: String
        public let findings: [SensitiveFinding]
        public let builtAt: String
        /// The attachments chosen when it was built (their names are in the text).
        public let attachmentIDs: [String]
        /// The detail level it was built at.
        public var detail: ContextDetail = .full
    }

    public struct PackFailure: Error, Equatable { public let message: String }

    /// The one builder for Copy with Context: the Core's packet for a local
    /// report (or the app's for an import) plus the chosen attachments.
    public func buildPack(_ ref: ReportRef) async -> Result<BuiltPack, PackFailure> {
        await buildPack(ref, detail: contextDetail)
    }

    public func buildPack(_ ref: ReportRef, detail: ContextDetail) async -> Result<BuiltPack, PackFailure> {
        if case .local(let key, let turn) = ref, autoSelectResultAttachments {
            if let shown = try? await core.show(sessionKey: key, turn: turn) { prepareResultAttachments(shown.data) }
        }
        let attached = attachments(for: ref).filter(\.isSelected)
        let selectedMaterials = materials(for: ref).filter(\.selected)
        let names = handoffNames(for: ref)
        let ids = handoffAttachments(for: ref).map(\.id)
        let builtAt = ReportStore.now()
        switch ref {
        case .imported(let id):
            guard let report = imports.first(where: { $0.id == id }) else {
                return .failure(PackFailure(message: "This report is no longer in Prompt Relay's history."))
            }
            let text = ReviewPack.render(imported: report, attachments: attached, exportedAt: builtAt,
                                         materials: selectedMaterials, names: names)
            let findings = SecretScanner.scan(report.task ?? "", section: "request") + SecretScanner.scan(report.text, section: "response")
            // An import has no commands or Git state: both levels are the same text.
            return .success(BuiltPack(ref: ref, text: text, findings: findings, builtAt: builtAt, attachmentIDs: ids, detail: detail))
        case .local(let key, let index):
            do {
                let result = try await core.context(sessionKey: key, turn: index, detail: detail)
                let text = ReviewPack.render(local: result.data.text, attachments: attached, materials: selectedMaterials, names: names)
                return .success(BuiltPack(ref: ref, text: text, findings: result.data.sensitiveFindings, builtAt: builtAt,
                                          attachmentIDs: ids, detail: detail))
            } catch {
                return .failure(PackFailure(message: Self.message(for: error)))
            }
        }
    }

    /// Puts a built package on the clipboard under the same rules for every
    /// path: likely secrets wait for confirmation, then step 2 for the files.
    func deliver(_ pack: BuiltPack) {
        if !pack.findings.isEmpty {
            pendingSensitiveContext = PendingSensitiveCopy(text: pack.text, sensitiveFindings: pack.findings, ref: pack.ref)
            copyFeedback = .idle
            return
        }
        do {
            try clipboard.copy(pack.text)
            finishCopy(.copied(.context, characters: pack.text.unicodeScalars.count), token: Self.reviewToken(pack.ref))
            record(.reviewPack, ref: pack.ref, characters: pack.text.unicodeScalars.count)
            beginHandoff(ref: pack.ref, text: pack.text)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    // MARK: Preview of Copy with Context

    public enum PackPreview: Equatable {
        case loading(ReportRef)
        case ready(BuiltPack)
        case failed(ReportRef, String)
        var ref: ReportRef {
            switch self { case .loading(let r), .failed(let r, _): return r; case .ready(let p): return p.ref }
        }
    }
    /// The preview of the report shown; dropped when another report is shown.
    public internal(set) var packPreview: PackPreview?

    /// The folder the last Export Bundle went to (Show in Finder).
    public var lastExportFolder: URL?

    /// Bumped when the user's check marks change, so views redraw.
    var reviewChecksVersion = 0

    /// Phase 7.2: Copy with Context is always Full, the most complete
    /// package; the owner asked for no choice in the interface. (The Core
    /// keeps `--detail standard` for other callers; the app never uses it,
    /// and an older saved "Standard" choice is ignored.)
    public let contextDetail: ContextDetail = .full

    private func rebuildPreview(_ ref: ReportRef) async {
        packPreview = .loading(ref)
        switch await buildPack(ref) {
        case .success(let pack): if packPreview?.ref == ref { packPreview = .ready(pack) }
        case .failure(let f): if packPreview?.ref == ref { packPreview = .failed(ref, f.message) }
        }
    }

    /// Builds the package for the report shown and opens its preview.
    public func openPackPreview() async {
        guard let ref = currentRef else { return }
        packPreview = .loading(ref)
        navigate(to: .packagePreview)
        switch await buildPack(ref) {
        case .success(let pack): if packPreview?.ref == ref { packPreview = .ready(pack) }
        case .failure(let f): if packPreview?.ref == ref { packPreview = .failed(ref, f.message) }
        }
    }

    /// The chosen files changed since the preview was built.
    public var previewSelectionChanged: Bool {
        guard case .ready(let pack)? = packPreview else { return false }
        return handoffAttachments(for: pack.ref).map(\.id) != pack.attachmentIDs
    }

    /// The visible snapshot is the only text this action may copy. A changed
    /// selection requires an explicit refresh, never a hidden export rebuild.
    public func copyPreviewedPack() async {
        guard case .ready(let pack)? = packPreview, pack.ref == currentRef else { return }
        guard !previewSelectionChanged, pack.detail == contextDetail else {
            copyFeedback = .failed("Attachments changed. Refresh Preview before copying.")
            return
        }
        copyFeedback = .working(.context)
        deliver(pack)
    }

    public func refreshPackPreview() async {
        guard let ref = currentRef else { return }
        await rebuildPreview(ref)
    }

    func copyObservedCommand(_ command: ObservedCommand) {
        guard let text = CommandDiagnostics.safeText(command) else { return }
        do { try clipboard.copy(text) }
        catch { copyFeedback = .failed(Self.message(for: error)) }
    }

    /// The user reviewed the findings and still wants the pack copied. It is
    /// not added to Recent Copies: a pack with possible secrets is never kept
    /// for one-click re-copying.
    public func confirmSensitiveContextCopy() {
        guard let pending = pendingSensitiveContext else { return }
        pendingSensitiveContext = nil
        do {
            try clipboard.copy(pending.text)
            finishCopy(.copied(.context, characters: pending.text.unicodeScalars.count), token: Self.reviewToken(pending.ref))
            beginHandoff(ref: pending.ref, text: pending.text)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    public func cancelSensitiveContextCopy() {
        pendingSensitiveContext = nil
    }

    /// What the last successful copy was ("answer|<report>", "review|…",
    /// "files|…"): each button shows "Copied!" only for its own copy, and
    /// only after the clipboard read-back confirmed it.
    public private(set) var copiedToken: String?

    public func isCopied(_ token: String) -> Bool { copiedToken == token }

    public static func answerToken(_ ref: ReportRef?) -> String { "answer|\(ref?.key ?? "-")" }
    public static func reviewToken(_ ref: ReportRef?) -> String { "review|\(ref?.key ?? "-")" }
    static let handoffToken = "files|handoff"
    static let clipboardImagesToken = "files|clipboard"
    static func attachmentToken(_ id: String) -> String { "files|\(id)" }

    func finishCopy(_ feedback: CopyFeedback, token: String? = nil) {
        copyFeedback = feedback
        if case .copied = feedback { copiedToken = token } else { copiedToken = nil }
        feedbackReset?.cancel()
        // "Copied!" for 2 s; a failure stays long enough to be read.
        let seconds: UInt64 = { if case .failed = feedback { return 6 } else { return 2 } }()
        feedbackReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.copyFeedback = .idle
            self?.copiedToken = nil
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

/// What the system file picker offers.
public enum FilePickRequest: Equatable, Sendable {
    /// Images to keep with a report.
    case images
    /// Project folders (only their paths are used).
    case folders
    /// Documents, PDFs and images to keep with a report.
    case files
    /// The folder an Export Bundle is written into (Phase 7).
    case exportFolder
}

/// The system `NSOpenPanel`, as its own window with the keyboard: the island
/// is out of the way while it is up (see `NotchController`).
@MainActor
public enum LiveFilePicker {
    /// The dialog on screen, if any.
    private static weak var current: NSOpenPanel?

    /// Brings the open dialog to the front again (it may have gone behind
    /// another app's windows meanwhile).
    public static func bringForward() {
        guard let current, current.isVisible else { return }
        NSApp.activate()
        current.makeKeyAndOrderFront(nil)
    }

    public static func present(_ request: FilePickRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        switch request {
        case .images:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            panel.message = "Choose images to keep with this report."
        case .folders:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.message = "Choose project folders. Capture stays off until you turn it on."
        case .files:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .commaSeparatedText, .xml, .html, .yaml]
            panel.message = "Choose documents, PDFs or images to keep with this report (snapshots)."
        case .exportFolder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export Here"
            panel.message = "Choose a folder. A new folder with the package, the chosen files and a manifest is created inside it."
        }
        // Prompt Relay is an agent app whose island is a non-activating
        // panel: the click on 📎 did not make it the active app. The dialog
        // needs an active app to get the keyboard; activating in response to
        // that click is allowed under cooperative activation.
        current = panel
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.urls : nil) }
        }
        panel.makeKeyAndOrderFront(nil)
    }
}
