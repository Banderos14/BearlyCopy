import Foundation

// Swift view of the Prompt Relay CLI JSON API, version 1
// (docs/JSON_API.md, docs/api/api-v1.schema.json).
//
// Rules from JSON_API.md §6 that this file follows:
// - `api_version` is checked by the client; unknown versions are refused.
// - Unknown fields are ignored (Decodable ignores extra keys).
// - Unknown enum values decode to `.unknown(raw)` instead of failing.

public let supportedAPIVersion = 1

/// The envelope every `prompt-relay <command> --json` prints.
public struct Envelope<Payload: Decodable>: Decodable {
    public let apiVersion: Int
    public let command: String?
    public let ok: Bool
    public let data: Payload?
    public let error: APIErrorInfo?
    public let warnings: [APIWarning]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version", command, ok, data, error, warnings
    }
}

/// Decodes only the version, so a future major version is refused before the
/// payload is interpreted.
struct VersionProbe: Decodable {
    let apiVersion: Int
    enum CodingKeys: String, CodingKey { case apiVersion = "api_version" }
}

public struct APIErrorInfo: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public struct APIWarning: Decodable, Equatable, Hashable, Sendable {
    public let code: String
    public let message: String
}

// MARK: - Open enums

public enum TurnStatus: Equatable, Hashable, Sendable, Decodable {
    case awaitingResponse, noMatchedResponse, stopReceived
    case stopReceivedBackgroundTasksPending, stopReceivedWithoutText, apiError
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "awaiting_response": self = .awaitingResponse
        case "no_matched_response": self = .noMatchedResponse
        case "stop_received": self = .stopReceived
        case "stop_received_background_tasks_pending": self = .stopReceivedBackgroundTasksPending
        case "stop_received_without_text": self = .stopReceivedWithoutText
        case "api_error": self = .apiError
        default: self = .unknown(raw)
        }
    }
}

/// Phase 9.4, the Core's `completion`: what a Stop means for "is the work
/// done". Stop only says the agent stopped responding.
public enum Completion: Equatable, Hashable, Sendable, Decodable {
    /// Stop with text and no work in flight.
    case answer
    /// Work was still running, and the user then sent a new request.
    case answerBackgroundRunning
    /// The last turn; its Stop reported work in flight: a continuation is expected.
    case waitingBackground
    /// Work was in flight and the session went on automatically: not the result.
    case intermediate
    case working, noText, apiError
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "answer": self = .answer
        case "answer_background_running": self = .answerBackgroundRunning
        case "waiting_background": self = .waitingBackground
        case "intermediate": self = .intermediate
        case "working": self = .working
        case "no_text": self = .noText
        case "api_error": self = .apiError
        default: self = .unknown(raw)
        }
    }

    /// For an older Core without `completion`: never more complete than the
    /// status shows (a Stop with work in flight is waiting, not done).
    public static func from(_ status: TurnStatus) -> Completion {
        switch status {
        case .stopReceived: return .answer
        case .stopReceivedBackgroundTasksPending: return .waitingBackground
        case .awaitingResponse: return .working
        case .stopReceivedWithoutText: return .noText
        case .apiError: return .apiError
        case .noMatchedResponse: return .unknown("no_matched_response")
        case .unknown(let raw): return .unknown(raw)
        }
    }

    /// A finished result: Latest, the green dot and notifications.
    public var isFinal: Bool { self == .answer || self == .answerBackgroundRunning }
}

public enum LinkQuality: Equatable, Hashable, Sendable, Decodable {
    case promptID, sequence, ambiguous, none
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "prompt_id": self = .promptID
        case "sequence": self = .sequence
        case "ambiguous": self = .ambiguous
        case "none": self = .none
        default: self = .unknown(raw)
        }
    }
}

// MARK: - Shared pieces

public struct ProjectRef: Decodable, Equatable, Hashable, Sendable {
    public let path: String?
    public let name: String?
}

/// Phase 9.3: the logical project a folder belongs to (the Core's
/// `logical_project`): an enabled project, a verified Git root, a workspace
/// root or the folder itself. The raw `cwd` stays in `project`/`cwds`.
public struct LogicalProject: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let name: String
    /// enabled_project | git_root | workspace | directory (open: unknown values kept).
    public let basis: String

    public init(path: String, name: String, basis: String) {
        self.path = path; self.name = name; self.basis = basis
    }
}

