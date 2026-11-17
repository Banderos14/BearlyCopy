import Foundation

/// Phase 12: several agents and local profiles side by side.
///
/// One history, several views of it — nothing here stores a second copy:
/// - **By Project** (`sessionsByProject`) and **By Agent** (`agentGroups`)
///   group the same `allSessions`.
/// - **Results Inbox** lists the Core's `results` (final answers only).
/// - **Quick Switcher** searches what is already loaded.
///
/// Read state is per result (`seenAnswers`, keyed by `ReportRef.key`):
/// opening one result marks that one, never the others, and survives a
/// restart. The notch keeps its single green dot (`readyIndicator`).
///
/// Four "latest" states are kept apart on purpose:
/// - newest received final answer of any agent: `readyAnswer`;
/// - what the user looked at: `seenAnswers` (+ `currentRef` while open);
/// - the conversation chosen: `selectedSessionKey` (and `sessionPinned`);
/// - newest result of one project: `latestResult(inProject:)`.
extension AppModel {
    // MARK: Profiles

    /// Every provider · profile with captured conversations (imports aside).
    public var knownProfiles: [ProfileKey] {
        Array(Set(allSessions.map(\.profileKey))).sorted()
    }

    /// Profiles matter in the UI only once there is more than one of some
    /// provider, or an Unassigned group next to a recorded one.
    public var showsProfiles: Bool {
        let byProvider = Dictionary(grouping: knownProfiles, by: \.provider)
        return byProvider.values.contains { $0.count > 1 } || !profileLabels.isEmpty
    }

