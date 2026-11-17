import Foundation

/// Phase 12.1: agents waiting for the person (Needs Input).
///
/// The state comes only from the Core's `attention` (hook signals:
/// AskUserQuestion, ExitPlanMode, PermissionRequest, MCP elicitation). It is
/// never inferred from time, never shown as an answer, and BearlyCopy never
/// answers, approves or allows anything. A host that sends no such signal
/// keeps its last confirmed state (Working / Waiting / Answer).
extension AppModel {
    public struct WaitingAgent: Identifiable, Equatable, Sendable {
        public let sessionKey: String
        public let provider: AgentProvider
        public let profile: ProfileKey
        public let host: AgentHost
        public let projectName: String
        public let kind: ActionKind
        public let since: String?
        /// The wait is still supported by recent evidence (see `isConfirmed`).
        public var confirmed: Bool = true
        public var id: String { sessionKey }
    }

    /// How long a wait counts as confirmed after its newest signal. After
    /// that it is shown as "may need input" — never removed: a person can
    /// take a long time to answer, and an abandoned dialog (Esc, killed
    /// window, no SessionEnd) sends no event.
    nonisolated static let waitConfirmationWindow: TimeInterval = 30 * 60

    /// A wait is unconfirmed when its newest signal is older than the window,
    /// or when a later conversation of the same agent profile in the same
    /// project shows activity after it (the person most likely moved on).
    func isConfirmed(_ session: SessionSummary, now: Date? = nil) -> Bool {
        let now = now ?? clock()
        guard let attention = session.attention else { return false }
        let latest = attention.lastSignalAt ?? attention.since
        guard let at = Wording.date(latest), now.timeIntervalSince(at) < Self.waitConfirmationWindow else { return false }
        let project = projectPath(for: session)
        return !allSessions.contains { other in
            other.sessionKey != session.sessionKey && other.profileKey == session.profileKey
                && projectPath(for: other) == project
                && (Wording.date(other.lastEventAt).map { $0 > at } ?? false)
        }
    }

    /// Every conversation whose agent waits for the person, longest waiting
    /// first (the oldest request is the most likely to be blocking).
    public var agentsNeedingInput: [WaitingAgent] {
        allSessions.compactMap { s -> WaitingAgent? in
            guard let attention = s.attention else { return nil }
            let path = projectPath(for: s)
            let name = (projects.value ?? []).first { $0.path == path && path != nil }.map(Wording.projectName)
                ?? s.logicalProject?.name ?? Wording.projectName(s.project)
            return WaitingAgent(sessionKey: s.sessionKey, provider: s.provider, profile: s.profileKey,
                                host: s.source?.environment ?? .unknown, projectName: name, kind: attention.kind, since: attention.since,
                                confirmed: isConfirmed(s))
        }
        .sorted { ($0.since ?? "", $0.sessionKey) < ($1.since ?? "", $1.sessionKey) }
    }

    /// "Claude Code · Needs input · Question", or "2 agents need input".
    public var needsInputLine: String? {
        let waiting = agentsNeedingInput
        guard let first = waiting.first else { return nil }
        if waiting.count > 1 { return "\(waiting.count) agents need input" }
        if !first.confirmed { return "\(first.provider.title) · May need input · \(first.kind.title) (not confirmed)" }
        return "\(first.provider.title) · Needs input · \(first.kind.title)"
    }

    /// The band beside the camera housing is narrow: "Needs input" in Quick
    /// Peek (who and what are in its tooltip), "Claude · Needs input · Plan"
    /// in Details.
    public func needsInputBandLine(withKind: Bool) -> String? {
        let waiting = agentsNeedingInput
        guard let first = waiting.first else { return nil }
        if waiting.count > 1 { return "\(waiting.count) need input" }
        if !waiting.contains(where: \.confirmed) { return withKind ? "\(first.provider.shortTitle) · May need input" : "May need input" }
        return withKind ? "\(first.provider.shortTitle) · Needs input · \(first.kind.shortTitle)" : "Needs input"
    }

    /// Longer form for tooltips and accessibility: who, where, what kind.
    public func needsInputDetail(_ agent: WaitingAgent) -> String {
        var who = agentLine(provider: agent.provider, profile: agent.profile, host: agent.host)
        who += " in \(agent.projectName)"
        if !agent.confirmed {
            return "\(who) asked for input (\(agent.kind.title)) and nothing has happened since; it may have been answered "
                + "or cancelled without a signal. Check the agent's app."
        }
        return "\(who) waits for you: \(agent.kind.title). Answer it in the agent's app; BearlyCopy never answers for you."
    }

    /// Waits not yet announced (optional notification). The first load only
    /// records what is already waiting: nothing old is announced at launch,
    /// and one wait is announced once however often it is refreshed.
    func announceNewWaits() {
        let current = agentsNeedingInput
        let keys = Set(current.map { $0.sessionKey + "|" + ($0.since ?? "") })
        defer { announcedWaits = keys.union(announcedWaits.intersection(keys)) }
        guard waitsBaselineTaken else { waitsBaselineTaken = true; return }
        for agent in current where agent.confirmed && !announcedWaits.contains(agent.sessionKey + "|" + (agent.since ?? "")) {
            onNeedsInput?(agent)
        }
    }
}