public struct LastTurn: Decodable, Equatable, Hashable, Sendable {
    public let index: Int
    public let status: TurnStatus
    /// When the turn's final response was stored (Core 0.3.x, Phase 9.3).
    public var answeredAt: String? = nil
    /// Phase 9.4 (absent from older Cores: derived from `status`).
    public var completionField: Completion? = nil
    public var continuedInTurn: Int? = nil
    public var completion: Completion { completionField ?? .from(status) }

    enum CodingKeys: String, CodingKey {
        case index, status, answeredAt = "answered_at", completionField = "completion", continuedInTurn = "continued_in_turn"
    }
}

public struct Integrity: Decodable, Equatable, Hashable, Sendable {
    public let corruptLines: Int
    public let unsupportedLines: Int
    public let foreignLines: Int

    enum CodingKeys: String, CodingKey {
        case corruptLines = "corrupt_lines", unsupportedLines = "unsupported_lines", foreignLines = "foreign_lines"
    }
}

public struct SessionSummary: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public let sessionID: String?
    public let sessionKey: String
    public let project: ProjectRef
    public let firstEventAt: String?
    public let lastEventAt: String?
    public let eventCount: Int
    public let turnCount: Int
    public let cwds: [String]
    public let lastTurn: LastTurn?
    public let integrity: Integrity
    /// The first captured request, one line, for display only (Core 0.3+).
    public let title: String?
    /// The title Claude Code gave the session (`session_title`), if any.
    public let claudeCodeTitle: String?
    /// Turns with a final answer.
    public let answeredCount: Int?
    /// A request is waiting for Claude (no Stop yet) and the session was
    /// active in the last 30 minutes. Background tasks at a Stop do not count.
    public let running: Bool?

    public var source: AgentSource? = nil
    /// Phase 9.3: absent from older Cores (then the raw project path is used).
    public var logicalProject: LogicalProject? = nil
    /// Phase 12: the local agent profile (config home, never an account).
    /// Absent for Claude Code sessions recorded before Phase 12: Unassigned.
    public var profile: AgentProfile? = nil
    /// Phase 12: the agent's own session id when the stored key was scoped.
    public var nativeSessionID: String? = nil

    public var id: String { sessionKey }

    enum CodingKeys: String, CodingKey {
        case profile, nativeSessionID = "native_session_id"
        case sessionID = "session_id", sessionKey = "session_key", project, logicalProject = "logical_project"
        case firstEventAt = "first_event_at", lastEventAt = "last_event_at"
        case eventCount = "event_count", turnCount = "turn_count", cwds
        case lastTurn = "last_turn", integrity, title
        case claudeCodeTitle = "claude_code_title", answeredCount = "answered_count", running, source
    }
}

/// `text_summary` (lists) and `text_full` (`show`): `text` is present only in
/// `show` and is the complete verbatim text.
public struct TextRef: Decodable, Equatable, Hashable, Sendable {
    public let preview: String
    public let truncated: Bool
    public let charCount: Int
    public let utf8Bytes: Int
    public let promptID: String?
    public let receivedAt: String?
    public let text: String?
    /// Requests only (Core 0.3, Phase 5.11): the start without automated
    /// blocks and paste wrappers; nil when nothing else remains.
    public let displayPreview: String?

    /// What to show for a request: the Core's cleaned start when present.
    public var readablePreview: String { displayPreview ?? Wording.requestForDisplay(preview).text }

    enum CodingKeys: String, CodingKey {
        case preview, truncated, text
        case displayPreview = "display_preview"
        case charCount = "char_count", utf8Bytes = "utf8_bytes"
        case promptID = "prompt_id", receivedAt = "received_at"
    }
}

public struct BackgroundTasks: Decodable, Equatable, Hashable, Sendable {
    public let reported: Bool
    /// Work in flight at the Stop (monitors excluded).
    public let count: Int?
    /// Monitors (watchers such as an artifact's live updates), not work.
    public let watchers: Int?
}

