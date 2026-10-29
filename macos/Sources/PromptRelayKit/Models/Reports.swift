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
    /// Pasted into Prompt Relay by the user (for example from a Claude Code
    /// cloud session, which the local hooks cannot observe).
    case cloudManualImport

    public var label: String {
        switch self {
        case .localClaudeCode: return "Claude Code · this Mac"
        case .cloudManualImport: return "Cloud · imported by you"
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
    public var source: ReportSource { .cloudManualImport }
    public var ref: ReportRef { .imported(id: id) }
}

/// An image the user added to a report. The file is copied into Prompt
/// Relay's private folder; the original path is not kept.
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
    /// How it got here. Today always "added by you from a file".
    public let provenance: String
}

/// One copy the user made in Prompt Relay (Recent Copies). Only a
/// reference: the text is fetched again when copying again.
public struct CopyRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case response, reviewPack
        public var title: String { self == .response ? "Response" : "Review Pack" }
    }

    public let id: String
    public let ref: ReportRef
    public let kind: Kind
    public let projectName: String
    public let label: String
    public let at: String
    public let characters: Int
}