    /// The user's label, else a neutral name from what the Core recorded:
    /// "Default", the config folder's name ("claude-work"), "Xcode" for
    /// Xcode's Codex home, or "Unassigned" (recorded before Phase 12).
    public func profileName(_ key: ProfileKey) -> String {
        if let label = profileLabels[key.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        if key.isUnassigned { return "Unassigned" }
        if key.isDefault { return "Default" }
        if let hint = profileHint(key) {
            if hint.contains("/Xcode/CodingAssistant") { return "Xcode" }
            var name = (hint as NSString).lastPathComponent
            while name.hasPrefix(".") { name.removeFirst() }
            if !name.isEmpty, name != "~" { return name }
        }
        return "Profile " + String(key.profileID.dropFirst(3).prefix(6))
    }

    /// "Claude · Work", "Codex · Default".
    public func profileTitle(_ key: ProfileKey) -> String { "\(key.provider.shortTitle) · \(profileName(key))" }

    /// The folder hint the Core recorded (`~/.claude-work`), if any.
    public func profileHint(_ key: ProfileKey) -> String? {
        allSessions.lazy.filter { $0.profileKey == key }.compactMap { $0.profile?.hint }.first
    }

    /// What BearlyCopy knows about a profile, in words (Settings, tooltips).
    public func profileExplanation(_ key: ProfileKey) -> String {
        if key.isUnassigned {
            return "Recorded before profiles were tracked. These conversations stay here; they are not moved into another profile."
        }
        let folder = profileHint(key).map { "Configuration folder \($0)." } ?? "Configuration folder recorded by its hash only."
        return folder + " A folder is not an account: if you sign in to another account in the same folder, BearlyCopy cannot tell."
    }

    /// Names a profile locally. Empty text removes the name; history is
    /// never touched.
    public func setProfileLabel(_ key: ProfileKey, _ label: String?) {
        let text = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { profileLabels[key.id] = nil } else { profileLabels[key.id] = String(text.prefix(40)) }
    }

    // MARK: By Agent

    public struct AgentGroup: Identifiable, Equatable, Sendable {
        public let key: ProfileKey
        public let projects: [ProjectGroup]
        public var id: String { key.id }
        public var sessionCount: Int { projects.reduce(0) { $0 + $1.sessions.count } }
    }

    public struct ProjectGroup: Identifiable, Equatable, Sendable {
        public let project: String
        public let name: String
        public let sessions: [SessionSummary]
        public var id: String { project }
    }

    /// Provider → profile → project → conversations, newest final answer
    /// first at every level. Same sessions as By Project.
    public var agentGroups: [AgentGroup] {
        let filtered = allSessions.filter { providerFilter == nil || $0.provider == providerFilter }
        let byKey = Dictionary(grouping: filtered, by: \.profileKey)
        return byKey.map { key, list in
            AgentGroup(key: key, projects: groupByProject(list).map { ProjectGroup(project: $0.project, name: $0.name, sessions: $0.sessions) })
        }
        .sorted { a, b in
            if a.key.provider != b.key.provider { return a.key < b.key }
            let da = a.projects.first?.sessions.first.map(conversationActivity) ?? .distantPast
            let db = b.projects.first?.sessions.first.map(conversationActivity) ?? .distantPast
            return da != db ? da > db : a.key < b.key
        }
    }

    /// Unseen final answers of one provider · profile.
    public func newAnswerCount(inProfile key: ProfileKey) -> Int {
        let keys = Set(allSessions.filter { $0.profileKey == key }.map(\.sessionKey))
        return unseenAnswers.filter { keys.contains($0.sessionKey) }.count
    }

    /// Phase 12 (Agent Workspace): the conversation's profile, for its row.
    public func profileKey(ofSession key: String) -> ProfileKey? {
        allSessions.first { $0.sessionKey == key }?.profileKey
    }

    // MARK: Results Inbox

    /// The Inbox or the Quick Switcher is visible: only then are results loaded.
    var inboxOnScreen: Bool { visibleSurfaces > 0 && (route == .inbox || route == .switcher) }

    /// The island shows a loaded report and the user is looking at it.
    var isReadingReport: Bool { visibleSurfaces > 0 && currentRef != nil && detail.value != nil }

    /// Loads (or reloads) the Results Inbox. Concurrent calls coalesce.
    public func loadInbox() async {
        if inboxLoading { inboxReloadAgain = true; return }
        inboxLoading = true
        defer { inboxLoading = false }
        repeat {
            inboxReloadAgain = false
            inbox = inbox.reloading
            do {
                let result = try await core.results(limit: inboxLimit)
                inbox = .loaded(result.data.results)
                inboxTotal = result.data.total
            } catch {
                inbox = inbox.failing(Self.coreError(error))
            }
        } while inboxReloadAgain
    }

    /// "Show More": the next page of older results.
    public func loadMoreInbox() {
        inboxLimit += Self.inboxPage
        Task { await loadInbox() }
    }

    /// Where a result belongs in the Inbox (nil: not listed at all).
    /// - finished: a final answer (also one the user moved on from while its
    ///   work still ran — tagged, but the agent did finish its turn);
    /// - needsAttention: the agent stopped while its own background work ran
    ///   and nothing followed within the wait limit — completion unknown. It
    ///   is kept (history, diagnostics, copy) but never looks finished, never
    ///   counts as unread and is never Latest.
    /// Intermediate Stops and turns still waiting are not listed.
    public enum InboxSection: Equatable, Sendable { case finished, needsAttention }

    nonisolated public static func inboxSection(_ r: ResultSummary, now: Date = Date()) -> InboxSection? {
        switch r.completion {
        case .answer, .answerBackgroundRunning: return .finished
        case .waitingBackground: return waitExpired(r.answeredAt, now: now) ? .needsAttention : nil
        default: return nil
        }
    }

    /// Finished results only (Go To, unread).
    nonisolated public static func isInboxResult(_ r: ResultSummary, now: Date = Date()) -> Bool {
        inboxSection(r, now: now) == .finished
    }

    /// Read state of one result. The same rule as the notch and Project and
    /// Session: newer than the first-run baseline and not opened yet.
    public func isUnread(_ result: ResultSummary) -> Bool {
        guard result.completion.isFinal, let at = result.answeredAt else { return false }
        return isUnread(ref: result.ref, at: at)
    }

    func isUnread(ref: ReportRef, at: String) -> Bool {
        guard let baseline = lastSeenAt, Self.isNewer(at, than: baseline) else { return false }
        return seenAnswers[ref.key] == nil
    }

    private func inboxRows(_ section: InboxSection) -> [ResultSummary] {
        let now = Date()
        return (inbox.value ?? []).filter { r in
            guard Self.inboxSection(r, now: now) == section else { return false }
            // Only the Inbox's own, visible filters (never the agent filter
            // of Project and Session or History, which is not shown here).
            if let p = inboxProfile, r.profileKey != p { return false }
            return true
        }
    }

    /// Finished results (newest first) for All / Unread, or the
    /// Needs Attention rows for that filter.
    public var inboxEntries: [ResultSummary] {
        switch inboxFilter {
        case .all: return inboxRows(.finished)
        case .unread: return inboxRows(.finished).filter(isUnread)
        case .attention: return inboxRows(.needsAttention)
        }
    }

    /// Results whose completion is unknown (shown apart, under All too).
    public var inboxNeedsAttention: [ResultSummary] { inboxRows(.needsAttention) }

    /// Unseen final answers of every agent (Inbox tab badge).
    public var unreadResultCount: Int { unseenAnswers.count }

    /// Opens exactly this result on Home (Answer, Copy Answer, Copy with
    /// Context, attachments, Preview) and marks only it as read.
    public func openResult(_ result: ResultSummary) {
        markRead(result.ref, at: result.answeredAt)
        open(result.ref)
    }

    func markRead(_ ref: ReportRef, at: String?) {
        guard seenAnswers[ref.key] == nil else { return }
        seenAnswers[ref.key] = at ?? lastSeenAt ?? ""
    }

    /// The explicit "Mark All as Read" of the rows shown (never implied by
    /// opening one result).
    public func markInboxRead() {
        for r in inboxEntries where isUnread(r) { markRead(r.ref, at: r.answeredAt) }
    }

    /// The newest unread final answer other than the one shown.
    public var nextUnread: ReadyAnswer? {
        unseenAnswers.first { ReportRef.local(sessionKey: $0.sessionKey, turn: $0.turnIndex) != currentRef }
    }

    /// ⌘J / the global shortcut: open the next unread result (newest first).
    /// Returns false when there is none.
    @discardableResult
    public func openNextUnread() -> Bool {
        guard let answer = nextUnread else { return false }
        let ref = ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex)
        markRead(ref, at: answer.at)
        open(ref)
        return true
    }

