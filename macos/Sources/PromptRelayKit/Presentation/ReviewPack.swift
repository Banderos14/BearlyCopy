import Foundation

/// Copy for ChatGPT (formerly the Review Pack): Markdown for an independent
/// review in another chat.
///
/// For a report captured on this Mac the Core writes it (`context`), with
/// read-only git state and its secret scan. For an imported report the app
/// writes it here in the same format and with the same provenance labels,
/// saying plainly that it was pasted in by the user and that nothing in it
/// was checked. In both cases the report is included in full, unmodified,
/// inside a fence longer than any fence it contains.
public enum ReviewPack {
    static let confirmed = "Confirmed locally"
    static let reported = "Reported by Claude"
    static let notVerified = "Not verified"
    static let unavailable = "Unavailable"
    static let userSupplied = "Supplied by you"

    /// A fence longer than every backtick run in `text` (at least three).
    static func fence(_ text: String) -> String {
        var longest = 0, run = 0
        for ch in text {
            if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    static func block(_ text: String, info: String) -> String {
        let f = fence(text)
        return "\(f)\(info)\n\(text)\n\(f)"
    }

    public static func render(imported report: ImportedReport, attachments: [ReportAttachment], exportedAt: String,
                              materials: [ReportMaterial] = [], names: [String: String] = [:]) -> String {
        var lines: [String] = []
        func add(_ s: String = "") { lines.append(s) }
        add("# Copy for ChatGPT: Claude Code result for independent review")
        add("Exported by Prompt Relay at \(exportedAt). No AI service was used.")
        add()
        add("Provenance labels: [\(confirmed)] = recorded on this machine by Prompt Relay; "
            + "[\(userSupplied)] = typed or pasted into Prompt Relay by the user; "
            + "[\(reported)] = Claude's own words, not checked; [\(notVerified)] = no independent source; "
            + "[\(unavailable)] = could not be determined.")
        add()
        add("## Session")
        add("- Source: Claude Code cloud session, imported manually: the user pasted this report into Prompt Relay. "
            + "Prompt Relay did not observe the session. [\(userSupplied)]")
        add("- Project: \(report.projectName ?? "not specified") [\(report.projectName == nil ? unavailable : userSupplied)]")
        add("- Cloud session: \(report.sessionLabel ?? "not specified") [\(report.sessionLabel == nil ? unavailable : userSupplied)]")
        add("- Imported at: \(report.importedAt) [\(confirmed)]")
        add()
        add("## Original user request")
        if let task = report.task {
            add("[\(userSupplied)] As entered by the user when importing; not matched by Prompt Relay.")
            add()
            add(block(task, info: "text"))
        } else {
            add("[\(unavailable)] The request was not supplied, so it is not included.")
        }
        add()
        add("## Claude final response")
        add("[\(reported)] Verbatim text as pasted by the user.")
        add()
        add(block(report.text, info: "markdown"))
        add()
        add("## Observed during this turn")
        add("[\(unavailable)] Prompt Relay did not observe the cloud session: no commands, tests or files are known.")
        add()
        add("## Git state")
        add("- [\(unavailable)] Not collected: the work happened in a cloud session, not in a folder on this Mac.")
        add()
        appendTail(&lines, attachments: attachments, materials: materials, names: names)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Core's pack for a local report, with the materials the user
    /// selected listed before "Not checked" (by name; files go separately).
    /// The last such heading is the Core's own: the response, which may
    /// contain any heading, comes earlier. Without it the section is appended.
    public static func render(local coreText: String, attachments: [ReportAttachment],
                              materials: [ReportMaterial] = [], names: [String: String] = [:]) -> String {
        guard !attachments.isEmpty || !materials.isEmpty else { return coreText }
        let section = attachmentsSection(attachments, materials: materials, names: names) + "\n\n"
        if let anchor = coreText.range(of: "\n## Not checked\n", options: .backwards) {
            var text = coreText
            text.insert(contentsOf: section, at: text.index(after: anchor.lowerBound))
            return text
        }
        return coreText + "\n" + section
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    static func type(_ a: ReportAttachment) -> String {
        let ext = (a.originalFilename as NSString).pathExtension.uppercased()
        switch a.effectiveKind {
        case .document: return ext.isEmpty ? "Text" : ext
        case .pdf: return "PDF"
        case .image: return a.mimeType.split(separator: "/").last.map { String($0).uppercased() } ?? "Image"
        }
    }

    static func origin(_ a: ReportAttachment) -> String {
        switch a.effectiveSource {
        case .you: return "added by you [\(userSupplied)]"
        case .claude: return "shown or written by Claude in this turn [\(confirmed)]"
        case .named: return "named in Claude's answer and found in the project; not seen being written in this turn [\(reported)]"
        case .clipboard: return "from your clipboard [\(userSupplied)]"
        }
    }

    /// The attachments section: what is selected, by group, and what is not
    /// available. It lists files; it never says they were sent.
    static func attachmentsSection(_ attachments: [ReportAttachment], materials: [ReportMaterial] = [],
                                   names: [String: String] = [:]) -> String {
        let files = attachments.filter { $0.mockupID == nil }
        let mockups = materials.filter { $0.kind == .mockup }
        let links = materials.filter { $0.kind == .link }
        let stateFiles = mockups.flatMap { m in m.states.filter { $0.selected && $0.status == .captured } }.count
        let fileCount = files.count + stateFiles
        var lines = ["## Attachments (\(fileCount) \(fileCount == 1 ? "file" : "files"), sent separately)",
                     "These files are part of this review only if they are attached to this message. "
                     + "Prompt Relay does not send files; links are listed, not opened."]
        let documents = files.filter { $0.effectiveKind != .image }
        let images = files.filter { $0.effectiveKind == .image }
        if !documents.isEmpty {
            lines += ["", "### Documents"]
            for a in documents {
                let path = a.originalPath.map { " (\($0))" } ?? ""
                lines.append("- \(names[a.id] ?? a.originalFilename)\(path) — \(type(a)), \(size(a.byteCount)) — \(origin(a)); "
                             + "snapshot \(a.addedAt)")
            }
        }
        if !images.isEmpty {
            lines += ["", "### Images"]
            for a in images {
                lines.append("- \(names[a.id] ?? a.originalFilename) — \(type(a)), \(size(a.byteCount)) — \(origin(a))")
            }
        }
        var unavailable: [String] = []
        if !mockups.isEmpty {
            lines += ["", "### Interactive mockups"]
            for m in mockups {
                lines.append("#### \(m.title) — Visual mockup, review required")
                lines.append("- Source: \(m.provenance)")
                if let url = m.url {
                    lines.append("- Link: \(url) — " + (m.isPrivateLink ? "private; you probably cannot open it [\(unavailable)]"
                                                                    : "not opened by Prompt Relay"))
                }
                let captured = m.states.filter { $0.selected && $0.status == .captured }
                lines.append("- States known: \(m.states.count) · images attached: \(captured.count)")
                if !captured.isEmpty {
                    lines.append("| # | File | State | What it shows | Not visible on a still |")
                    lines.append("|---|---|---|---|---|")
                    for (n, state) in captured.enumerated() {
                        let file = state.attachmentID.flatMap { names[$0] } ?? "\(state.id).png"
                        let still = state.interactive.isEmpty ? "—" : state.interactive.joined(separator: ", ")
                        lines.append("| \(n + 1) | \(file) | \(cell(state.title)) | \(cell(state.summary ?? "—")) | \(cell(still)) |")
                    }
                }
                for state in m.states where state.status != .captured || !state.selected {
                    let why: String
                    if !state.selected { why = "excluded by you" }
                    else if state.status == .failed { why = "failed: \(state.failure ?? "unknown reason")" }
                    else { why = "known by name only; no image" }
                    unavailable.append("Mockup \"\(m.title)\", state \"\(state.title)\": \(why)")
                }
                lines.append("Transitions, animations, pointer reactions and feel cannot be judged from still images; "
                             + "the owner reviews them separately.")
            }
        }
        if !links.isEmpty {
            lines += ["", "### Links"]
            for l in links {
                lines.append("- \(l.title): \(l.url ?? "?") — " + (l.isPrivateLink ? "private; you probably cannot open it" : "not opened by Prompt Relay"))
            }
        }
        if !unavailable.isEmpty {
            lines += ["", "### Not available"]
            lines += unavailable.map { "- " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func appendTail(_ lines: inout [String], attachments: [ReportAttachment], materials: [ReportMaterial],
                                   names: [String: String]) {
        if !attachments.isEmpty || !materials.isEmpty {
            lines.append(attachmentsSection(attachments, materials: materials, names: names))
            lines.append("")
        }
        lines.append("## Not checked")
        lines.append("- Claude's claims of success, passing tests or completed work: [\(notVerified)]. "
                     + "Nothing about this cloud session was observed by Prompt Relay.")
        lines.append("- CI: no source is connected [\(unavailable)]")
        lines.append("- Completion signal: none observed by Prompt Relay; the report was imported by the user [\(unavailable)]")
        lines.append("")
        lines.append("## Request for review")
        lines.append("Please review this result independently. Check whether the response actually fulfils the original "
                     + "request, point out unsupported claims, risks and missing verification, and propose the next concrete "
                     + "step or follow-up prompt for Claude Code.")
    }
}