/// Counts of the tool events observed in a turn (ADR-013). Exit codes
/// describe single commands, never the task.
public struct ObservedCounts: Decodable, Equatable, Hashable, Sendable {
    public let toolEvents: Int
    public let runsExitZero: Int
    public let runsNonzero: Int
    public let runsUnknown: Int
    public let filesChanged: Int
    public let backgroundStarted: Int
    /// Shell commands of any kind that exited non-zero (Core 0.3, Phase 5.11).
    public let commandsNonzero: Int?

    enum CodingKeys: String, CodingKey {
        case toolEvents = "tool_events", runsExitZero = "runs_exit_zero", runsNonzero = "runs_nonzero"
        case commandsNonzero = "commands_nonzero"
        case runsUnknown = "runs_unknown", filesChanged = "files_changed", backgroundStarted = "background_started"
    }
}

public struct ObservedCommand: Decodable, Equatable, Hashable, Sendable {
    public let at: String
    public let command: String?
    public let commandWithheld: String?
    public let kind: String?
    public let outcome: String?
    public let exitCode: Int?
    public let durationMs: Int?
    public let compound: Bool
    public let background: Bool
    public let agentType: String?
    public let afterStop: Bool
    public let outputTail: String?
    public let tailWithheld: String?

    enum CodingKeys: String, CodingKey {
        case at, command, kind, outcome, compound, background
        case commandWithheld = "command_withheld", exitCode = "exit_code", durationMs = "duration_ms"
        case agentType = "agent_type", afterStop = "after_stop", outputTail = "output_tail", tailWithheld = "tail_withheld"
    }

    /// Tests, builds, git, failures and background starts; the rest is counted.
    public var isImportant: Bool {
        ["test", "build", "git"].contains(kind ?? "") || outcome != "ok" || background
    }
}

/// Phase 9.4 (`show` only): earlier turns of the session whose Stop left
/// work running and which this turn continued — the same task.
public struct WorkChain: Decodable, Equatable, Hashable, Sendable {
    public let fromTurn: Int
    public let turns: [Int]
    public let startedAt: String?
    public let filesChanged: [ChangedFile]
    public let shownFiles: [String]

    enum CodingKeys: String, CodingKey {
        case turns, fromTurn = "from_turn", startedAt = "started_at"
        case filesChanged = "files_changed", shownFiles = "shown_files"
    }
}

public struct ChangedFile: Decodable, Equatable, Hashable, Sendable {
    public let path: String
    public let tools: [String]
    public let count: Int
}

/// What the Artifact tool returned about a page Claude published.
public struct ObservedArtifact: Decodable, Equatable, Hashable, Sendable {
    public let title: String?
    public let url: String?
    public let audience: String?
    public let path: String?
    public let sourcePath: String?
    public let at: String?

    enum CodingKeys: String, CodingKey { case title, url, audience, path, at, sourcePath = "source_path" }
}

public struct ObservedDetail: Decodable, Equatable, Hashable, Sendable {
    public let commands: [ObservedCommand]
    public let filesChanged: [ChangedFile]
    public let shownFiles: [String]
    public let artifacts: [ObservedArtifact]
    public let notifications: Int

    enum CodingKeys: String, CodingKey {
        case commands, artifacts, notifications
        case filesChanged = "files_changed", shownFiles = "shown_files"
    }
}

public struct TurnError: Decodable, Equatable, Hashable, Sendable {
    public let type: String?
    public let details: String?
    public let message: String?
}

