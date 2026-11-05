import Foundation

/// Phase 12: one local configuration home of an agent (the Core's
/// `profile`, `profiles.py`): `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, or the
/// provider's default. It is **not** an account: the folder does not say who
/// is signed in, and credentials are never read. The user's names for
/// profiles ("Work") are local labels (`AppModel.profileLabels`).
public struct AgentProfile: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let provider: String
    /// config_dir | default_home | installation (open: unknown values kept).
    public let basis: String
    public let isDefault: Bool
    /// `~/.claude-work`; never a user name or an absolute home path.
    public let hint: String?

    public init(id: String, provider: String, basis: String, isDefault: Bool, hint: String?) {
        self.id = id; self.provider = provider; self.basis = basis; self.isDefault = isDefault; self.hint = hint
    }

    enum CodingKeys: String, CodingKey { case id, provider, basis, isDefault = "default", hint }
}

/// Where a conversation belongs in By Agent: provider + profile. Sessions
/// recorded before Phase 12 (Claude Code) have no profile: `Unassigned`,
/// never guessed into another profile.
public struct ProfileKey: Hashable, Comparable, Sendable, Identifiable, Codable {
    public let provider: AgentProvider
    /// The Core's profile id, or `unassigned`.
    public let profileID: String
    public static let unassigned = "unassigned"

    public init(provider: AgentProvider, profileID: String) { self.provider = provider; self.profileID = profileID }
    public var id: String { provider.rawValue + "/" + profileID }
    public var isUnassigned: Bool { profileID == Self.unassigned }
    public var isDefault: Bool { profileID.hasSuffix("-default") }

    public static func < (a: ProfileKey, b: ProfileKey) -> Bool {
        if a.provider != b.provider { return a.provider.sortOrder < b.provider.sortOrder }
        // Default first, named profiles next, Unassigned last.
        func rank(_ k: ProfileKey) -> Int { k.isDefault ? 0 : (k.isUnassigned ? 2 : 1) }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.profileID < b.profileID
    }
}

extension AgentProvider {
    var sortOrder: Int {
        switch self {
        case .claudeCode: return 0
        case .codex: return 1
        case .imported: return 3
        case .unknown: return 2
        }
    }
    /// "Claude" / "Codex" before a profile name ("Claude · Work").
    public var shortTitle: String {
        switch self {
        case .claudeCode: return "Claude"
        default: return title
        }
    }
}

extension SessionSummary {
    public var profileKey: ProfileKey {
        ProfileKey(provider: provider, profileID: profile?.id ?? ProfileKey.unassigned)
    }
}

