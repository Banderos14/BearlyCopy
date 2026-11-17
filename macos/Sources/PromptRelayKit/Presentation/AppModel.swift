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
        /// Where the agent ran, only when the hook recorded it.
        public var host: AgentHost = .unknown
        /// Phase 14: the local profile (config folder), or `unassigned`.
        public var profileID: String = ProfileKey.unassigned
    }

    public private(set) var readyAnswer: ReadyAnswer?
    /// A newer answer arrived since the user last opened a surface.
    public var hasUnseenAnswer: Bool { !unseenAnswers.isEmpty }
    var finishedAnswers: [ReadyAnswer] = []
    var unseenAnswers: [ReadyAnswer] {
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
    /// Phase 19: the Quick Tour's page and a counter that refreshes `tourSeen`.
    public var tourPage = 0
    public var tourVersion = 0
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
    /// Phase 12.1: called once per new wait for the person (optional notification).
    public var onNeedsInput: ((WaitingAgent) -> Void)?
    @ObservationIgnored var announcedWaits: Set<String> = []
    @ObservationIgnored var waitsBaselineTaken = false

    public static let pollSeconds = 30
    static let lastSeenKey = "answers.lastSeenAt"
    static let seenAnswersKey = "answers.seenReports"
    let stateDefaults: (any SettingsStore)?

    let core: CoreProviding
    let clipboard: ClipboardService
    private let dataDirectory: URL?
    private var watcher: StoreWatcher?
    private var pollTimer: Timer?
    private var refreshing = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var feedbackReset: Task<Void, Never>?
    var visibleSurfaces = 0

    /// `stateDefaults` remembers which answer was last seen, so a restart
    /// does not announce old answers again (nil in tests: nothing persisted).
    /// `reportStore` keeps imported reports and attachments (nil: imports
    /// are unavailable, e.g. in most tests).
    public init(core: CoreProviding, clipboard: ClipboardService, dataDirectory: URL?,
                stateDefaults: (any SettingsStore)? = nil, reportStore: ReportStore? = nil) {
        self.core = core
        self.clipboard = clipboard
        self.dataDirectory = dataDirectory
        self.stateDefaults = stateDefaults
        self.reportStore = reportStore
        autoSelectResultAttachments = stateDefaults?.object(forKey: "attachments.autoSelectResults") as? Bool ?? true
        autoSelectPreparedAttachments = stateDefaults?.object(forKey: Self.autoSelectPreparedKey) as? Bool ?? true
        autoCaptureFinalWindow = stateDefaults?.bool(forKey: Self.autoCaptureKey) ?? false
        autoScreenshotsInHandoff = stateDefaults?.bool(forKey: Self.autoCaptureHandoffKey) ?? false
        autoLinkWindowEnabled = (stateDefaults?.object(forKey: Self.autoLinkKey) as? Bool) ?? true
        lastSeenAt = stateDefaults?.string(forKey: Self.lastSeenKey)
        seenAnswers = stateDefaults?.dictionary(forKey: Self.seenAnswersKey) as? [String: String] ?? [:]
        notchAcknowledgedAt = stateDefaults?.string(forKey: Self.notchAckKey)
        handoffs = reportStore.map(Self.loadHandoffs) ?? [:]
        loadPackDraft()
        handoffHistory = reportStore.map(Self.loadHandoffHistory) ?? []
        imports = reportStore?.imports() ?? []
        copyHistory = Self.decode([CopyRecord].self, stateDefaults?.data(forKey: Self.copiesKey)) ?? []
        expandedConversations = Set(stateDefaults?.stringArray(forKey: Self.expandedConversationsKey) ?? [])
        pinned = Self.decode([ReportRef].self, stateDefaults?.data(forKey: Self.pinsKey)) ?? []
        workspaceMode = (stateDefaults?.string(forKey: Self.workspaceModeKey)).flatMap(WorkspaceMode.init(rawValue:)) ?? .byProject
        profileLabels = stateDefaults?.dictionary(forKey: Self.profileLabelsKey) as? [String: String] ?? [:]
        browsingProfile = Self.decode(ProfileKey.self, stateDefaults?.data(forKey: Self.browsingProfileKey))
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
    /// Phase 17: files BearlyCopy prepared are ticked for Copy with
    /// Context and drag (on by default). Off: prepared, listed, unticked.
    public var autoSelectPreparedAttachments: Bool = true {
        didSet { stateDefaults?.set(autoSelectPreparedAttachments, forKey: Self.autoSelectPreparedKey) }
    }
    static let autoSelectPreparedKey = "attachments.autoSelectPrepared"
    // Phase 17, Daily Use (AppModel+DailyUse).
    /// Bumped when something the readiness status reads outside observation changes.
    var dailyUseVersion = 0
    /// The setup card is open (Settings → Daily Use → Set Up…).
    public var dailySetupOpen = false
    public internal(set) var dailyUseOutcome: DailyUseSetupOutcome?
    public internal(set) var dailyUseNotice: String?
    /// The Core version this build bundled (nil outside an app bundle; tests set it).
    @ObservationIgnored lazy var bundledCoreVersion: String? = AppBuild.launchStamp.coreVersion
    @ObservationIgnored var arrivalBaseline: Date?
    @ObservationIgnored var arrivalPrepared: Set<String> = []
    @ObservationIgnored var arrivalTasks: [Task<Void, Never>] = []
    @ObservationIgnored var driftCache: [String: (stamp: String, drift: SnapshotDrift)] = [:]
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

    var lastSeenAt: String? {
        didSet { stateDefaults?.set(lastSeenAt, forKey: Self.lastSeenKey) }
    }
    var seenAnswers: [String: String] {
        didSet { stateDefaults?.set(seenAnswers, forKey: Self.seenAnswersKey) }
    }
    private var lastAnnouncedAt: String?

    /// The live app: the CLI adapter, the general pasteboard, the default data dir.
    public static func live() -> AppModel {
        let locator = CoreLocator()
        let model = AppModel(core: CoreClient.live(locator: locator), clipboard: ClipboardService(),
                             dataDirectory: locator.dataDirectory, stateDefaults: UserDefaults.standard,
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

    /// Phase 9.4: a turn the user sees as an answer (Answer carousel, its
    /// count, History, search, Copy Answer): a final result, an API error, or
    /// a background wait that expired with no continuation (shown with an
    /// unknown completion). An intermediate Stop ("waiting for the tests") is
    /// kept for correlation and diagnostics only.
    nonisolated public static func isVisibleAnswer(_ turn: Turn) -> Bool {
        if turn.status == .apiError { return true }
        guard turn.finalResponse != nil else { return false }
        switch turn.completion {
        case .answer, .answerBackgroundRunning: return true
        case .waitingBackground: return waitExpired(turn.finalResponse?.receivedAt)
        default: return false
        }
    }

    /// Why Copy Response is unavailable for a turn, or nil when it can copy.
    nonisolated public static func copyBlocker(for turn: Turn) -> String? {
        switch turn.completion {
        case .intermediate: return "An intermediate message; the final answer came in a later turn."
        case .waitingBackground where !waitExpired(turn.finalResponse?.receivedAt):
            return "The agent is waiting for its background work; the final answer has not arrived."
        default: break
        }
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
        acknowledgeNotch()
        islandOpened()
        if visibleSurfaces == 0 { followLatestOnOpen() }
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
            closedHoldUntil = nil
            // An explicit pin is the only thing that outlives closing for good.
            if staysOnChosenSession || sessionPinned {
                followsLatest = true
                if !isOffLatest { deferredLatest = nil }
                return
            }
            // Phase 17: closing the island returns to Latest. Two short,
            // bounded exceptions keep the report in hand (see
            // `closedHoldActive`): an older report being read in Details
            // (the pointer slipped off) and a file hand-off just started.
            if detailsPreferred, !followsLatest, isOffLatest {
                closedHoldUntil = clock().addingTimeInterval(Self.readingGrace)
            }
            if closedHoldActive(now: clock()) {
                if !isOffLatest { followsLatest = true; deferredLatest = nil }
                return
            }
            followLatestWhileClosed()
        }
    }

    // MARK: Following Latest while the island is closed (Phase 17)

    /// How long an older report read in Details survives an accidental
    /// close. After that, reopening shows the newest answer.
    nonisolated static let readingGrace: TimeInterval = 90
    /// How long a file hand-off that was just started (text copied, files
    /// still to drag) keeps its report while the island is closed. Before
    /// Phase 17 an unfinished hand-off held its report forever, so one
    /// forgotten "Done" pinned an old answer across every reopen.
    nonisolated static let handoffHoldWindow: TimeInterval = 10 * 60
    /// Set at close (reading grace) or by a pick made while closed (a
    /// notification, the menu bar): the selection is kept until then.
    @ObservationIgnored var closedHoldUntil: Date?

    /// The island is closed and the report shown must still be there when it
    /// reopens. Never true for long: both reasons expire on their own.
    func closedHoldActive(now: Date) -> Bool {
        if let until = closedHoldUntil, until > now { return true }
        if let step = handoffStep, !step.filesCopied, let started = step.startedAt,
           now.timeIntervalSince(started) < Self.handoffHoldWindow { return true }
        return false
    }

    /// Points the selection at the newest answer (closed island, no pin).
    private func followLatestWhileClosed() {
        followsLatest = true
        deferredLatest = nil
        guard isOffLatest, let answer = readyAnswer else { return }
        lastFollowedAt = answer.at
        select(answer)
        Task { await loadSessions() }
    }

    /// Opening the island: the newest completed answer, unless the user
    /// pinned a conversation or a short hold is still running. Decided here
    /// (not from "unseen" marks): an older answer that was never opened must
    /// not win over a newer one that was.
    private func followLatestOnOpen() {
        defer { closedHoldUntil = nil }
        guard !staysOnChosenSession, !sessionPinned, !closedHoldActive(now: clock()) else { return }
        followLatestWhileClosed()
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
                if inboxOnScreen { await loadInbox() }
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
            captureSettings = result.data.settings.capture
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

    func loadSessions() async {
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
                // Default: the newest visible final answer, else the newest turn.
                selectedTurnIndex = list.last(where: { Self.isVisibleAnswer($0) && Self.copyBlocker(for: $0) == nil })?.index
                    ?? list.last?.index
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
            // Phase 17: also when the selection moved on without a new load
            // having started yet — a late answer never lands on another report.
            guard token == generation, key == selectedSessionKey, index == selectedTurnIndex else { return }
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
        announceNewWaits()
        // Phase 14: every new final answer, of any agent, whether the island
        // is open or not (before: only the newest unseen one).
        autoLinkWorkingWindows()
        autoCaptureNewFinals()
        prepareNewFinals()
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
        // Phase 17: with the island closed nothing but a pin or a running
        // short hold keeps an older report (a stale hand-off no longer does).
        let closedAndFree = visibleSurfaces == 0 && !staysOnChosenSession && !sessionPinned && !closedHoldActive(now: clock())
        if closedAndFree { followsLatest = true }
        let closedAndHeld = visibleSurfaces == 0 && closedHoldActive(now: clock())
        if closedAndHeld, currentRef != ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex) {
            deferredLatest = answer
        } else if followsLatest,
           closedAndFree || handoffStep == nil || currentRef == ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex),
           lastFollowedAt != at || (closedAndFree && isOffLatest), !sessionPinned || answer.sessionKey == selectedSessionKey {
            if isReadingReport, lastFollowedAt != nil, currentRef != ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex) {
                // Phase 12: the user is reading an answer on screen. A newer
                // one (any agent) never replaces it mid-read: it waits
                // behind "New in …" / the Inbox, and Follow Latest moves on
                // when the island closes.
                deferredLatest = answer
                followsLatest = false
            } else {
                lastFollowedAt = at
                deferredLatest = nil
                select(answer)
            }
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
    nonisolated static let backgroundWaitLimit: TimeInterval = 2 * 60 * 60
    nonisolated static func waitExpired(_ at: String?, now: Date = Date()) -> Bool {
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
                           completion: completion, host: session.source?.environment ?? .unknown,
                           profileID: session.profile?.id ?? ProfileKey.unassigned)
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
        /// Phase 12.1: an agent waits for the person (question, plan,
        /// permission) in this many sessions. A static amber dot; it never
        /// means an answer is ready. `confirmed` false: no wait can be
        /// confirmed any more (old signal, or the agent moved on in another
        /// session) — an amber ring, never removed by time.
        case needsInput(sessions: Int, confirmed: Bool)
    }

    /// A waiting prompt older than this is not shown as work (an interrupted
    /// turn never gets a Stop and would otherwise look busy forever).
    static let workingWindow: TimeInterval = 20 * 60

    /// Phase 16: the time `readyIndicator` and Needs Input judge against
    /// (tests pin it; the app uses the wall clock).
    @ObservationIgnored var clock: () -> Date = Date.init

    public var readyIndicator: ReadyIndicator {
        if projects.error != nil, projects.value == nil { return .attention }
        // Phase 12.1: an agent blocked on the person comes first; the other
        // agents keep their states in Workspace, Inbox and History.
        let waitingForPerson = agentsNeedingInput
        if !waitingForPerson.isEmpty {
            return .needsInput(sessions: waitingForPerson.count, confirmed: waitingForPerson.contains(where: \.confirmed))
        }
        // Phase 10: the notch asks for attention only for answers that
        // arrived after the island was last opened. Opening it is looking at
        // Latest; unread answers of other conversations stay marked in
        // Project and Session and History, but no longer keep a green dot
        // and a session count ("7") on the notch indefinitely.
        let unseen = unseenAnswers.filter { answer in
            notchAcknowledgedAt.map { Self.isNewer(answer.at, than: $0) } ?? true
        }
        if let answer = unseen.first {
            let turns = answer.sessionKey == selectedSessionKey ? turns.value : turnCache[answer.sessionKey]?.turns
            // The follow-up of background work arrives in a turn the harness
            // started; it is the result of the user's task, not a side event.
            let continuesWork = turns?.contains { $0.continuedInTurn == answer.turnIndex && $0.completion == .intermediate } ?? false
            let automated = !continuesWork && turns?.first { $0.index == answer.turnIndex }?.requestOrigin == .automated
            return .ready(sessions: Set(unseen.map(\.sessionKey)).count, automated: automated,
                          backgroundPending: answer.completion == .answerBackgroundRunning)
        }
        let now = clock()
        let working = allSessions.filter {
            $0.attention == nil && $0.lastTurn?.status == .awaitingResponse
                && (Wording.date($0.lastEventAt).map { now.timeIntervalSince($0) < Self.workingWindow } ?? false)
        }
        if !working.isEmpty { return .working(sessions: working.count) }
        let waiting = allSessions.filter {
            $0.lastTurn?.completion == .waitingBackground && !Self.waitExpired($0.lastTurn?.answeredAt ?? $0.lastEventAt, now: now)
        }
        return waiting.isEmpty ? .none : .waitingBackground(sessions: waiting.count)
    }

    /// Phase 10: the newest final answer known when the island opened. Only
    /// answers newer than this light the notch dot again. Persisted, so a
    /// restart does not bring back a dot for answers already looked at.
    private(set) var notchAcknowledgedAt: String? {
        didSet { stateDefaults?.set(notchAcknowledgedAt, forKey: Self.notchAckKey) }
    }
    static let notchAckKey = "answers.notchAcknowledgedAt"

    func acknowledgeNotch() {
        guard let newest = finishedAnswers.first(where: { $0.completion.isFinal })?.at else { return }
        if notchAcknowledgedAt.map({ Self.isNewer(newest, than: $0) }) ?? true { notchAcknowledgedAt = newest }
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
        // Phase 17: the newest answer, never "the newest unopened one" — an
        // older answer in a conversation that was never opened used to
        // replace the newest answer on every reopen. Unopened answers stay
        // marked unread in the Inbox and in Project and Session.
        guard let answer = readyAnswer else { return }
        if sessionPinned, answer.sessionKey != selectedSessionKey { return }
        // A report kept on purpose (a pick, a hold) is not taken away here.
        if !sessionPinned, isOffLatest, !followsLatest || handoffStep != nil { return }
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
    /// Phase 9.4: the island reopens on Details (set by the notch
    /// controller). Closing it then keeps the report being read.
    public var detailsPreferred = false

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
    /// user chose it); otherwise BearlyCopy follows Latest again.
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

    /// Phase 17, "Stay on this conversation": the one deliberate action that
    /// pins. An ordinary pick never does; the pin is kept across launches
    /// and shown on Home until Follow Latest.
    public func stayOnThisConversation() {
        guard selectedSessionKey != nil, selectedImportID == nil else { return }
        if staysOnChosenSession { pinSelection() } else { staysOnChosenSession = true }
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
        holdPickMadeWhileClosed()
        guard let answer = readyAnswer else { followsLatest = true; return }
        followsLatest = selectedSessionKey == answer.sessionKey
            && (selectedTurnIndex == nil || selectedTurnIndex == answer.turnIndex)
    }

    // MARK: Selection

    /// A report chosen while the island is closed (menu bar, shortcut,
    /// import): the island opens on it, once.
    private func holdPickMadeWhileClosed() {
        if visibleSurfaces == 0 { closedHoldUntil = .distantFuture }
    }

    public func selectProject(_ path: String?) {
        selectedImportID = nil
        guard path != selectedProjectPath else { return }
        selectedProjectPath = path
        selectedSessionKey = nil
        selectedTurnIndex = nil
        followsLatest = false
        pinSelection()
        holdPickMadeWhileClosed()
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
        /// Phase 11: first-run setup (agents, project, first capture).
        case setup
        /// Phase 19: the Quick Tour (first launch, Settings → Show Quick Tour).
        case tour
        /// Phase 12: final results of every agent, newest first.
        case inbox
        /// Phase 12: jump to an agent, profile, project, conversation or result.
        case switcher
        /// Phase 13: several results prepared as one Context Pack.
        case contextPack
        /// Phase 13: the prepared pack's exact text, before copying.
        case contextPackPreview
        /// Phase 13: prepared packs and what was done with them.
        case handoffHistory
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
            case .setup: return "Set Up"
            case .tour: return "Quick Tour"
            case .inbox: return "Results Inbox"
            case .switcher: return "Go To"
            case .contextPack: return "Context Pack"
            case .contextPackPreview: return "Pack Preview"
            case .handoffHistory: return "Handoff History"
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
            if route != oldValue, route == .inbox || route == .switcher { Task { await loadInbox() } }
            if route != oldValue, route == .switcher { switcherQuery = "" }
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
    public internal(set) var isPresentingSystemDialog = false {
        didSet { if oldValue != isPresentingSystemDialog { onSystemDialog?(isPresentingSystemDialog) } }
    }
    /// Called synchronously when a dialog opens or closes, before it shows,
    /// so the island is out of the way first (set by `NotchController`).
    @ObservationIgnored var onSystemDialog: ((Bool) -> Void)?
    /// The user pressed Done on a hand-off (Bearly's satisfied reaction).
    @ObservationIgnored public var onHandoffDone: (() -> Void)?
    /// Shows the system file picker; calls back with the chosen files, or
    /// nil for Cancel or Esc. Replaceable in tests.
    @ObservationIgnored public var filePicker: @MainActor (FilePickRequest, @escaping @MainActor ([URL]?) -> Void) -> Void
        = LiveFilePicker.present
    /// Brings an open picker forward (the shortcut or the menu bar while it is up).
    @ObservationIgnored public var bringFilePickerForward: @MainActor () -> Void = LiveFilePicker.bringForward

    /// Phase 9.4: the window capturer (the system picker); replaceable in tests.
    @ObservationIgnored public lazy var windowCapture: WindowCapturing = WindowCapture()
    /// Phase 14.1: Screen Recording authorization, read-only; replaceable in tests.
    @ObservationIgnored public lazy var screenRecordingPermission: ScreenRecordingPermissionChecking = LiveScreenRecordingPermission()
    /// Phase 14.1: quits this process (Settings → About already has its own
    /// quit action for other builds; this is "Quit BearlyCopy" after a
    /// permission grant that needs a restart to take effect). Replaceable in
    /// tests — never call `NSApp.terminate` from a test.
    @ObservationIgnored public var quitApp: @MainActor () -> Void = { NSApp.terminate(nil) }
    /// Set when the picker itself (Link Window…) reports macOS declined
    /// screen capture; Settings offers "Open Screen Recording Settings" next
    /// to the message while this is true.
    public internal(set) var autoCapturePermissionBlocked = false

    /// Capture Final Window: the user picks one window in macOS's picker; its
    /// still image is kept locally with the report shown now, as an
    /// attachment added by the user (selected; uncheck or remove like any
    /// other). Cancel adds nothing; nothing is captured otherwise.
    public func captureFinalWindow() {
        guard let ref = currentRef, let store = reportStore, !isPresentingSystemDialog else { return }
        isPresentingSystemDialog = true
        windowCapture.captureWindow { [weak self] result in
            guard let self else { return }
            self.isPresentingSystemDialog = false
            switch result {
            case nil: break
            case .success(let shot)?:
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH.mm.ss"
                do {
                    // Phase 10: memory only — no file in the attachments folder.
                    _ = try store.addEphemeralImage(shot.png, name: "\(shot.label) \(f.string(from: Date())).png", to: ref,
                                                    source: .windowSnapshot)
                    self.attachmentMessage = nil
                } catch {
                    self.attachmentMessage = "The window image could not be kept (too large)."
                }
                self.attachmentsVersion += 1
            case .failure?:
                self.attachmentMessage = "The window could not be captured. You can add a screenshot with Files…"
            }
        }
    }

    // MARK: Auto-capture final window (opt-in, Phase 9.4; Phase 14 links)

    static let autoCaptureKey = "attachments.autoCaptureFinalWindow"
    static let autoCaptureHandoffKey = "attachments.autoScreenshotsInHandoff"
    /// Off by default. When on, after each new final answer one still image
    /// of the window linked to that agent is kept with the answer (memory
    /// only). See `AppModel+AutoCapture.swift`.
    public var autoCaptureFinalWindow = false {
        didSet {
            stateDefaults?.set(autoCaptureFinalWindow, forKey: Self.autoCaptureKey)
            if !autoCaptureFinalWindow { unlinkAllAutoCaptureWindows() } else if !oldValue { autoCaptureArmedAt = captureNow() }
        }
    }
    /// Phase 14: auto screenshots start selected for Copy with Context,
    /// Context Packs and Drag only when the user turns this on (off by default).
    public var autoScreenshotsInHandoff = false {
        didSet { stateDefaults?.set(autoScreenshotsInHandoff, forKey: Self.autoCaptureHandoffKey) }
    }
    /// Phase 18: link the window of the app in front when a prompt starts, so
    /// the screenshot is of the window where the agent works. On by default
    /// (it only does anything while Automatic final screenshots are on). It
    /// needs Screen Recording already granted, checked without a prompt.
    static let autoLinkKey = "attachments.autoLinkWindow"
    public var autoLinkWindowEnabled = true {
        didSet { stateDefaults?.set(autoLinkWindowEnabled, forKey: Self.autoLinkKey) }
    }
    /// Phase 14: windows linked to agents (memory only: window identity does
    /// not survive a restart of BearlyCopy or of the agent's app).
    public internal(set) var autoCaptureBindings: [WindowBinding] = []
    /// What happened to each answer's auto screenshot (report key).
    public internal(set) var autoCaptureStatuses: [String: AutoCaptureStatus] = [:]
    public internal(set) var autoCaptureMessage: String?
    /// Reports already considered in this run (never twice for one answer).
    @ObservationIgnored var autoCapturedRefs: Set<String> = []
    /// Conversations already auto-linked during their current run (Phase 18).
    @ObservationIgnored var autoLinkedRunning: Set<String> = []
    /// One capture job per window at a time; a newer answer cancels it.
    @ObservationIgnored var autoCaptureJobs: [String: (ref: String, task: Task<Void, Never>)] = [:]
    /// How long the window may settle before and between stills (tests: immediate).
    @ObservationIgnored public var captureSettle = CaptureSettle.standard
    @ObservationIgnored var captureNow: () -> Date = Date.init
    /// Answers that finished before this (app start or turning the feature
    /// on) are never captured and get no status.
    @ObservationIgnored var autoCaptureArmedAt = Date()

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
        // Phase 9.4: by the newest real final answer; conversations with none
        // yet follow, by their latest activity (`groupByProject`, shared
        // with By Agent so both views order alike).
        groupByProject(allSessions.filter { providerFilter == nil || $0.provider == providerFilter })
    }

    /// Phase 9.3: what a session row says about its state. Stop means the
    /// agent stopped, not that the task succeeded; `0 answers` is never shown
    /// as finished.
    public enum SessionState: Equatable, Sendable { case working, waitingBackground, answered, noAnswer, failed, needsInput, mayNeedInput }
    public func sessionState(_ session: SessionSummary) -> SessionState {
        if session.attention != nil { return isConfirmed(session) ? .needsInput : .mayNeedInput }   // Phase 12.1
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
    var turnCache: [String: (lastEventAt: String?, turns: [Turn])] = [:]

    // MARK: Conversations (Project and Session, Phase 9.4)

    static let expandedConversationsKey = "projects.expandedConversations"
    /// Conversations opened in Project and Session; kept across launches.
    public private(set) var expandedConversations: Set<String> = [] {
        didSet { stateDefaults?.set(Array(expandedConversations).sorted(), forKey: Self.expandedConversationsKey) }
    }

    public func toggleConversation(_ session: SessionSummary) {
        if expandedConversations.contains(session.sessionKey) {
            expandedConversations.remove(session.sessionKey)
        } else {
            expandedConversations.insert(session.sessionKey)
            Task { _ = await cachedTurns(session) }
        }
    }

    /// The final answers of a conversation, newest first (nil until loaded).
    /// Intermediate Stops and background turns are not listed.
    public func conversationAnswers(_ session: SessionSummary) -> [Turn]? {
        guard let hit = turnCache[session.sessionKey], hit.lastEventAt == session.lastEventAt else {
            if expandedConversations.contains(session.sessionKey) { Task { _ = await cachedTurns(session) } }
            return nil
        }
        return hit.turns.filter(Self.isVisibleAnswer).reversed()
    }

    /// When the conversation's newest final answer arrived (for sorting).
    func lastFinalAnswerAt(_ session: SessionSummary) -> String? {
        if let last = session.lastTurn, last.completion.isFinal { return last.answeredAt ?? session.lastEventAt }
        if let hit = turnCache[session.sessionKey], hit.lastEventAt == session.lastEventAt {
            return hit.turns.last(where: Self.isVisibleAnswer)?.finalResponse?.receivedAt
        }
        return nil
    }

    func cachedTurns(_ session: SessionSummary) async -> [Turn] {
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
            for turn in await cachedTurns(session) where turn.finalResponse != nil && Self.isVisibleAnswer(turn) {
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

    // MARK: Phase 12 — agent workspace, Results Inbox, Quick Switcher
    // (logic in AppModel+Workspace.swift; stored state must live here)

    public enum WorkspaceMode: String, CaseIterable, Sendable {
        case byProject = "By Project", byAgent = "By Agent"
    }
    static let workspaceModeKey = "workspace.mode"
    /// Project and Session: one history, two groupings. Kept across launches.
    public var workspaceMode: WorkspaceMode = .byProject {
        didSet { if oldValue != workspaceMode { stateDefaults?.set(workspaceMode.rawValue, forKey: Self.workspaceModeKey) } }
    }
    static let browsingProfileKey = "workspace.browsingProfile"
    /// By Agent: the provider · profile row open in the left column.
    public var browsingProfile: ProfileKey? {
        didSet { stateDefaults?.set(browsingProfile.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.browsingProfileKey) }
    }
    static let profileLabelsKey = "profiles.labels"
    /// The user's names for profiles ("Work"), by `ProfileKey.id`. Local UI
    /// state only: never sent anywhere, never proof of an account. Removing
    /// a name never removes history.
    public internal(set) var profileLabels: [String: String] = [:] {
        didSet { stateDefaults?.set(profileLabels, forKey: Self.profileLabelsKey) }
    }
    /// Results Inbox: the Core's `results` (newest first), loaded only while
    /// the Inbox or the Quick Switcher is on screen — never in idle.
    public internal(set) var inbox: LoadState<[ResultSummary]> = .idle
    public internal(set) var inboxTotal = 0
    public internal(set) var inboxLimit = AppModel.inboxPage
    public static let inboxPage = 300
    public enum InboxFilter: String, CaseIterable, Sendable { case all = "All", unread = "Unread", attention = "Needs Attention" }
    public var inboxFilter: InboxFilter = .all
    /// Inbox: only this provider · profile (nil: every agent).
    public var inboxProfile: ProfileKey?
    @ObservationIgnored var inboxLoading = false
    @ObservationIgnored var inboxReloadAgain = false
    /// Quick Switcher: typed text and scope (kept while the island is open).
    public var switcherQuery = ""
    public var switcherScope: SwitcherScope = .all
    /// Phase 12: a newer answer arrived while the user was reading another
    /// one; Follow Latest moves on when the island closes, never mid-read.
    public internal(set) var deferredLatest: ReadyAnswer?

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
        holdPickMadeWhileClosed()
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
        /// Phase 17: when the text was copied. Absent in steps saved by
        /// earlier versions: those never hold a report across a close.
        public var startedAt: Date?
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
    // MARK: Context Pack (Phase 13)

    /// The results chosen for a Context Pack, in the user's order (references
    /// only; saved next to the reports so a restart keeps the draft).
    public internal(set) var packRefs: [ReportRef] = [] {
        didSet { if packRefs != oldValue { savePackDraft() } }
    }
    /// The user's own words for the receiving AI (never generated).
    public var packInstructions = "" {
        didSet { if packInstructions != oldValue { savePackDraft() } }
    }
    public var packDestination: HandoffDestination = .generic {
        didSet { if packDestination != oldValue { savePackDraft() } }
    }
    public internal(set) var contextPack: ContextPackState = .idle
    /// What the user did with the prepared pack (never "delivered").
    public internal(set) var packProgress = PackProgress()
    /// The prepared pack holds likely secrets: the copy waits for a yes.
    public internal(set) var packAwaitsSensitiveConfirmation = false
    /// The user said "Copy Anyway" for the pack prepared now: its files and
    /// drag follow without asking again (reset by every Prepare).
    public internal(set) var packSensitiveConfirmed = false
    public internal(set) var packMessage: String?
    /// Prepared packs and what the user did with them (no text, no images).
    public internal(set) var handoffHistory: [HandoffRecord] = [] {
        didSet { if handoffHistory != oldValue { saveHandoffHistory() } }
    }
    /// Include the machine-readable manifest at the end of the copied text.
    public var packIncludesManifest = false {
        didSet { if packIncludesManifest != oldValue { savePackDraft() } }
    }
    @ObservationIgnored var loadingPackDraft = false

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
    /// Phase 16: the last attachment action's success, in words ("Attached
    /// X — selected for …"); `attachmentMessage` holds problems. Never both.
    public internal(set) var attachmentNotice: String? {
        didSet { attachmentNoticeKey = attachmentNotice == nil ? nil : currentRef?.key }
    }
    /// The answer the notice is about; shown only while that answer is open.
    public internal(set) var attachmentNoticeKey: String?

    public func attachments(for ref: ReportRef?) -> [ReportAttachment] {
        _ = attachmentsVersion
        guard let ref, let store = reportStore else { return [] }
        return store.attachments(for: ref)
    }

    public func attachmentURL(_ attachment: ReportAttachment) -> URL? { reportStore?.fileURL(for: attachment) }

    /// Phase 10: present now — an in-memory snapshot is never a file.
    public func isAttachmentAvailable(_ attachment: ReportAttachment) -> Bool { reportStore?.isAvailable(attachment) ?? false }

    /// The bytes (memory or the private copy), for previews and thumbnails.
    public func attachmentData(_ attachment: ReportAttachment) -> Data? { reportStore?.data(for: attachment) }

    /// The image of an in-memory snapshot for the pasteboard or a drag: data
    /// only, no file URL. nil for persistent attachments or when it expired.
    func memoryImage(_ attachment: ReportAttachment) -> ClipboardImage? {
        guard attachment.isInMemory, let data = reportStore?.data(for: attachment) else { return nil }
        return ClipboardImage(data: data, uti: UTType(mimeType: attachment.mimeType)?.identifier ?? "public.png")
    }

    /// Phase 10: what a drag of these attachments carries — files for
    /// persistent ones (hand-off copies, original names), image data for
    /// in-memory snapshots (no temporary file is created for them).
    public func dragPayloads(for attachments: [ReportAttachment]) -> [DragPayload] {
        handoffFiles(attachments.filter { !$0.isInMemory }).map(DragPayload.file)
            + attachments.compactMap(memoryImage).map(DragPayload.image)
    }

    /// One attachment for SwiftUI's onDrag.
    public func dragProvider(for attachment: ReportAttachment) -> NSItemProvider {
        if let image = memoryImage(attachment) {
            return NSItemProvider(item: image.data as NSData, typeIdentifier: image.uti)
        }
        return dragFile(for: attachment).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
    }

    /// Images the user chose in the file picker, copied into BearlyCopy's
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
        case .documentTooLarge(let name): return "\(name) is a text document larger than 1 MB"
        case .lockUnavailable: return "\(file) was not saved: BearlyCopy's folder is busy or not writable. Try again"
        case .noPermission(let name): return "\(name) could not be read: no permission"
        case .damagedImage(let name): return "\(name) is damaged or not a readable image"
        case .unreadable(let name): return "\(name) could not be read"
        case .writeFailed: return "\(file) could not be saved in BearlyCopy's folder"
        case .removeFailed: return "The image could not be removed"
        case .empty: return "\(file) is empty"
        case .unsupported(let name): return "\(name) is not a document, PDF or image BearlyCopy can keep"
        }
    }

    /// Unlinks one image from the report. The report's text and its other
    /// images stay as they are.
    public func removeAttachment(_ attachment: ReportAttachment) {
        do {
            try reportStore?.removeAttachment(attachment.id)
            attachmentMessage = nil
            attachmentNotice = nil
        } catch {
            attachmentMessage = "\(attachment.originalFilename) could not be removed. Try again."
        }
        attachmentsVersion += 1
    }

    /// Copies one attachment as an image (PNG/TIFF data and its file).
    public func copyAttachment(_ attachment: ReportAttachment) {
        if attachment.isInMemory {
            guard let image = memoryImage(attachment) else { finishCopy(.failed("The snapshot is no longer in memory.")); return }
            do {
                try clipboard.copyImage(image)
                finishCopy(.copied(.image, characters: 0), token: Self.attachmentToken(attachment.id))
            } catch { finishCopy(.failed("The image could not be copied.")) }
            return
        }
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
        let files = handoffFiles(attachments.filter { !$0.isInMemory })
        let images = attachments.compactMap(memoryImage)
        guard !files.isEmpty || !images.isEmpty else { finishCopy(.failed("The image files are missing.")); return }
        if files.isEmpty, images.count == 1, attachments.count == 1 { copyAttachment(attachments[0]); return }
        do {
            try clipboard.copyFiles(files, images: images)
            finishCopy(.copied(.files, characters: files.count), token: attachments.count == 1 ? Self.attachmentToken(attachments[0].id) : nil)
        } catch {
            finishCopy(.failed("The files could not be copied."))
        }
    }

    /// The report's images in a Finder window, selected, under their
    /// original names: drag them into ChatGPT after pasting the text.
    public func revealAttachmentsForHandoff(_ attachments: [ReportAttachment]) {
        let files = handoffFiles(attachments.filter { !$0.isInMemory })
        guard !files.isEmpty else {
            attachmentMessage = attachments.contains(where: \.isInMemory)
                ? "Window snapshots are kept in memory only, not as files. Use Copy or Drag."
                : "The image files are missing."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// A file URL for dragging one image out (original name), or nil.
    public func dragFile(for attachment: ReportAttachment) -> URL? { handoffFiles([attachment]).first }

    /// Hand-off copies under the original names; missing images are skipped.
    func handoffFiles(_ attachments: [ReportAttachment]) -> [URL] {
        guard let store = reportStore else { return [] }
        do { return try store.handoffFiles(for: attachments) } catch {
            attachmentMessage = "BearlyCopy could not prepare the files."
            return []
        }
    }

    /// Text and images in one clipboard write. Whether a paste carries the
    /// images depends on the destination app (see docs/MACOS_APP.md).
    public func copyResponseWithImages() async {
        guard let ref = currentRef else { return }
        guard let text = await fullText(for: ref) else { return }
        let all = attachments(for: ref)
        let images = handoffFiles(all.filter { !$0.isInMemory }).compactMap(ClipboardImage.init(file:)) + all.compactMap(memoryImage)
        do {
            try clipboard.copy(text, imageItems: images)
            finishCopy(.copied(.responseWithImages, characters: text.unicodeScalars.count), token: Self.answerToken(ref))
            record(.response, ref: ref, characters: text.unicodeScalars.count)
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }

    // MARK: Recent Copies

    static let copiesKey = "copies.recent"
    public static let copyHistoryLimit = 5
    /// The last copies made in BearlyCopy, newest first. References only.
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
            finishCopy(.failed("This report is no longer in BearlyCopy's history."))
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
        // Phase 16: with all projects captured, the switches exclude whole
        // projects, so the list shows projects (a repository with its
        // subfolders), not every folder an agent ran in.
        let source = captureSettings?.mode == .global ? (projects.value ?? rawProjects) : rawProjects
        let core = source.compactMap { p -> ProjectRow? in
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
    // MARK: Phase 16 — capture mode

    /// The Core's capture policy as last listed (nil: a Core before 0.8.0).
    public internal(set) var captureSettings: CaptureSettings?
    /// A mode change in progress or its last error.
    public internal(set) var captureModeError: String?

    /// What capture is doing now, in one state the UI shows everywhere.
    public enum CaptureStatus: Equatable, Sendable {
        case allProjects(excluded: Int)
        case selectedProjects(count: Int)
        case paused
        /// A mode is set, but the installed Claude Code plugin is too old to
        /// honor it: that plugin stores nothing until it is updated.
        case pluginUpdateRequired(installed: String, needed: String)
        case unknown

        public var title: String {
            switch self {
            case .allProjects(let n): return n == 0 ? "Capturing all projects" : "Capturing all projects · \(n) excluded"
            case .selectedProjects(let n): return n == 1 ? "Capturing 1 selected project" : "Capturing \(n) selected projects"
            case .paused: return "Capture paused"
            case .pluginUpdateRequired: return "Plugin update required"
            case .unknown: return "Capture status unknown"
            }
        }

        public var detail: String? {
            switch self {
            case .allProjects: return "Every project Claude Code or a connected Codex works in appears automatically."
            case .selectedProjects: return "Only projects switched on in Projects are captured."
            case .paused: return "Nothing new is stored until you resume."
            case .pluginUpdateRequired(let installed, let needed):
                return "The Claude Code plugin is \(installed); capture modes need \(needed). Until it is updated, nothing is captured. In Terminal: claude plugin update prompt-relay@prompt-relay — then start a new Claude session."
            case .unknown: return nil
            }
        }

        public var isActive: Bool {
            switch self { case .allProjects, .selectedProjects: return true; default: return false }
        }
    }

    /// The installed Claude Code plugin's version, when `doctor` found one.
    public var installedPluginVersion: String? {
        doctor.value?.configuration.plugin.records.first { $0.id.hasPrefix("prompt-relay@") }?.version
    }

    public var captureStatus: CaptureStatus {
        Self.captureStatus(settings: captureSettings, installedPlugin: installedPluginVersion)
    }

    static func captureStatus(settings: CaptureSettings?, installedPlugin: String?) -> CaptureStatus {
        guard let settings else { return .unknown }
        let policy = settings.mode != .selected || !settings.excludedProjects.isEmpty
        if policy, let installed = installedPlugin,
           let a = AppBuild.numeric(installed), let b = AppBuild.numeric(settings.minimumPluginVersion), a.lexicographicallyPrecedes(b) {
            return .pluginUpdateRequired(installed: installed, needed: settings.minimumPluginVersion)
        }
        switch settings.mode {
        case .global: return .allProjects(excluded: settings.excludedProjects.count)
        case .selected: return .selectedProjects(count: settings.enabledProjects.count)
        case .paused: return .paused
        }
    }

    static let globalOfferDismissedKey = "PromptRelayGlobalCaptureOfferDismissed"

    /// Phase 16: the one-time offer to capture every project, shown while the
    /// user has not chosen (selected mode, not dismissed). Never switched on
    /// without this explicit choice.
    public var offersGlobalCapture: Bool {
        captureSettings?.mode == .selected && !(stateDefaults?.bool(forKey: Self.globalOfferDismissedKey) ?? false)
            && !globalOfferDismissedNow
    }
    var globalOfferDismissedNow = false

    public func dismissGlobalCaptureOffer() {
        stateDefaults?.set(true, forKey: Self.globalOfferDismissedKey)
        globalOfferDismissedNow = true
    }

    public func setCaptureMode(_ change: CapturePolicyChange) async {
        captureModeError = nil
        do {
            captureSettings = try await core.setCaptureMode(change)
            if case .mode = change { dismissGlobalCaptureOffer() }
        } catch {
            captureModeError = Self.message(for: error)
        }
        await refreshNow()
        loadDoctor()
    }

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

    /// Phase 17: awaitable (Daily Use needs the plugin version before it decides).
    @discardableResult
    func reloadDoctor() async -> Bool {
        do {
            doctor = .loaded(try await core.doctor().data)
            return true
        } catch {
            doctor = doctor.failing(Self.coreError(error))
            return false
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
                finishCopy(.failed("This report is no longer in BearlyCopy's history."))
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
                return .failure(PackFailure(message: "This report is no longer in BearlyCopy's history."))
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
        // BearlyCopy is an agent app whose island is a non-activating
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
