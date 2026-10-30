import Foundation

/// User-facing wording for API values. It follows the product invariants:
/// `Stop` means "Claude stopped", never "succeeded"; an inferred link says so.
public enum Wording {
    /// A request as shown in the island (display only; every copy and the
    /// Review Pack keep it verbatim). Text pasted into Claude Code arrives
    /// wrapped in `<pasted_content id="…">` tags: they are dropped here, so
    /// the Task card and History show the words, not the wrapper.
    public static func requestForDisplay(_ text: String) -> (text: String, pasted: Bool) {
        // Blocks Claude Code injects (origin.py HARNESS_TAGS) are not shown;
        // the stored text keeps them. Phase 5.11.
        let harness = #"<(system-reminder|side-sessions-event|ci-monitor-event|task-notification)\b[^>]*>[\s\S]*?</\1>"#
        let stripped = text.replacingOccurrences(of: harness, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stripped.isEmpty ? text : stripped
        let opening = #"<pasted_content(\s[^>]*)?>"#, closing = #"</pasted_content(\s[^>]*)?>"#
        guard text.range(of: opening, options: .regularExpression) != nil else { return (text, false) }
        let cleaned = text.replacingOccurrences(of: opening, with: "", options: .regularExpression)
            .replacingOccurrences(of: closing, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? text : cleaned, true)
    }

    public static func status(_ status: TurnStatus) -> String {
        switch status {
        case .awaitingResponse: return "Waiting for Claude"
        case .noMatchedResponse: return "No response captured"
        case .stopReceived: return "Claude stopped"
        case .stopReceivedBackgroundTasksPending: return "Stopped; background work was running at the Stop"
        case .stopReceivedWithoutText: return "Stopped without text"
        case .apiError: return "API error"
        case .unknown(let raw): return "Unknown status (\(raw))"
        }
    }

    public static func link(_ link: LinkQuality) -> String? {
        switch link {
        case .promptID: return nil  // confirmed: nothing to explain
        case .sequence: return "Request inferred from order"
        case .ambiguous: return "Request unclear"
        case .none: return "No matching request"
        case .unknown(let raw): return "Link: \(raw)"
        }
    }

    public static func projectName(_ ref: ProjectRef) -> String {
        ref.name ?? ref.path.map { ($0 as NSString).lastPathComponent } ?? "Unknown project"
    }

    public static func projectName(_ project: ProjectInfo) -> String {
        project.name ?? project.path.map { ($0 as NSString).lastPathComponent } ?? "Unknown project"
    }

    /// The session's first captured request (one line), else its ID.
    public static func sessionTitle(_ session: SessionSummary) -> String {
        if let title = session.title, !title.isEmpty { return title }
        guard let id = session.sessionID else { return "Session without ID" }
        return "Session " + String(id.prefix(8))
    }

    /// "2 min ago · 3 answers · captured from 14:02"
    public static func sessionMeta(_ session: SessionSummary) -> String {
        var parts = ["this Mac", relative(session.lastEventAt)]
        let answers = session.answeredCount ?? session.turnCount
        parts.append(answers == 1 ? "1 answer" : "\(answers) answers")
        return parts.joined(separator: " · ")
    }

    /// Local time of day, "14:03:20".
    public static func clock(_ iso: String?) -> String {
        guard let date = date(iso) ?? iso.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    public static func duration(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms) ms"
    }

    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return parser.date(from: iso)
    }

    public static func relative(_ iso: String?, now: Date = Date()) -> String {
        guard let date = date(iso) else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "now", "4m", "2h", "3d": for tight spaces such as the notch.
    public static func short(_ iso: String?, now: Date = Date()) -> String {
        guard let date = date(iso) else { return "—" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    public static func absolute(_ iso: String?) -> String {
        guard let date = date(iso) else { return "—" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    public static func size(_ ref: TextRef) -> String {
        let chars = ref.charCount.formatted()
        return ref.charCount == 1 ? "1 character" : "\(chars) characters"
    }
}
