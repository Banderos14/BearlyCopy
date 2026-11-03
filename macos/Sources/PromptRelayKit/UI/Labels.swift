import Foundation

/// User-facing names of the actions, in one place. The two copies are named
/// for what they copy, not for one destination: the package is plain
/// Markdown for any assistant (ChatGPT, Gemini, Claude…). Stored record
/// kinds are unchanged ("reviewPack" is Copy with Context).
enum Labels {
    static let copyAnswer = "Copy Answer"
    static let copyWithContext = "Copy with Context"
    static let copied = "Copied!"

    static let copyAnswerHelp = "Copy the original answer"
    static let copyWithContextHelp = "Copy the answer with project context"

    /// Phase 7 (was "Import Saved Result"): one finished result from another
    /// AI, pasted by the user. Nothing is captured automatically through it.
    static let importAIResult = "Import AI Result"
    static let importAIResultHelp = "Import an answer from another AI"
    static let markdownSource = "Markdown Source"
    static let viewFullTask = "View Full Task"
    static let copyOriginalTask = "Copy Original Task"
    static let attachToCurrentAnswer = "Attach to Current Answer"

    /// "1,234 chars": the size of what was really put on the clipboard.
    static func chars(_ n: Int) -> String { "\(n.formatted()) chars" }

    /// Plain-language facts for Quick Peek; the exit codes stay in Details.
    static func completedCommands(_ n: Int) -> String { n == 1 ? "1 command completed" : "\(n) commands completed" }
    static func failedCommands(_ n: Int) -> String { n == 1 ? "1 failed command" : "\(n) failed commands" }
    static func filesChanged(_ n: Int) -> String { n == 1 ? "1 file changed" : "\(n) files changed" }
}
