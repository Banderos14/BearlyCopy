import Foundation

/// The Review Pack: Markdown for an independent review in another chat.
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

    public static func render(imported report: ImportedReport, attachments: [ReportAttachment], exportedAt: String) -> String {
        var lines: [String] = []
        func add(_ s: String = "") { lines.append(s) }
        add("# Review Pack: Claude Code result for independent review (exported by Prompt Relay)")
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
        add("- Exported at: \(exportedAt)")
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
        add("## Git state")
        add("- [\(unavailable)] Not collected: the work happened in a cloud session, not in a folder on this Mac.")
        add()
        appendTail(&lines, attachments: attachments)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Core's pack for a local report, with the attachments the user
    /// chose listed at the end (by name only, never a local path).
    /// The section goes before "Tests and CI", like in an import's pack. The
    /// last such heading is the Core's own: the response, which may contain
    /// any heading, comes earlier. Without it the section is appended.
    public static func render(local coreText: String, attachments: [ReportAttachment]) -> String {
        guard !attachments.isEmpty else { return coreText }
        let section = attachmentsSection(attachments) + "\n\n"
        if let anchor = coreText.range(of: "\n## Tests and CI\n", options: .backwards) {
            var text = coreText
            text.insert(contentsOf: section, at: text.index(after: anchor.lowerBound))
            return text
        }
        return coreText + "\n" + section
    }

    static func attachmentsSection(_ attachments: [ReportAttachment]) -> String {
        var lines = ["## Attachments (\(attachments.count), sent separately)",
                     "[\(userSupplied)] Images the user added to this report in Prompt Relay. They are not part of this text; "
                     + "if they are not attached to this message, they were not shared."]
        for a in attachments {
            lines.append("- \(a.originalFilename) — \(a.mimeType), \(ByteCountFormatter.string(fromByteCount: Int64(a.byteCount), countStyle: .file))")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendTail(_ lines: inout [String], attachments: [ReportAttachment]) {
        if !attachments.isEmpty {
            lines.append(attachmentsSection(attachments))
            lines.append("")
        }
        lines.append("## Tests and CI")
        lines.append("- [\(notVerified)] Prompt Relay has no independent source of test or CI results. "
                     + "Any statement about tests, builds or CI in Claude's response is reported by Claude only.")
        lines.append("")
        lines.append("## Verification status")
        lines.append("- Claude's claims of success, passing tests or completed work: [\(notVerified)]")
        lines.append("- Completion signal: none observed by Prompt Relay; the report was imported by the user [\(unavailable)]")
        lines.append("")
        lines.append("## Request for review")
        lines.append("Please review this result independently. Check whether the response actually fulfils the original "
                     + "request, point out unsupported claims, risks and missing verification, and propose the next concrete "
                     + "step or follow-up prompt for Claude Code.")
    }
}
