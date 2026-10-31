import Foundation

/// Failure Inspector (Phase 8): what Prompt Relay really saw of each command
/// that did not exit 0, read only from the stored hook facts. It never runs
/// a command, never calls a failure fixed and never fills in what the hook
/// did not record: what is missing is listed as missing.
public struct FailureInspector: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let command: ObservedCommand
        /// What this exit code usually means for this kind of command.
        public let meaning: String
        /// Why the exit code may not describe the whole line.
        public let caveats: [String]
        /// A later run of the same command (or the same test/build tool).
        public let later: Later?
        /// What the hook did not record for this command.
        public let unavailable: [String]
        public var id: String { command.at + (command.command ?? command.commandWithheld ?? "") }
        /// grep without a match, diff with differences, `test` false: a
        /// non-zero exit that usually is an answer, not an error.
        public let likelyNotAnError: Bool
    }

    public struct Later: Equatable, Sendable {
        public enum Match: String, Sendable { case sameCommand = "same command", sameTool = "same tool" }
        public let command: ObservedCommand
        public let match: Match
        public var passed: Bool { command.exitCode == 0 && command.outcome == "ok" }
    }

    public let entries: [Entry]

    public init(commands: [ObservedCommand]) {
        let ordered = commands.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        entries = ordered.enumerated().compactMap { i, c in
            guard Self.isFailure(c) else { return nil }
            let rest = Array(ordered[(i + 1)...])
            return Entry(command: c, meaning: Self.meaning(c), caveats: Self.caveats(c), later: Self.later(after: c, in: rest),
                         unavailable: Self.unavailable(c), likelyNotAnError: Self.likelyNotAnError(c))
        }
    }

    /// Exited non-zero, failed without an exit code, or was interrupted.
    /// Background starts are not failures: their end is not observed.
    public static func isFailure(_ c: ObservedCommand) -> Bool {
        guard !c.background else { return false }
        if let code = c.exitCode { return code != 0 }
        return c.outcome == "failed" || c.outcome == "interrupted"
    }

    /// The program that decides the exit code: the last part of a pipe or
    /// chain, without `cd …`, env assignments and `sudo`/`time`/`env`.
    static func program(_ command: String) -> String? {
        let parts = command.components(separatedBy: CharacterSet(charactersIn: "|;&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var words = parts.last?.split(separator: " ").map(String.init) else { return nil }
        while let first = words.first, first.contains("=") || ["sudo", "time", "env", "command", "exec"].contains(first) {
            words.removeFirst()
        }
        return words.first.map { ($0 as NSString).lastPathComponent }
    }

    static func likelyNotAnError(_ c: ObservedCommand) -> Bool {
        guard c.exitCode == 1, let command = c.command, let program = program(command) else { return false }
        return ["grep", "egrep", "fgrep", "rg", "ag", "diff", "cmp", "test", "[", "pgrep", "which"].contains(program)
    }

    static func meaning(_ c: ObservedCommand) -> String {
        if c.outcome == "interrupted" { return "Interrupted before it finished; there is no exit code." }
        guard let code = c.exitCode else { return "Reported as failed, but the hook did not include an exit code." }
        if likelyNotAnError(c), let program = c.command.flatMap(program) {
            switch program {
            case "grep", "egrep", "fgrep", "rg", "ag", "pgrep": return "\(program) exits 1 when nothing matched. That is usually an answer, not an error."
            case "diff", "cmp": return "\(program) exits 1 when the inputs differ. That is usually an answer, not an error."
            case "which": return "which exits 1 when the program is not installed."
            default: return "The condition was false (exit 1)."
            }
        }
        switch code {
        case 127: return "Exit 127: the shell did not find the command."
        case 126: return "Exit 126: the command was found but could not be run."
        case 130: return "Exit 130: stopped with Ctrl-C (SIGINT)."
        case 137: return "Exit 137: killed (SIGKILL), for example by a timeout or low memory."
        case 143: return "Exit 143: terminated (SIGTERM)."
        default: break
        }
        switch c.kind {
        case "test": return "The test command exited \(code): tests failed or could not run. The hook does not say which tests."
        case "build": return "The build command exited \(code): the build did not succeed."
        case "git": return "The git command exited \(code)."
        default: return "The command exited \(code)."
        }
    }

    static func caveats(_ c: ObservedCommand) -> [String] {
        var out: [String] = []
        if c.compound {
            out.append("Pipe, `;`, `||` or `&` in the line: the exit code is the last process's, not necessarily the whole line's.")
        } else if c.command?.contains("&&") == true {
            out.append("A chain with `&&`: the first failing step stopped it; which step failed is not recorded.")
        }
        if c.afterStop { out.append("Finished after Claude had stopped answering.") }
        if let agent = c.agentType { out.append("Run by a subagent (\(agent)).") }
        return out
    }

    static func unavailable(_ c: ObservedCommand) -> [String] {
        var out: [String] = []
        if c.command == nil { out.append("Command text: withheld (\(Wording.withheld(c.commandWithheld))).") }
        if let why = c.tailWithheld {
            out.append("Output: withheld (\(Wording.withheld(why))).")
        } else if c.outputTail == nil {
            out.append(["test", "build"].contains(c.kind ?? "")
                       ? "Output: none was recorded for this run."
                       : "Output: not recorded; it is kept only for failed tests and builds.")
        } else {
            out.append("Output: only its last lines were kept (at most 12 lines, 2 KB).")
        }
        if c.durationMs == nil { out.append("Duration: not reported.") }
        return out
    }

    /// A later run that can reasonably be called a re-check: the exact same
    /// command, or (for tests and builds) the same tool. The first such run.
    static func later(after c: ObservedCommand, in rest: [ObservedCommand]) -> Later? {
        let candidates = rest.filter { !$0.background && $0.agentType == c.agentType }
        if let command = c.command, let same = candidates.first(where: { $0.command == command }) {
            return Later(command: same, match: .sameCommand)
        }
        guard ["test", "build"].contains(c.kind ?? ""), let tool = c.command.flatMap(Self.tool) else { return nil }
        return candidates.first { $0.kind == c.kind && $0.command.flatMap(Self.tool) == tool }.map { Later(command: $0, match: .sameTool) }
    }

    /// "swift build", "xcodebuild", "pytest": the first two words of the
    /// part of the line that is a test or build, enough to tell tools apart.
    static func tool(_ command: String) -> String? {
        let parts = command.components(separatedBy: CharacterSet(charactersIn: "|;&")).map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts where !part.isEmpty && !part.hasPrefix("cd ") {
            let words = part.split(separator: " ").map(String.init).filter { !$0.contains("=") }
            guard let first = words.first else { continue }
            let second = words.dropFirst().first.map { $0.hasPrefix("-") ? "" : " " + $0 } ?? ""
            return first + second
        }
        return nil
    }
}

extension Wording {
    /// The Core's reason for withholding text, in words.
    static func withheld(_ reason: String?) -> String {
        switch reason {
        case "possible_secret": return "it may contain a secret"
        case "too_long": return "longer than 1 KB"
        case let r?: return r.replacingOccurrences(of: "_", with: " ")
        case nil: return "reason not recorded"
        }
    }
}