public struct Turn: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public var nativeTurnID: String? = nil
    public let index: Int
    public let status: TurnStatus
    public let link: LinkQuality
    public let request: TextRef?
    public let finalResponse: TextRef?
    public let responseEventCount: Int
    public let backgroundTasks: BackgroundTasks?
    public let error: TurnError?
    public let candidateRequestTurns: [Int]
    /// Background-task notifications and subagent hand-backs inside the turn.
    public let notificationCount: Int?
    public let observed: ObservedCounts?
    /// Only in `show`.
    public let observedDetail: ObservedDetail?
    /// Who wrote the request, read from its structure (Core 0.3, Phase 5.11).
    public let requestOrigin: RequestOrigin?
    /// For a turn Claude Code started itself: the user's latest earlier request.
    public let earlierUserRequest: EarlierRequest?
    /// Phase 9.3: for a short continuation request ("continue"), the latest
    /// earlier substantive request of the same session — context only; the
    /// turn's own request stays its request.
    public var continuesRequest: EarlierRequest? = nil
    /// Phase 9.4 (absent from older Cores: derived from `status`).
    public var completionField: Completion? = nil
    public var continuedInTurn: Int? = nil
    public var completion: Completion { completionField ?? .from(status) }
    public var workChain: WorkChain? = nil

    public var id: Int { index }

    /// The request to show as the user's: never an automated message.
    public var userRequestPreview: String? {
        requestOrigin == .automated ? earlierUserRequest.map { $0.displayPreview ?? $0.preview }
                                    : request.map(\.readablePreview)
    }

    enum CodingKeys: String, CodingKey {
        case nativeTurnID = "native_turn_id"
        case index, status, link, request, error, observed
        case finalResponse = "final_response", responseEventCount = "response_event_count"
        case backgroundTasks = "background_tasks", candidateRequestTurns = "candidate_request_turns"
        case notificationCount = "notification_count", observedDetail = "observed_detail"
        case requestOrigin = "request_origin", earlierUserRequest = "earlier_user_request"
        case continuesRequest = "continues_request"
        case completionField = "completion", continuedInTurn = "continued_in_turn"
        case workChain = "work_chain"
    }
}

/// `user` and `user_pasted`: no automated blocks; `automated`: only blocks
/// Claude Code injects (a side session reporting back); `unknown`: mixed or
/// unreadable. Values a newer Core adds read as `unknown`.
public enum RequestOrigin: String, Decodable, Equatable, Hashable, Sendable {
    case user, userPasted = "user_pasted", automated, unknown

    public init(from decoder: Decoder) throws {
        self = RequestOrigin(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct EarlierRequest: Decodable, Equatable, Hashable, Sendable {
    public let turn: Int
    public let preview: String
    public let displayPreview: String?
    public let receivedAt: String?
    /// Only in `show` (full): the whole earlier request, verbatim.
    public var text: String? = nil

    enum CodingKeys: String, CodingKey {
        case turn, preview, text
        case displayPreview = "display_preview", receivedAt = "received_at"
    }
}

// MARK: - Command payloads

public struct ProjectInfo: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public let path: String?
    public let name: String?
    public let captureEnabled: Bool
    public let explicitlyEnabled: Bool
    public let sessionCount: Int
    public let lastEventAt: String?
    /// Phase 9.3: the logical project this folder belongs to.
    public var logicalProject: LogicalProject? = nil
    /// Phase 9.3, app side: the raw folders merged into this logical project.
    public var memberPaths: [String] = []

    public var id: String { path ?? "" }

    public init(path: String?, name: String?, captureEnabled: Bool, explicitlyEnabled: Bool,
                sessionCount: Int, lastEventAt: String?, logicalProject: LogicalProject? = nil, memberPaths: [String] = []) {
        self.path = path; self.name = name; self.captureEnabled = captureEnabled
        self.explicitlyEnabled = explicitlyEnabled; self.sessionCount = sessionCount; self.lastEventAt = lastEventAt
        self.logicalProject = logicalProject; self.memberPaths = memberPaths
    }

    enum CodingKeys: String, CodingKey {
        case path, name
        case captureEnabled = "capture_enabled", explicitlyEnabled = "explicitly_enabled"
        case sessionCount = "session_count", lastEventAt = "last_event_at", logicalProject = "logical_project"
    }
}

public struct RetentionSettings: Decodable, Equatable, Sendable {
    public let retentionDays: Int?
    public let automaticDeletion: Bool

    enum CodingKeys: String, CodingKey {
        case retentionDays = "retention_days", automaticDeletion = "automatic_deletion"
    }
}

public struct ProjectsData: Decodable, Equatable, Sendable {
    public let projects: [ProjectInfo]
    public let settings: RetentionSettings
}

public struct SessionsData: Decodable, Equatable, Sendable {
    public let projectFilter: String?
    public let sessions: [SessionSummary]

    enum CodingKeys: String, CodingKey { case projectFilter = "project_filter", sessions }
}

public struct TurnsData: Decodable, Equatable, Sendable {
    public let session: SessionSummary
    public let turns: [Turn]
}

public struct ShowData: Decodable, Equatable, Sendable {
    public let session: SessionSummary
    public let turn: Turn
}

public struct SensitiveFinding: Decodable, Equatable, Hashable, Sendable {
    public let section: String
    public let line: Int
    public let kind: String
}

public struct GitSummary: Decodable, Equatable, Sendable {
    public let available: Bool
    public let reason: String?
    public let branch: String?
    public let head: String?
    public let changedFileCount: Int
    public let changedFilesTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case available, reason, branch, head
        case changedFileCount = "changed_file_count", changedFilesTruncated = "changed_files_truncated"
    }
}

public struct ContextData: Decodable, Equatable, Sendable {
    public let session: SessionSummary
    public let turn: Turn
    public let exportedAt: String
    public let text: String
    public let sensitiveFindings: [SensitiveFinding]
    public let git: GitSummary