    /// Newest final result of one logical project (not the same as Latest).
    public func latestResult(inProject path: String) -> ReadyAnswer? {
        finishedAnswers.first { $0.projectPath == path && $0.completion.isFinal }
    }

    // MARK: Helpers shared by By Project and By Agent

    func conversationActivity(_ s: SessionSummary) -> Date {
        Wording.date(lastFinalAnswerAt(s)) ?? Wording.date(s.lastEventAt).map { $0.addingTimeInterval(-10 * 365 * 86_400) } ?? .distantPast
    }

    func groupByProject(_ list: [SessionSummary]) -> [(project: String, name: String, sessions: [SessionSummary])] {
        var groups: [String: [SessionSummary]] = [:]
        var names: [String: String] = [:]
        for session in list {
            let key = projectPath(for: session) ?? session.logicalProject?.path ?? session.project.path ?? "?"
            groups[key, default: []].append(session)
            names[key] = (projects.value ?? []).first { $0.path == key }.map(Wording.projectName)
                ?? session.logicalProject?.name ?? Wording.projectName(session.project)
        }
        return groups.map { key, list in
            (project: key, name: names[key] ?? key, sessions: list.sorted {
                let a = conversationActivity($0), b = conversationActivity($1)
                return a != b ? a > b : $0.sessionKey < $1.sessionKey
            })
        }
        .sorted { a, b in
            let da = a.sessions.first.map(conversationActivity) ?? .distantPast
            let db = b.sessions.first.map(conversationActivity) ?? .distantPast
            return da != db ? da > db : a.name < b.name
        }
    }

    /// The project name a result shows (logical project when listed).
    public func projectName(of result: ResultSummary) -> String {
        if let session = allSessions.first(where: { $0.sessionKey == result.sessionKey }), let path = projectPath(for: session),
           let p = (projects.value ?? []).first(where: { $0.path == path }) { return Wording.projectName(p) }
        return result.logicalProject?.name ?? Wording.projectName(result.project)
    }

    /// "Claude · Work · Claude Desktop" — the profile only when it tells
    /// conversations apart; an unrecorded host is left out.
    public func agentLine(provider: AgentProvider, profile: ProfileKey?, host: AgentHost) -> String {
        var parts = [showsProfiles ? (profile.map(profileTitle) ?? provider.title) : provider.title]
        // "Codex · Xcode", not "Codex · Xcode · Xcode" for Xcode's own Codex folder.
        if host != .unknown, !(showsProfiles && profile.map(profileName) == host.title) { parts.append(host.title) }
        return parts.joined(separator: " · ")
    }

    // MARK: Quick Switcher

    public enum SwitcherScope: String, CaseIterable, Sendable {
        case all = "All", unread = "Unread", agents = "Agents", projects = "Projects", conversations = "Conversations"
    }

    public struct SwitcherItem: Identifiable, Equatable, Sendable {
        public enum Target: Equatable, Sendable {
            case result(ReportRef), profile(ProfileKey), project(String), conversation(String)
        }
        public enum Kind: String, Sendable { case latest = "Latest", unread = "Unread", agent = "Agent", project = "Project",
                                                    conversation = "Conversation", result = "Result" }
        public let kind: Kind
        public let target: Target
        public let title: String
        public let subtitle: String
        public let unread: Bool
        public var id: String { kind.rawValue + "|" + String(describing: target) }
    }

