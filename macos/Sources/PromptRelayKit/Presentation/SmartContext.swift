import Foundation

/// How much Copy with Context carries (Phase 7). Both come from the Core's
/// one renderer (`export.render_context`); the request and the answer are
/// complete in both. Answer Only is Copy Answer.
public enum ContextDetail: String, CaseIterable, Codable, Sendable {
    /// The default: request, answer, failures, tests and builds, files,
    /// branch and HEAD, attachments, provenance. Output, routine commands and
    /// the list of uncommitted files are left out, and the package says so.
    case standard
    /// Everything BearlyCopy has: also command output, git commands and
    /// the full `git status` list.
    case full

    public var title: String { self == .standard ? "Standard" : "Full" }

    public var help: String {
        switch self {
        case .standard: return "Standard: the request and answer in full, failed commands, tests and builds, changed files, branch and HEAD, attachments. Command output and the uncommitted file list are left out, and the package says so."
        case .full: return "Full: everything BearlyCopy recorded, including command output, git commands and the full list of uncommitted files."
        }
    }
}

/// The `## ` sections of a built package, for Preview's section menu. Read
/// from the text itself, so the menu can never disagree with what is copied.
public struct PackSection: Equatable, Sendable, Identifiable {
    public let title: String
    /// Offset of the heading in the text, in UTF-16 units (NSTextView ranges).
    public let offset: Int
    public var id: Int { offset }

    public static func sections(in text: String) -> [PackSection] {
        var out: [PackSection] = []
        var offset = 0
        var inFence: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = inFence {
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == fence.first }) { inFence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = String(trimmed.prefix { $0 == trimmed.first })
            } else if line.hasPrefix("## ") {
                out.append(PackSection(title: String(line.dropFirst(3)), offset: offset))
            }
            offset += line.utf16.count + 1
        }
        return out
    }

    /// A short name for the menu ("Request", "Answer", …) beside the heading.
    public var short: String {
        let t = title.lowercased()
        if t.contains("request for review") { return "Review request" }
        if t.contains("request") { return "Request" }
        if t.contains("final response") || t.contains("answer") || t.contains("report") && !t.contains("not") { return "Answer" }
        if t.contains("observed") { return "Evidence & commands" }
        if t.contains("files") { return "Files" }
        if t.contains("git") { return "Git" }
        if t.contains("attach") || t.contains("material") { return "Attachments" }
        if t.contains("not checked") || t.contains("limit") { return "Limitations" }
        if t.contains("session") || t.contains("source") { return "Session" }
        return title
    }
}
