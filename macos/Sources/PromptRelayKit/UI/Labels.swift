import Foundation

/// User-facing names of the actions, in one place. The two copies are named
/// for what they copy, not for one destination: the package is plain
/// Markdown for any assistant (ChatGPT, Gemini, Claude…). Stored record
/// kinds are unchanged ("reviewPack" is Copy with Context).
enum Labels {
    static let copyAnswer = "Copy Answer"
    static let copyWithContext = "Copy with Context"
    static let copied = "Copied!"

    static let copyAnswerHelp = "Copy Answer: only Claude's answer, exactly as written (⇧⌘C)"
    static let copyWithContextHelp = "Copy with Context: Claude's full answer plus your request, the commands Prompt Relay saw, "
        + "changed files, Git status and the chosen attachments, as Markdown for another assistant (⌥⌘C)"

    static let importSavedResult = "Import Saved Result"
    static let importSavedResultHelp = "Paste one result saved elsewhere (for example a Claude Code cloud session), "
        + "where Prompt Relay could not capture it. One answer, not a whole conversation."
    static let attachToCurrentAnswer = "Attach to Current Answer"

    /// "1,234 chars": the size of what was really put on the clipboard.
    static func chars(_ n: Int) -> String { "\(n.formatted()) chars" }

    /// Plain-language facts for Quick Peek; the exit codes stay in Details.
    static func completedCommands(_ n: Int) -> String { n == 1 ? "1 command completed" : "\(n) commands completed" }
    static func failedCommands(_ n: Int) -> String { n == 1 ? "1 failed command" : "\(n) failed commands" }
    static func filesChanged(_ n: Int) -> String { n == 1 ? "1 file changed" : "\(n) files changed" }
}