    /// What the Quick Switcher lists. Empty query: Latest, unread results,
    /// agents, recent projects and conversations. With a query: matches in
    /// names, titles and result previews. Built from loaded data only.
    public func switcherItems(limit: Int = 40) -> [SwitcherItem] {
        let query = switcherQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ texts: String?...) -> Bool {
            query.isEmpty || texts.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let scope = switcherScope
        var items: [SwitcherItem] = []
        var seen = Set<String>()
        func add(_ item: SwitcherItem) {
            guard !seen.contains(item.id), items.count < limit else { return }
            seen.insert(item.id); items.append(item)
        }
        func resultItem(_ answer: ReadyAnswer, kind: SwitcherItem.Kind) -> SwitcherItem? {
            let session = allSessions.first { $0.sessionKey == answer.sessionKey }
            let title = session.map(Wording.sessionTitle) ?? answer.projectName
            let sub = [agentLine(provider: answer.provider, profile: session?.profileKey, host: answer.host), answer.projectName,
                       Wording.relative(answer.at)].joined(separator: " · ")
            guard matches(title, sub) else { return nil }
            let ref = ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex)
            return SwitcherItem(kind: kind, target: .result(ref), title: title, subtitle: sub,
                                unread: isUnread(ref: ref, at: answer.at))
        }
        if scope == .all, let latest = readyAnswer, latest.completion.isFinal, let item = resultItem(latest, kind: .latest) { add(item) }
        if scope == .all || scope == .unread {
            for answer in unseenAnswers { if let item = resultItem(answer, kind: .unread) { add(item) } }
        }
        if scope == .all || scope == .agents {
            for key in knownProfiles {
                let count = allSessions.filter { $0.profileKey == key }.count
                let fresh = newAnswerCount(inProfile: key)
                let sub = "\(count) conversation\(count == 1 ? "" : "s")" + (fresh > 0 ? " · \(fresh) new" : "")
                if matches(profileTitle(key), key.provider.title, profileHint(key)) {
                    add(SwitcherItem(kind: .agent, target: .profile(key), title: profileTitle(key), subtitle: sub, unread: fresh > 0))
                }
            }
        }
        if scope == .all || scope == .projects {
            for p in projects.value ?? [] where p.sessionCount > 0 {
                guard let path = p.path, matches(Wording.projectName(p), path) else { continue }
                let fresh = newAnswerCount(inProject: path)
                add(SwitcherItem(kind: .project, target: .project(path), title: Wording.projectName(p),
                                 subtitle: "\(p.sessionCount) conversation\(p.sessionCount == 1 ? "" : "s")" + (fresh > 0 ? " · \(fresh) new" : ""),
                                 unread: fresh > 0))
            }
        }
        if scope == .all || scope == .conversations {
            let recent = scope == .conversations || !query.isEmpty ? allSessions : Array(allSessions.prefix(8))
            for s in recent {
                let title = Wording.sessionTitle(s)
                let project = projectPath(for: s).flatMap { path in (projects.value ?? []).first { $0.path == path } }
                    .map { Wording.projectName($0) } ?? Wording.projectName(s.project)
                let sub = [agentLine(provider: s.provider, profile: s.profileKey, host: s.source?.environment ?? .unknown), project,
                           Wording.relative(lastFinalAnswerAt(s) ?? s.lastEventAt)].joined(separator: " · ")
                guard matches(title, sub, s.sessionID, s.nativeSessionID) else { continue }
                add(SwitcherItem(kind: .conversation, target: .conversation(s.sessionKey), title: title, subtitle: sub, unread: false))
            }
        }
        // With a query, older results whose request or answer matches.
        if !query.isEmpty, scope == .all || scope == .unread {
            for r in inbox.value ?? [] where Self.isInboxResult(r) {
                guard scope == .all || isUnread(r) else { continue }
                let title = AppModel.oneLine(r.request?.displayPreview ?? r.response.preview)
                guard matches(title, r.response.preview, r.conversation.title) else { continue }
                let sub = [agentLine(provider: r.provider, profile: r.profileKey, host: r.host), projectName(of: r),
                           Wording.relative(r.answeredAt)].joined(separator: " · ")
                add(SwitcherItem(kind: .result, target: .result(r.ref), title: title.isEmpty ? "Answer" : title, subtitle: sub,
                                 unread: isUnread(r)))
            }
        }
        return items
    }

    /// Opens what a Quick Switcher row points at.
    public func activate(_ item: SwitcherItem) {
        switch item.target {
        case .result(let ref):
            if case .local(let key, let turn) = ref,
               let answer = finishedAnswers.first(where: { $0.sessionKey == key && $0.turnIndex == turn }) {
                markRead(ref, at: answer.at)
            } else if let r = inbox.value?.first(where: { $0.ref == ref }) {
                markRead(ref, at: r.answeredAt)
            }
            open(ref)
        case .profile(let key):
            workspaceMode = .byAgent
            browsingProfile = key
            route = .projects
        case .project(let path):
            openProject(path)
        case .conversation(let key):
            if let session = allSessions.first(where: { $0.sessionKey == key }) { focusSession(session) }
            route = .home
        }
    }
}
