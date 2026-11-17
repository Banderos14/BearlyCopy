import Foundation

/// Phase 13: one Context Pack — several results for another AI, each in its
/// own section (docs/CONTEXT_PACK.md).
///
/// The result sections of local captures come from the Core verbatim
/// (`context-pack`: the same functions as Copy with Context, one heading
/// level deeper). The app adds what only it knows — the chosen attachments
/// with their availability, imported reports, the user's profile names and
/// review instructions — and composes the document with the same frame as
/// the Core's `render_pack` (tests compare the two). Nothing in a result is
/// rewritten, summarised or merged with another result.
public enum ContextPackComposer {
    static let confirmed = ReviewPack.confirmed
    static let notVerified = ReviewPack.notVerified
    static let unavailable = ReviewPack.unavailable
    static let userSupplied = ReviewPack.userSupplied

    public static let standardRequest = "Please review each result independently. For each one, check whether the response fulfils its "
        + "original request, compare the agent's claims with what was observed, and point out unsupported "
        + "claims, risks and missing verification. Where results depend on each other, say where they agree "
        + "or conflict, without treating one agent's statement as proof of another's. Propose the next "
        + "concrete step."

    /// What one result brings into the pack.
    public struct Input: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            case local(ContextPackData.Result)
            case imported(ImportedReport)
        }
        public let ref: ReportRef
        public let source: Source
        /// The user's own profile name, when they gave one ("Work").
        public var profileLabel: String?
        /// The selected attachments in hand-off order (documents, states, images).
        public var attachments: [ReportAttachment] = []
        public var materials: [ReportMaterial] = []
        public var names: [String: String] = [:]
        /// Attachment ids whose stored copy or memory image is gone.
        public var missing: Set<String> = []

        public init(ref: ReportRef, source: Source, profileLabel: String? = nil, attachments: [ReportAttachment] = [],
                    materials: [ReportMaterial] = [], names: [String: String] = [:], missing: Set<String> = []) {
            self.ref = ref; self.source = source; self.profileLabel = profileLabel; self.attachments = attachments
            self.materials = materials; self.names = names; self.missing = missing
        }

        var entry: ContextPackData.Entry {
            switch source {
            case .local(let r):
                let e = r.entry
                return .init(provider: e.provider, agent: e.agent, profile: profileLabel ?? e.profile, host: e.host,
                             project: e.project, title: e.title, answeredAt: e.answeredAt)
            case .imported(let report):
                return .init(provider: "Imported by you", agent: "agent", profile: report.assistantTitle ?? "AI",
                             host: report.host?.title ?? "Unknown", project: report.projectName ?? "not specified",
                             title: ContextPackComposer.firstLine(report.task ?? ""), answeredAt: report.importedAt)
            }
        }
    }

    static func firstLine(_ text: String) -> String {
        String((text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").prefix(160))
    }

    // MARK: Frame (the same text as context_pack.py)

    static func preamble(count: Int, exportedAt: String, agents: [String]) -> [String] {
        let reported = agents.map { a in
            a == "agent" ? "[\(ReviewPack.reported)] = the imported AI's own words, not checked"
                         : "[Reported by \(a)] = \(a)'s own words, not checked"
        }.joined(separator: "; ")
        return [
            "# Context Pack: \(count) AI \(count == 1 ? "result" : "results") for an independent check",
            "Prepared by BearlyCopy at \(exportedAt). No AI service was used. Format: \(ContextPackFormat.name) v\(ContextPackFormat.version).",
            "",
            "Provenance labels: [\(confirmed)] = recorded on this machine by BearlyCopy; "
                + (reported.isEmpty ? "" : reported + "; ")
                + "[\(userSupplied)] = typed or pasted into BearlyCopy by the user; "
                + "[\(notVerified)] = no independent source; [\(unavailable)] = could not be determined.",
            "",
            "Each result below is a separate section with its own source. Their texts are not merged or rewritten, "
                + "and one agent's statements do not confirm another's.",
            "",
        ]
    }

    static func contents(_ entries: [ContextPackData.Entry], warnings: [String]) -> [String] {
        var lines = ["## Contents"]
        for (n, e) in entries.enumerated() {
            let words = e.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let scalars = Array(words.unicodeScalars)
            let title = scalars.count <= 80 ? words : String(String.UnicodeScalarView(scalars.prefix(79))) + "…"
            lines.append("\(n + 1). \(e.provider) · \(e.profile) · \(e.host) — project \(e.project)"
                         + (title.isEmpty ? "" : " — “\(title)”")
                         + " — answered \(e.answeredAt.isEmpty ? unavailable : e.answeredAt)")
        }
        lines += warnings.map { "- Warning: " + $0 }
        lines.append("")
        return lines
    }

    static func heading(_ n: Int, of total: Int, _ e: ContextPackData.Entry) -> String {
        "## Result \(n) of \(total) — \(e.provider) · \(e.profile) · \(e.host) · \(e.project)"
    }

    public static func instructionsSection(_ instructions: String?) -> [String] {
        if let text = instructions, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["## Review instructions",
                    "[\(userSupplied)] Written by the user for the receiving AI. Not part of any agent's result.",
                    "",
                    ReviewPack.block(text, info: "text"),
                    ""]
        }
        return ["## Review request",
                "[BearlyCopy standard text] The user wrote no instructions; this is BearlyCopy's default request.",
                "",
                standardRequest,
                ""]
    }

    static func mixedProjectWarning(_ projects: [String]) -> String? {
        let distinct = Array(Set(projects)).sorted { Array($0.unicodeScalars).lexicographicallyPrecedes(Array($1.unicodeScalars)) { $0.value < $1.value } }
        guard distinct.count >= 2 else { return nil }
        return "these results come from \(distinct.count) different projects (\(distinct.joined(separator: ", "))). "
            + "Their contexts are separate; a file or command in one project says nothing about another."
    }

    /// One heading level deeper for every heading outside a fenced block
    /// (test doubles only; the real Core writes its sections this way).
    static func shiftOutsideFences(_ text: String) -> String {
        var fence: String?
        return text.components(separatedBy: "\n").map { line -> String in
            let run = String(line.prefix { $0 == "`" })
            if fence == nil, run.count >= 3 { fence = run; return line }
            if let f = fence { if line == f { fence = nil }; return line }
            return line.hasPrefix("#") ? "#" + line : line
        }.joined(separator: "\n")
    }

    /// Puts every heading line written by BearlyCopy one level deeper. Only
    /// used on lines the app generated itself (never on a verbatim block).
    static func shifted(_ lines: [String]) -> [String] {
        lines.map { $0.hasPrefix("#") ? "#" + $0 : $0 }
    }

    // MARK: One result's body

    /// The attachments of one result, one level deeper, plus what is only in
    /// memory and what is gone. Missing items are listed, never offered.
    static func attachmentLines(_ input: Input) -> [String] {
        let present = input.attachments.filter { !input.missing.contains($0.id) }
        let gone = input.attachments.filter { input.missing.contains($0.id) }
        guard !input.attachments.isEmpty || !input.materials.isEmpty else { return [] }
        var lines: [String] = []
        if !present.isEmpty || !input.materials.isEmpty {
            lines += shifted(ReviewPack.attachmentsSection(present, materials: input.materials, names: input.names)
                .components(separatedBy: "\n"))
        }
        let memory = present.filter(\.isInMemory)
        if !memory.isEmpty || !gone.isEmpty {
            lines += ["", "#### Availability (checked when this pack was prepared)"]
            for a in memory {
                lines.append("- \(input.names[a.id] ?? a.originalFilename) — temporary window snapshot, held in memory only "
                             + "(no file was written); lost when BearlyCopy quits [\(confirmed)]")
            }
            for a in gone {
                lines.append("- \(input.names[a.id] ?? a.originalFilename) — not available: \(a.isInMemory ? "the snapshot is no longer in memory" : "the stored copy is missing"); "
                             + "it is not part of this pack [\(confirmed)]")
            }
        }
        lines.append("")
        return lines
    }

    static func body(_ input: Input) -> String {
        let attachments = attachmentLines(input)
        switch input.source {
        case .local(let r):
            guard !attachments.isEmpty else { return r.section }
            let section = attachments.joined(separator: "\n") + "\n"
            if let anchor = r.section.range(of: "\n### Not checked (provenance and verification limits)\n", options: .backwards) {
                var text = r.section
                text.insert(contentsOf: section, at: text.index(after: anchor.lowerBound))
                return text
            }
            return r.section + "\n" + section
        case .imported(let report):
            let lines = shifted(ReviewPack.importedSections(report)) + attachments + shifted(ReviewPack.importedNotChecked())
            return lines.joined(separator: "\n") + "\n"
        }
    }

    // MARK: The document

    /// The whole Markdown pack. `coreWarnings`: the Core's per-result
    /// warnings, already numbered ("Result 2: …").
    public static func compose(_ inputs: [Input], exportedAt: String, instructions: String?, coreWarnings: [String] = []) -> String {
        let entries = inputs.map(\.entry)
        var agents: [String] = []
        for e in entries where !agents.contains(e.agent) { agents.append(e.agent) }
        var warnings = coreWarnings
        if let mixed = mixedProjectWarning(entries.map(\.project)) { warnings.insert(mixed, at: 0) }
        var lines = preamble(count: inputs.count, exportedAt: exportedAt, agents: agents) + contents(entries, warnings: warnings)
        for (n, input) in inputs.enumerated() {
            lines.append(heading(n + 1, of: inputs.count, entries[n]))
            lines.append("")
            var text = body(input)
            while text.hasSuffix("\n") { text.removeLast() }
            lines.append(text)
            lines.append("")
        }
        lines += instructionsSection(instructions)
        var out = lines.joined(separator: "\n")
        while out.hasSuffix("\n") { out.removeLast() }
        return out + "\n"
    }
}