/// Phase 12, `results --json`: one final result (the answer that ended a
/// user task) of any session. Display previews only; the verbatim texts come
/// from `show` / `context` as before.
public struct ResultSummary: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public let sessionKey: String
    public let turn: Int
    public let answeredAt: String?
    public let status: TurnStatus
    public let completion: Completion
    public let conversation: Conversation
    public var source: AgentSource? = nil
    public var profile: AgentProfile? = nil
    public var nativeSessionID: String? = nil
    public let project: ProjectRef
    public var logicalProject: LogicalProject? = nil
    public let request: Request?
    public let response: Response
    public let observed: ObservedCounts?

    public var id: String { ref.key }
    public var ref: ReportRef { .local(sessionKey: sessionKey, turn: turn) }
    public var provider: AgentProvider { source?.agent ?? .claudeCode }
    public var host: AgentHost { source?.environment ?? .unknown }
    public var profileKey: ProfileKey { ProfileKey(provider: provider, profileID: profile?.id ?? ProfileKey.unassigned) }

    public struct Conversation: Decodable, Equatable, Hashable, Sendable {
        public let title: String?
        public let sessionID: String?
        enum CodingKeys: String, CodingKey { case title, sessionID = "session_id" }
    }

    public struct Request: Decodable, Equatable, Hashable, Sendable {
        /// The turn whose request names this result (an earlier one for a
        /// background follow-up; then `own` is false).
        public let turn: Int
        public let own: Bool
        public let displayPreview: String?
        public let charCount: Int
        enum CodingKeys: String, CodingKey { case turn, own, displayPreview = "display_preview", charCount = "char_count" }
    }

    public struct Response: Decodable, Equatable, Hashable, Sendable {
        public let preview: String
        public let truncated: Bool
        public let charCount: Int
        enum CodingKeys: String, CodingKey { case preview, truncated, charCount = "char_count" }
    }

    enum CodingKeys: String, CodingKey {
        case sessionKey = "session_key", turn, answeredAt = "answered_at", status, completion, conversation, source, profile
        case nativeSessionID = "native_session_id", project, logicalProject = "logical_project", request, response, observed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try c.decode(String.self, forKey: .sessionKey)
        turn = try c.decode(Int.self, forKey: .turn)
        answeredAt = try c.decodeIfPresent(String.self, forKey: .answeredAt)
        status = try c.decode(TurnStatus.self, forKey: .status)
        completion = try c.decodeIfPresent(Completion.self, forKey: .completion) ?? .from(status)
        conversation = try c.decode(Conversation.self, forKey: .conversation)
        source = try c.decodeIfPresent(AgentSource.self, forKey: .source)
        profile = try c.decodeIfPresent(AgentProfile.self, forKey: .profile)
        nativeSessionID = try c.decodeIfPresent(String.self, forKey: .nativeSessionID)
        project = try c.decode(ProjectRef.self, forKey: .project)
        logicalProject = try c.decodeIfPresent(LogicalProject.self, forKey: .logicalProject)
        request = try c.decodeIfPresent(Request.self, forKey: .request)
        response = try c.decode(Response.self, forKey: .response)
        observed = try c.decodeIfPresent(ObservedCounts.self, forKey: .observed)
    }

    /// Built from a session and one of its turns (Cores without `results`,
    /// test doubles and Previews).
    public init(session: SessionSummary, turn t: Turn) {
        sessionKey = session.sessionKey
        turn = t.index
        answeredAt = t.finalResponse?.receivedAt
        status = t.status
        completion = t.completion
        conversation = Conversation(title: session.title, sessionID: session.sessionID)
        source = session.source
        profile = session.profile
        nativeSessionID = session.nativeSessionID
        project = session.project
        logicalProject = session.logicalProject
        let own = t.requestOrigin != .automated
        let earlier = own ? nil : (t.earlierUserRequest?.turn)
        request = t.request.map { r in
            Request(turn: earlier ?? t.index, own: own || earlier == nil, displayPreview: t.userRequestPreview ?? r.readablePreview,
                    charCount: r.charCount)
        }
        response = Response(preview: t.finalResponse?.preview ?? "", truncated: t.finalResponse?.truncated ?? false,
                            charCount: t.finalResponse?.charCount ?? 0)
        observed = t.observed
    }
}

public struct ResultsData: Decodable, Equatable, Sendable {
    public let total: Int
    public let limit: Int
    public let results: [ResultSummary]
    public init(total: Int, limit: Int, results: [ResultSummary]) { self.total = total; self.limit = limit; self.results = results }
}

/// Phase 12.1: the Core's `attention` — a waiting signal not yet followed by
/// confirmed activity. Never an answer; never derived from a timer.
public struct AgentAttention: Decodable, Equatable, Hashable, Sendable {
    public let state: String
    public let kind: ActionKind
    public let since: String?
    public let subagent: Bool

    public init(kind: ActionKind, since: String?, subagent: Bool = false) {
        state = "needs_input"; self.kind = kind; self.since = since; self.subagent = subagent
    }
}

public enum ActionKind: Equatable, Hashable, Sendable, Decodable {
    case question, planApproval, permission, elicitation, input
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "question": self = .question
        case "plan_approval": self = .planApproval
        case "permission": self = .permission
        case "elicitation": self = .elicitation
        case "input": self = .input
        default: self = .other(raw)
        }
    }

    /// One word for the narrow band beside the camera housing.
    public var shortTitle: String {
        switch self {
        case .question: return "Question"
        case .planApproval: return "Plan"
        case .permission: return "Permission"
        case .elicitation, .input, .other: return "Input"
        }
    }

    /// Safe wording: the type of action only, never the question itself.
    public var title: String {
        switch self {
        case .question: return "Question"
        case .planApproval: return "Plan approval"
        case .permission: return "Permission required"
        case .elicitation, .input, .other: return "Input requested"
        }
    }
}
