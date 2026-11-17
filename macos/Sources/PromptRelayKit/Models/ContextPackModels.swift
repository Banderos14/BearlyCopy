import Foundation

// Phase 13: Context Packs — several results in one hand-off (docs/CONTEXT_PACK.md).

/// One slot of a pack in the order the user chose: a result captured on this
/// Mac (the Core renders its section) or a slot the app fills itself (an
/// imported report). External slots keep the Core's numbering right.
public enum PackSlot: Equatable, Sendable {
    case local(sessionKey: String, turn: Int)
    case external

    var argument: String {
        switch self {
        case .local(let key, let turn): return "\(key):\(turn)"
        case .external: return "external"
        }
    }
}

/// `prompt-relay context-pack --json` (JSON API v1, `context_pack_data`).
public struct ContextPackData: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let provider: String
        public let agent: String
        public let profile: String
        public let host: String
        public let project: String
        public let title: String
        public let answeredAt: String
        public init(provider: String, agent: String, profile: String, host: String, project: String, title: String, answeredAt: String) {
            self.provider = provider; self.agent = agent; self.profile = profile; self.host = host
            self.project = project; self.title = title; self.answeredAt = answeredAt
        }
        enum CodingKeys: String, CodingKey { case provider, agent, profile, host, project, title, answeredAt = "answered_at" }
    }

    public struct Result: Decodable, Equatable, Sendable {
        public let sessionKey: String
        public let turn: Int
        public let position: Int
        public let resultID: String
        public let entry: Entry
        /// One result's Markdown body, verbatim from the Core.
        public let section: String
        public let sensitiveFindings: [SensitiveFinding]
        public let warnings: [String]
        public let manifest: PackManifest.Result
        enum CodingKeys: String, CodingKey {
            case sessionKey = "session_key", turn, position, resultID = "result_id", entry, section
            case sensitiveFindings = "sensitive_findings", warnings, manifest
        }
    }

    public let format: String
    public let formatVersion: Int
    public let exportedAt: String
    public let results: [Result]
    /// The Core's own whole document (local results only, no attachments).
    public let text: String
    public let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case format, formatVersion = "format_version", exportedAt = "exported_at", results, text, warnings
    }
}

/// The machine-readable side of a pack: facts about it, its results and
/// their provenance. No absolute paths, no session ids, no request or
/// response text (results are named by an opaque `result_id`).
public struct PackManifest: Codable, Equatable, Sendable {
    public struct Request: Codable, Equatable, Sendable {
        public var included: Bool
        public var provenance: String
        public var origin: String
        public var characters: Int?
        public var earlierUserRequestTurn: Int?
    }
    public struct Response: Codable, Equatable, Sendable {
        public var included: Bool
        public var provenance: String
        public var characters: Int
    }
    public struct Observed: Codable, Equatable, Sendable {
        public var provenance: String
        public var toolEvents: Int?
        public var filesChanged: Int?
        public var runsExitZero: Int?
        public var runsNonzero: Int?
        public var runsUnknown: Int?
        public var backgroundStarted: Int?
        public var commandsNonzero: Int?
    }
    public struct Attachment: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var bytes: Int
        /// "file", "memory_only" (a window snapshot, never written) or "missing".
        public var availability: String
        public var origin: String
    }
    public struct Result: Codable, Equatable, Sendable {
        public var position: Int
        public var resultId: String
        /// "local_capture" or "user_import".
        public var kind: String
        public var provider: String
        public var profile: String
        public var profileRecorded: Bool?
        public var host: String
        public var project: String
        public var turn: Int?
        public var answeredAt: String?
        public var status: String?
        public var completion: String?
        public var link: String?
        public var request: Request
        public var response: Response
        public var observed: Observed?
        public var attachments: [Attachment]
    }
    public struct Instructions: Codable, Equatable, Sendable {
        public var suppliedByUser: Bool
        public var characters: Int
    }

    public var format = ContextPackFormat.name
    public var formatVersion = ContextPackFormat.version
    public var preparedAt: String
    public var preparedBy: String
    public var aiServiceUsed = false
    public var resultCount: Int
    public var results: [Result]
    public var reviewInstructions: Instructions
    public var markdownCharacters: Int
    public var destination: String
    public var warnings: [String]
    public var limits: [String]

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Pretty, sorted, snake_case JSON (Export writes it as manifest.json).
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension PackManifest.Result {
    // The Core writes snake_case keys; decode them the same way the manifest does.
    public init(from decoder: Decoder) throws {
        enum K: String, CodingKey {
            case position, resultId = "result_id", kind, provider, profile, profileRecorded = "profile_recorded", host, project, turn
            case answeredAt = "answered_at", status, completion, link, request, response, observed, attachments
        }
        let c = try decoder.container(keyedBy: K.self)
        position = try c.decode(Int.self, forKey: .position)
        resultId = try c.decode(String.self, forKey: .resultId)
        kind = try c.decode(String.self, forKey: .kind)
        provider = try c.decode(String.self, forKey: .provider)
        profile = try c.decode(String.self, forKey: .profile)
        profileRecorded = try c.decodeIfPresent(Bool.self, forKey: .profileRecorded)
        host = try c.decode(String.self, forKey: .host)
        project = try c.decode(String.self, forKey: .project)
        turn = try c.decodeIfPresent(Int.self, forKey: .turn)
        answeredAt = try c.decodeIfPresent(String.self, forKey: .answeredAt)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        completion = try c.decodeIfPresent(String.self, forKey: .completion)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        request = try PackManifest.Request.snake(c.superDecoder(forKey: .request))
        response = try PackManifest.Response.snake(c.superDecoder(forKey: .response))
        observed = try c.decodeIfPresent(SnakeObserved.self, forKey: .observed)?.value
        attachments = try c.decodeIfPresent([PackManifest.Attachment].self, forKey: .attachments) ?? []
    }
}

