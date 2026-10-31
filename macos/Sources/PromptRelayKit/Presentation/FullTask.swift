import Foundation

/// The request of the selected answer, as View Full Task shows it: the
/// stored text exactly (Markdown Source, Copy Original Task), the same text
/// without the blocks Claude Code adds (Formatted), and plain facts about
/// where it came from and whether it is whole. Built only from what is
/// already stored or loaded; nothing is summarized, shortened or guessed.
public struct FullTask: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// Captured by the UserPromptSubmit hook and linked by `prompt_id`.
        case linked
        /// Captured by the hook, linked to the answer by order only.
        case inferred
        /// Entered by the user when importing a result.
        case imported
        /// Claude Code started the turn itself: not the user's request.
        case automated
        /// Automated blocks mixed with other text: who wrote it is not known.
        case unknownSource
    }

    public let origin: Origin
    /// The stored text, verbatim; nil when no request is at hand.
    public let original: String?
    /// For Formatted: `original` without harness blocks and paste wrappers.
    public let display: String?
    /// False when only the Core's short preview is at hand.
    public let complete: Bool
    /// Where it came from and what is missing, in plain words.
    public let notes: [String]
    /// For an automatic turn: the user's request before it (a preview).
    public let earlierRequest: String?

    /// Copy Original Task copies only a request the user wrote or supplied.
    public var canCopy: Bool { original != nil && origin != .automated }
    public var characters: Int? { original?.unicodeScalars.count }

    /// - Parameters:
    ///   - request: the turn's request as the list returned it (`preview`).
    ///   - fullText: `request.text` from `show`, when loaded for this turn.
    public static func local(request: TextRef?, fullText: String?, requestOrigin: RequestOrigin?, link: LinkQuality,
                             earlier: EarlierRequest?) -> FullTask {
        guard let request else {
            return FullTask(origin: .inferred, original: nil, display: nil, complete: false,
                            notes: ["No request was captured for this answer (\((Wording.link(link) ?? "not captured").lowercased()))."],
                            earlierRequest: nil)
        }
        let text = fullText ?? request.text ?? request.preview
        let complete = fullText != nil || request.text != nil || !request.truncated
        var notes: [String] = []
        let origin: Origin
        switch (requestOrigin, link) {
        case (.automated?, _): origin = .automated
        case (.unknown?, _): origin = .unknownSource
        case (_, .promptID): origin = .linked
        default: origin = .inferred
        }
        switch origin {
        case .automated:
            notes.append("Claude Code started this turn itself; you did not write this message. It is shown as stored, not as your request.")
        case .unknownSource:
            notes.append("Blocks Claude Code adds are mixed with other text here: who wrote it is not established.")
        case .linked:
            notes.append("Captured on this Mac by the UserPromptSubmit hook; linked to the answer by prompt_id.")
        case .inferred:
            notes.append("Captured on this Mac by the UserPromptSubmit hook; linked to the answer by order only (\((Wording.link(link) ?? "inferred").lowercased())).")
        case .imported: break
        }
        if !complete {
            notes.append("Incomplete here: only the first \(request.preview.unicodeScalars.count.formatted()) of \(request.charCount.formatted()) characters are loaded. The full text loads with the answer; this turn has no answer to load.")
        }
        let shown = Wording.requestForDisplay(text)
        if shown.text != text, origin != .automated {
            notes.append(shown.pasted && !hasHarness(text)
                         ? "Formatted hides the paste wrapper; Markdown Source shows the stored text exactly."
                         : "Formatted hides the blocks Claude Code added (such as system reminders); Markdown Source shows the stored text exactly.")
        }
        return FullTask(origin: origin, original: text, display: origin == .automated ? nil : shown.text,
                        complete: complete, notes: notes,
                        earlierRequest: origin == .automated ? earlier.map { $0.displayPreview ?? Wording.requestForDisplay($0.preview).text } : nil)
    }

    public static func imported(task: String?) -> FullTask {
        guard let task else {
            return FullTask(origin: .imported, original: nil, display: nil, complete: false,
                            notes: ["No request was supplied when this result was imported."], earlierRequest: nil)
        }
        return FullTask(origin: .imported, original: task, display: task, complete: true,
                        notes: ["Entered by you when importing; not captured by a local hook."], earlierRequest: nil)
    }

    static func hasHarness(_ text: String) -> Bool {
        text.range(of: #"<(system-reminder|side-sessions-event|ci-monitor-event|task-notification)\b"#, options: .regularExpression) != nil
    }
}

extension AppModel {
    /// The full request of the selected turn, once `show` has loaded it.
    public var selectedRequestText: String? {
        guard let show = detail.value, show.turn.index == selectedTurnIndex,
              show.session.sessionKey == selectedSessionKey else { return nil }
        return show.turn.request?.text
    }

    /// View Full Task's document for the selected answer.
    public var fullTask: FullTask? {
        if let report = selectedImport { return .imported(task: report.task) }
        guard let turn = selectedTurn else { return nil }
        return .local(request: turn.request, fullText: selectedRequestText, requestOrigin: turn.requestOrigin, link: turn.link,
                      earlier: turn.earlierUserRequest)
    }

    static func taskToken(_ ref: ReportRef?) -> String { "task|\(ref?.key ?? "-")" }

    /// Copy Original Task: the stored request, verbatim.
    public func copyOriginalTask() {
        guard let ref = currentRef, let task = fullTask, task.canCopy, let text = task.original else { return }
        do {
            try clipboard.copy(text)
            finishCopy(.copied(.task, characters: text.unicodeScalars.count), token: Self.taskToken(ref))
        } catch {
            finishCopy(.failed(Self.message(for: error)))
        }
    }
}