/// A prepared pack: the exact text a copy puts on the clipboard, its
/// manifest, and what each result brings. Immutable: a change to the
/// selection, the order, the instructions or the attachments needs a new one.
public struct BuiltContextPack: Equatable, Sendable, Identifiable {
    public struct AttachmentStatus: Equatable, Sendable, Identifiable {
        public enum Availability: String, Equatable, Sendable {
            /// A stored copy exists and is handed over as a file.
            case file
            /// A window snapshot held in memory only: image data, no file.
            case memoryOnly = "memory_only"
            /// Gone: listed in the pack as not available, never sent.
            case missing
        }
        public let id: String
        public let ref: ReportRef
        public let name: String
        public let kind: AttachmentKind
        public let bytes: Int
        public let availability: Availability
        public let origin: AttachmentSource
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let ref: ReportRef
        public let position: Int
        public let entry: ContextPackData.Entry
        public let isImport: Bool
        public let attachments: [AttachmentStatus]
        public let findings: [SensitiveFinding]
        public let responseCharacters: Int
        public let requestOrigin: String
        public var id: String { ref.key }
    }

    public let id: String
    public let builtAt: String
    public let text: String
    public let manifest: PackManifest
    public let items: [Item]
    public let warnings: [String]
    public let instructions: String?
    public let destination: HandoffDestination
    /// The manifest is appended to the text.
    public var includesManifest = false

    public var refs: [ReportRef] { items.map(\.ref) }
    public var characters: Int { CharacterCount.of(text) }
    public var findingCount: Int { items.reduce(0) { $0 + $1.findings.count } }
    public var attachments: [AttachmentStatus] { items.flatMap(\.attachments) }
    /// Files and snapshots that can be handed over now.
    public var sendable: [AttachmentStatus] { attachments.filter { $0.availability != .missing } }
    public var temporaryImages: Int { attachments.filter { $0.availability == .memoryOnly }.count }
    public var missingCount: Int { attachments.filter { $0.availability == .missing }.count }
    public var isLong: Bool { characters > ContextPackFormat.longPasteCharacters }
    public var isTooLargeForClipboard: Bool { characters > ContextPackFormat.maxClipboardCharacters }
    public var projects: [String] { Array(Set(items.map(\.entry.project))).sorted() }
    public var mixesProjects: Bool { projects.count > 1 }
}

extension BuiltContextPack.AttachmentStatus {
    var manifest: PackManifest.Attachment {
        PackManifest.Attachment(name: name, kind: kind.rawValue, bytes: bytes, availability: availability.rawValue,
                                origin: origin.rawValue)
    }
}