    enum CodingKeys: String, CodingKey {
        case session, turn, text, git
        case exportedAt = "exported_at", sensitiveFindings = "sensitive_findings"
    }
}

// MARK: - doctor (only the parts the status screen shows)

public struct DoctorData: Decodable, Equatable, Sendable {
    public struct Core: Decodable, Equatable, Sendable {
        public struct Python: Decodable, Equatable, Sendable {
            public let executable: String
            public let version: String
            public let supported: Bool
        }
        public struct Pinned: Decodable, Equatable, Sendable {
            public let path: String?
            public let state: String
        }
        public let promptRelayVersion: String
        public let python: Python
        public let pinnedPython: Pinned

        enum CodingKeys: String, CodingKey {
            case python
            case promptRelayVersion = "prompt_relay_version", pinnedPython = "pinned_python"
        }
    }
    public struct Storage: Decodable, Equatable, Sendable {
        public let dataDir: String
        public let exists: Bool
        public let writable: Bool
        public let sessionFiles: Int

        enum CodingKeys: String, CodingKey {
            case exists, writable
            case dataDir = "data_dir", sessionFiles = "session_files"
        }
    }
    public struct Capture: Decodable, Equatable, Sendable {
        public let configError: String?
        public let enabledProjects: [String]

        enum CodingKeys: String, CodingKey {
            case configError = "config_error", enabledProjects = "enabled_projects"
        }
    }
    public struct Configuration: Decodable, Equatable, Sendable {
        public struct Plugin: Decodable, Equatable, Sendable {
            public struct Record: Decodable, Equatable, Sendable {
                public let id: String
                public let scope: String?
                public let version: String?
                public let manifestFound: Bool
                public let launcherFound: Bool

                enum CodingKeys: String, CodingKey {
                    case id, scope, version
                    case manifestFound = "manifest_found", launcherFound = "launcher_found"
                }
            }
            public let state: String
            public let records: [Record]
        }
        public let plugin: Plugin
    }
    public struct Observed: Decodable, Equatable, Sendable {
        public struct Via: Decodable, Equatable, Sendable {
            public let events: Int
            public let lastAt: String?
            enum CodingKeys: String, CodingKey { case events, lastAt = "last_at" }
        }
        public let state: String
        public struct Source: Decodable, Equatable, Sendable {
            public let events: Int
            public let lastAt: String
            public let lastEvent: String
            public let lastOutcome: String
            public let lastStoredAt: String?
            public let lastErrorAt: String?
            public let lastError: String?

            enum CodingKeys: String, CodingKey {
                case events
                case lastAt = "last_at", lastEvent = "last_event", lastOutcome = "last_outcome"
                case lastStoredAt = "last_stored_at", lastErrorAt = "last_error_at", lastError = "last_error"
            }
        }
        public let byVia: [String: Via]
        public let outcomes: [String: Int]
        public var bySource: [String: Source]? = nil

        enum CodingKeys: String, CodingKey { case state, outcomes, byVia = "by_via", bySource = "by_source" }
    }
    public struct Finding: Decodable, Equatable, Hashable, Sendable {
        public let level: String
        public let code: String
        public let message: String
    }

    public let core: Core
    public let storage: Storage
    public let capture: Capture
    public let configuration: Configuration
    public let observed: Observed
    public let findings: [Finding]
    public let unverified: [String]
}
