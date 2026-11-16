import Foundation

/// The AI a result came from, as the user says (Import AI Result). A
/// detected one is only ever a suggestion the user confirms.
public enum ImportAssistant: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCloud, claudeCode, chatGPT, gemini, codex, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claudeCloud: return "Claude Cloud"
        case .claudeCode: return "Claude Code"
        case .chatGPT: return "ChatGPT"
        case .gemini: return "Gemini"
        case .codex: return "Codex"
        case .other: return "Other"
        }
    }
}

/// What the pasted text itself says, read only from explicit structure:
/// a Prompt Relay package's known headings, a `## Task`-style heading, and
/// `Project:` / `Repository:` fields. Never guessed from loose words; never
/// raises the trust of anything in the text (it stays imported by the user).
public struct ImportAnalysis: Equatable, Sendable {
    /// The text is a Copy with Context package Prompt Relay made earlier.
    public var isPromptRelayPackage = false
    /// A request stated in the text, verbatim, when its place is unambiguous.
    public var task: String?
    /// Local projects named by an explicit field (paths); several = ambiguous.
    public var projects: [String] = []
    /// The project or repository names the text states, as written.
    public var statedProjects: [String] = []
    public var assistant: ImportAssistant?

    public struct LocalProject: Equatable, Sendable {
        public let name: String
        public let path: String
        public init(name: String, path: String) { self.name = name; self.path = path }
    }

    public static func analyze(_ text: String, projects local: [LocalProject]) -> ImportAnalysis {
        var a = ImportAnalysis()
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
        a.isPromptRelayPackage = ["# Copy with Context:", "# Review Pack", "# Copy for ChatGPT", "# Copy Context"].contains { first.hasPrefix($0) }

        // The request: the package's "Original user request" fenced block, or
        // the body under a Task / Request heading. Harness blocks never count.
        a.task = a.isPromptRelayPackage ? packageRequest(lines) : headedSection(lines)
        if let t = a.task, FullTask.hasHarness(t) || t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { a.task = nil }

        // Explicit fields only ("Project:", "Repository:", the package's "- Project:").
        let field = #"^\s*(?:[-*]\s*)?(?:\*\*)?(project|repository|repo|проект|репозиторий)(?:\*\*)?\s*:\s*(?:\*\*)?\s*(.+?)\s*$"#
        let regex = try! NSRegularExpression(pattern: field, options: [.caseInsensitive])
        var stated: [String] = []
        for line in lines {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            var value = ns.substring(with: m.range(at: 2))
            value = value.replacingOccurrences(of: #"\s*\[[^\]]*\]\s*$"#, with: "", options: .regularExpression)   // a provenance label
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`*\"' ."))
            if !value.isEmpty, value.lowercased() != "not specified", !stated.contains(value) { stated.append(value) }
        }
        a.statedProjects = stated
        var matches: [String] = []
        for value in stated {
            let v = value.lowercased()
            let tail = (v.hasSuffix(".git") ? String(v.dropLast(4)) : v).split(separator: "/").last.map(String.init) ?? v
            for p in local where p.name.lowercased() == v || p.path.lowercased() == v || p.name.lowercased() == tail
                || (p.path as NSString).lastPathComponent.lowercased() == tail {
                if !matches.contains(p.path) { matches.append(p.path) }
            }
        }
        a.projects = matches

        // The source, from the package's own Session line or a "Source:" field.
        if a.isPromptRelayPackage, lines.contains(where: { $0.hasPrefix("- Source: Claude Code on this Mac") }) {
            a.assistant = .claudeCode
        } else if let line = lines.first(where: { $0.range(of: #"^\s*(?:[-*]\s*)?(?:\*\*)?(source|assistant|model)(?:\*\*)?\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
            let l = line.lowercased()
            if l.contains("chatgpt") || l.contains("gpt-") { a.assistant = .chatGPT }
            else if l.contains("gemini") { a.assistant = .gemini }
            else if l.contains("codex") { a.assistant = .codex }
            else if l.contains("claude code") { a.assistant = .claudeCode }
            else if l.contains("claude") { a.assistant = .claudeCloud }
        }
        return a
    }

    /// The first fenced block after "## Original user request" (not "Request
    /// (source not established)", not an automatic turn's message).
    static func packageRequest(_ lines: [String]) -> String? {
        guard let start = lines.firstIndex(where: { $0 == "## Original user request" }) else { return nil }
        var i = start + 1
        var fence: String?
        var body: [String] = []
        while i < lines.count {
            let line = lines[i]
            if fence == nil {
                if line.hasPrefix("## ") || line.hasPrefix("### ") { return nil }
                if line.contains("This turn was not started by the user") { return nil }
                if line.hasPrefix("```") || line.hasPrefix("~~~") { fence = String(line.prefix { $0 == line.first }) }
            } else if let f = fence, line.hasPrefix(f), line.allSatisfy({ $0 == f.first }) {
                return body.joined(separator: "\n")
            } else {
                body.append(line)
            }
            i += 1
        }
        return nil
    }

    /// The body under one `# Task`, `## Request`, `## Original request`,
    /// `## Задача` or `## Запрос` heading, up to the next heading. Two such
    /// headings: ambiguous, nothing suggested.
    static func headedSection(_ lines: [String]) -> String? {
        let heading = #"^#{1,3}\s*(task|request|original request|user request|prompt|задача|запрос)\s*:?\s*$"#
        let starts = lines.indices.filter { lines[$0].range(of: heading, options: [.regularExpression, .caseInsensitive]) != nil }
        guard starts.count == 1, let s = starts.first else { return nil }
        var body: [String] = []
        for line in lines[(s + 1)...] {
            if line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil { break }
            body.append(line)
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension AppModel {
    /// An existing import with exactly this text, to warn before a repeat.
    public func existingImport(text: String) -> ImportedReport? {
        imports.first { $0.text == text }
    }

    public var localProjectsForImport: [ImportAnalysis.LocalProject] {
        projectRows.map { ImportAnalysis.LocalProject(name: $0.name, path: $0.path) }
    }
}
