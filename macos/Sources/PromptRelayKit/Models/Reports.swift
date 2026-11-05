import Foundation

/// A stable reference to one report, wherever it lives: a turn the Core
/// captured on this Mac, or a report the user imported by hand. Copy
/// history, pins and attachments store this reference, never the text.
public enum ReportRef: Hashable, Codable, Sendable {
    case local(sessionKey: String, turn: Int)
    case imported(id: String)

    /// A file-name-safe key (attachments are grouped by it).
    public var key: String {
        switch self {
        case .local(let session, let turn):
            let safe = session.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
            return "local-\(safe)-\(turn)"
        case .imported(let id): return "import-\(id)"
        }
    }
}

/// Where a report came from. Shown on every report and written into the
/// Review Pack, so an import is never mistaken for a local capture.
public enum ReportSource: String, Codable, Sendable {
    /// Captured on this Mac by the Prompt Relay hooks (Claude Code Stop).
    case localClaudeCode
    case localCodex
    /// Pasted into Prompt Relay by the user (for example from a Claude Code
    /// cloud session, which the local hooks cannot observe).
    case cloudManualImport

    public var label: String {
        switch self {
        case .localClaudeCode: return "Claude Code · this Mac"
        case .localCodex: return "Codex · this Mac"
        case .cloudManualImport: return "Imported by you"
        }
    }
}

/// A report the user pasted in. The text is kept exactly as pasted.
public struct ImportedReport: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let importedAt: String
    /// The report, verbatim.
    public let text: String
    /// The task as the user supplied it, if they did. Never inferred.
    public var task: String?
    /// The project the user associated it with, if any.
    public var projectPath: String?
    public var projectName: String?
    /// Free text the user gave to identify the cloud session (an ID or URL).
    public var sessionLabel: String?
    /// SHA-256 of the text and task, to recognize a repeated import.
    public let digest: String
    /// Phase 7.1 (optional, older imports decode unchanged): the AI the user
    /// says it came from (`ImportAssistant.rawValue`), and whether a pasted
    /// Prompt Relay package was kept as historical context or plain text.
    public var assistant: String? = nil
    public var importedAs: String? = nil
    public var host: AgentHost? = nil
    public var assistantTitle: String? { assistant.flatMap(ImportAssistant.init(rawValue:))?.title }
    public var isHistoricalPackage: Bool { importedAs == "historical-context" }
    public var source: ReportSource { .cloudManualImport }
    public var ref: ReportRef { .imported(id: id) }
}

/// What kind of material an attachment is (ADR-016). Records written
/// before Phase 5 have no kind and are images.
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case document, pdf, image
    public var label: String {
        switch self {
        case .document: return "Document"
        case .pdf: return "PDF"
        case .image: return "Image"
        }
    }
}

/// Where an attachment came from.
public enum AttachmentSource: String, Codable, Sendable {
    /// The user chose the file (📎, drop).
    case you
    /// Claude showed it to the user (SendUserFile) or wrote it and named it
    /// in its answer; added by the user's click.
    case claude
    /// Named in Claude's answer and found in the project, but no Edit/Write
    /// of it was observed (a script made it, or it is older). Phase 5.11.
    case named
    /// The user's clipboard history.
    case clipboard
    case agentResult
    case agentObserved
    /// Phase 9.3: named in the answer, inside the project, and changed during
    /// this turn (local file time). Not proof the agent created it.
    case namedVerified
    public var label: String {
        switch self {
        case .you: return "you"
        case .claude: return "Claude"
        case .named: return "named by agent"
        case .clipboard: return "clipboard"
        case .agentResult: return "observed result"
        case .agentObserved: return "observed file"
        case .namedVerified: return "named · changed this turn"
        }
    }
}

/// A file kept with a report: a private snapshot copied into Prompt
/// Relay's folder (SHA-256, time). Later changes to the original are not
/// applied silently.
public struct ReportAttachment: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    /// `ReportRef.key` of the report it belongs to.
    public let reportKey: String
    public let originalFilename: String
    public let storedFilename: String
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public let addedAt: String
    /// How it got here, in words.
    public let provenance: String
    // Phase 5 (optional: older records decode unchanged).
    public var kind: AttachmentKind? = nil
    public var source: AttachmentSource? = nil
    public var sourceProvider: AgentProvider? = nil
    /// Where the original was, for display (project-relative when possible).
    public var originalPath: String? = nil
    /// Included in Copy for ChatGPT and the file hand-off (default: yes).
    public var selected: Bool? = nil
    /// The mockup state this image shows, if any.
    public var mockupID: String? = nil
    public var stateID: String? = nil

    public var effectiveKind: AttachmentKind { kind ?? .image }
    public var effectiveSource: AttachmentSource { source ?? .you }
    public var isSelected: Bool { selected ?? true }
}

/// A state of an interactive mockup: a named screen with its own image.
public struct MockupState: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// An image is stored in Prompt Relay.
        case captured
        /// Only the name is known (declared by the page or typed by the user).
        case namedOnly = "named_only"
        /// Getting an image failed; `failure` says why.
        case failed
    }
    public let id: String
    public var title: String
    public var summary: String?
    /// What a still image of this state cannot show (sliders, animation…).
    public var interactive: [String]
    public var status: Status
    public var attachmentID: String?
    public var failure: String?
    public var selected: Bool
}

/// A link or an interactive mockup kept with a report. Neither is a file
/// the reviewer can open: a link is listed with its availability, a mockup
/// with its states and the images actually stored for them.
public struct ReportMaterial: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case link, mockup }
    public let id: String
    public let reportKey: String
    public let kind: Kind
    public var title: String
    public var url: String?
    /// "owner" for a private Claude artifact.
    public var audience: String?
    /// The mockup's source file on this Mac, if known (display only).
    public var sourcePath: String?
    public var version: String?
    public let addedAt: String
    /// "Published by Claude (Artifact)", "Added by you".
    public var provenance: String
    public var selected: Bool
    public var states: [MockupState]

    /// A claude.ai link that only its owner can open.
    public var isPrivateLink: Bool {
        audience == "owner" || (url?.contains("claude.ai/") ?? false)
    }
}

/// One copy the user made in Prompt Relay (Recent Copies). Only a
/// reference: the text is fetched again when copying again.
public struct CopyRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `reviewPack` is the stored name of what is now Copy for ChatGPT.
        case response, reviewPack
        public var title: String { self == .response ? "Answer" : "Copy with Context" }
    }

    public let id: String
    public let ref: ReportRef
    public let kind: Kind
    public let projectName: String
    public let label: String
    public let at: String
    public let characters: Int
}