private struct SnakeObserved: Decodable {
    let value: PackManifest.Observed
    init(from decoder: Decoder) throws {
        enum K: String, CodingKey {
            case provenance, toolEvents = "tool_events", filesChanged = "files_changed", runsExitZero = "runs_exit_zero"
            case runsNonzero = "runs_nonzero", runsUnknown = "runs_unknown", backgroundStarted = "background_started"
            case commandsNonzero = "commands_nonzero"
        }
        let c = try decoder.container(keyedBy: K.self)
        value = PackManifest.Observed(provenance: try c.decodeIfPresent(String.self, forKey: .provenance) ?? "confirmed_locally",
                                      toolEvents: try c.decodeIfPresent(Int.self, forKey: .toolEvents),
                                      filesChanged: try c.decodeIfPresent(Int.self, forKey: .filesChanged),
                                      runsExitZero: try c.decodeIfPresent(Int.self, forKey: .runsExitZero),
                                      runsNonzero: try c.decodeIfPresent(Int.self, forKey: .runsNonzero),
                                      runsUnknown: try c.decodeIfPresent(Int.self, forKey: .runsUnknown),
                                      backgroundStarted: try c.decodeIfPresent(Int.self, forKey: .backgroundStarted),
                                      commandsNonzero: try c.decodeIfPresent(Int.self, forKey: .commandsNonzero))
    }
}

extension PackManifest.Request {
    static func snake(_ decoder: Decoder) throws -> Self {
        enum K: String, CodingKey { case included, provenance, origin, characters, earlierUserRequestTurn = "earlier_user_request_turn" }
        let c = try decoder.container(keyedBy: K.self)
        return Self(included: try c.decode(Bool.self, forKey: .included), provenance: try c.decode(String.self, forKey: .provenance),
                    origin: try c.decode(String.self, forKey: .origin), characters: try c.decodeIfPresent(Int.self, forKey: .characters),
                    earlierUserRequestTurn: try c.decodeIfPresent(Int.self, forKey: .earlierUserRequestTurn))
    }
}

extension PackManifest.Response {
    static func snake(_ decoder: Decoder) throws -> Self {
        enum K: String, CodingKey { case included, provenance, characters }
        let c = try decoder.container(keyedBy: K.self)
        return Self(included: try c.decode(Bool.self, forKey: .included), provenance: try c.decode(String.self, forKey: .provenance),
                    characters: try c.decode(Int.self, forKey: .characters))
    }
}

/// The pack format, versioned apart from the app, the Core and JSON API v1.
public enum ContextPackFormat {
    public static let name = "prompt-relay-context-pack"
    public static let version = 1
    /// The most results in one pack (the Core enforces the same).
    public static let maxResults = 20
    /// Above this many characters the pack view warns: long pastes may be
    /// cut or refused by the receiving app (not verified per app).
    public static let longPasteCharacters = 100_000
    /// Above this the pack is not put on the clipboard: Export it instead.
    /// Measured: a 4 MB string copies and reads back in well under a second
    /// (Phase13Tests), so this is about the receiving chat, not the pasteboard.
    public static let maxClipboardCharacters = 2_000_000
}

// MARK: - Destinations

/// Where the user says they will take the pack. A receiver, not a capture
/// source. Nothing here was tested against the real apps unless it says so:
/// BearlyCopy never pastes, sends, reads another app's chat or drives a
/// browser. The choice only changes the guidance and the suggested order.
public enum HandoffDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case generic, chatGPT = "chatgpt", claude, gemini, codex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .generic: return "Any AI chat"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .codex: return "Codex"
        }
    }

    /// What a receiver may take, as far as BearlyCopy knows.
    public enum Support: String, Equatable, Sendable {
        /// Standard macOS behaviour for this kind of receiver (still not tested by BearlyCopy).
        case standard
        /// Not verified on this Mac: try it; it may not work.
        case unverified
        /// Known not to work for this kind of receiver.
        case unsupported

        public var label: String {
            switch self {
            case .standard: return "standard paste"
            case .unverified: return "not verified"
            case .unsupported: return "not possible"
            }
        }
    }

    public enum Capability: String, CaseIterable, Identifiable, Sendable {
        case plainText, markdown, imageData, fileURL, multipleFiles
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .plainText: return "Text"
            case .markdown: return "Markdown"
            case .imageData: return "Image data"
            case .fileURL: return "Files"
            case .multipleFiles: return "Several files at once"
            }
        }
    }

    public func support(_ capability: Capability) -> Support {
        switch (self, capability) {
        case (_, .plainText): return .standard
        // Markdown is pasted as its plain-text source everywhere; whether a
        // receiver renders it is up to that app.
        case (_, .markdown): return .standard
        // A terminal takes text only: a dropped file becomes its path, and
        // image data cannot be pasted (standard Terminal behaviour).
        case (.codex, .imageData): return .unsupported
        case (.codex, .fileURL), (.codex, .multipleFiles): return .unverified
        default: return .unverified
        }
    }

    /// One or two plain sentences about this receiver.
    public var guidance: String {
        switch self {
        case .generic:
            return "Paste the text into the chat first, then add the files with Copy Files or Drag. Check that every file appears before you send."
        case .chatGPT, .claude, .gemini:
            return "Paste the text into a new message, then add the files with Drag or Copy Files. Whether text and several images arrive in one paste is not verified; check the message before you send it."
        case .codex:
            return "Paste the text into the Codex prompt. In a terminal, a dropped file becomes its path and images cannot be pasted; Export the pack to a folder if Codex should read the files."
        }
    }

    /// Codex in a terminal reads files from disk, so Export comes before Drag.
    public var prefersExport: Bool { self == .codex }
}
