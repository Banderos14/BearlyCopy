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
        let parts = segments(command)
        guard var words = parts.last?.split(separator: " ").map(String.init) else { return nil }
        while let first = words.first, first.contains("=") || ["sudo", "time", "env", "command", "exec"].contains(first) {
            words.removeFirst()
        }
        return words.first.map { ($0 as NSString).lastPathComponent }
    }

    /// Phase 15: the parts of a line split at `|`, `;` and `&`, without
    /// cutting quoted text (`grep -E "a|b"`) or redirections (`2>&1`, `&>`)
    /// into fake parts — before, `swift build 2>&1` ended in a part "1" and
    /// `grep -E "error|warning" f` in a part `warning" f`.
    static func segments(_ command: String) -> [String] {
        var line = command.replacingOccurrences(of: #""(?:[^"\\]|\\.)*"|'[^']*'"#, with: "Q", options: .regularExpression)
        line = line.replacingOccurrences(of: #"[0-9]*>&[0-9-]+|&>>?|>&"#, with: " ", options: .regularExpression)
        return line.components(separatedBy: CharacterSet(charactersIn: "|;&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Phase 15.1: a line's stages and the operators between them, with
    /// setup stages (`cd`, `set`, `export`, bare assignments) left out and
    /// `set -o pipefail` noted. Same quoting/redirection rules as `segments`.
    struct ParsedLine: Equatable { var stages: [String]; var operators: [String]; var pipefail: Bool }

    static func parse(_ command: String) -> ParsedLine {
        var line = command.replacingOccurrences(of: #""(?:[^"\\]|\\.)*"|'[^']*'"#, with: "Q", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\|&"#, with: "|", options: .regularExpression)
        line = line.replacingOccurrences(of: #"[0-9]*>&[0-9-]+|&>>?|>&"#, with: " ", options: .regularExpression)
        let pipefail = line.range(of: #"(^|[;&|]\s*)set\s+[^;&|]*pipefail"#, options: .regularExpression) != nil
        var parts: [(text: String, op: String?)] = []
        var rest = Substring(line)
        let opRegex = try! NSRegularExpression(pattern: #"\|\||&&|\||;|&"#)
        while true {
            let ns = String(rest)
            guard let m = opRegex.firstMatch(in: ns, range: NSRange(ns.startIndex..., in: ns)),
                  let r = Range(m.range, in: ns) else { parts.append((ns, nil)); break }
            parts.append((String(ns[..<r.lowerBound]), String(ns[r])))
            rest = Substring(ns[r.upperBound...])
        }
        func isSetup(_ t: String) -> Bool {
            let words = t.split(separator: " ").map(String.init)
            guard let first = words.first else { return true }
            if ["cd", "set", "export", "pushd", "popd", "source", "."].contains(first) { return true }
            return words.allSatisfy { $0.contains("=") }
        }
        var stages: [String] = [], operators: [String] = []
        for (i, part) in parts.enumerated() {
            let text = part.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isSetup(text) else { continue }
            if !stages.isEmpty, let op = parts[i - 1].op { operators.append(op) }
            stages.append(text)
        }
        // A trailing `&` (background) is an operator too.
        if let last = parts.last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }), last.op == "&" { operators.append("&") }
        return ParsedLine(stages: stages, operators: operators, pipefail: pipefail)
    }

    static func likelyNotAnError(_ c: ObservedCommand) -> Bool {
        guard c.exitCode == 1, let command = c.command, let program = program(command) else { return false }
        return ["grep", "egrep", "fgrep", "rg", "ag", "diff", "cmp", "test", "[", "pgrep", "which"].contains(program)
    }

    static func meaning(_ c: ObservedCommand) -> String {
        if c.outcome == "interrupted" { return "Interrupted before it finished; there is no exit code." }
        guard let code = c.exitCode else { return "Reported as failed, but the hook did not include an exit code." }
        // Phase 15.1: never call a test/build failed when the exit code
        // cannot be attributed to it (same rule as FailureBreakdown).
        if FailureBreakdown.stageResult(c) == .unclear, let kind = c.kind {
            let noun = kind == "test" ? "the tests themselves passed" : "the build itself succeeded"
            guard let command = c.command else {
                return "The line exited \(code). Its text is withheld and it contains a pipe, `;` or `&`, so whether \(noun) is not known."
            }
            let last = program(command).map { " (`\($0)`)" } ?? ""
            return "The line exited \(code), but that exit code may belong to another step\(last). Whether \(noun) is not known."
        }
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

/// Phase 14.2: "1 failed" told the user a diagnostic `grep`/`plutil` call
/// and a failed test suite apart only by reading the small print. These four
/// outcomes are not interchangeable, and the UI never collapses them into
/// one: a command failing is not a test failing, which is not a build
/// failing, which is not knowing whether the task succeeded.
public struct FailureBreakdown: Equatable, Sendable {
    /// Failed commands whose `kind` is neither "test" nor "build" (a
    /// diagnostic shell command, a lint, "other", or no kind recorded).
    public var commandsFailed = 0
    public var testsFailed = 0
    public var buildsFailed = 0
    /// Phase 15: non-zero exits that look like a normal non-match or a false
    /// condition (`FailureInspector.likelyNotAnError`: grep without a match,
    /// diff with differences, `test` false) of a command that is neither a
    /// test nor a build. Counted here *instead of* `commandsFailed`, and
    /// still named in the summary — never hidden, never called a failure.
    public var likelyNotAnError = 0
    /// Phase 15: a test or build line whose exit code belongs to a later
    /// program in the same line (`swift build 2>&1 | grep error`, `swift
    /// build && grep -c x f`): the test's or build's own result was not
    /// recorded, so it is neither a failure nor a success.
    public var testsUnclear = 0
    public var buildsUnclear = 0

    /// Every non-zero exit, of any kind (what was observed, unchanged).
    public var total: Int { commandsFailed + testsFailed + buildsFailed + likelyNotAnError + testsUnclear + buildsUnclear }
    public var isEmpty: Bool { total == 0 }

    /// When only the aggregate counts are known (no per-command detail
    /// loaded yet), the failures cannot be classified by kind — they are
    /// counted as generic commands, never guessed to be tests or builds.
    public static func fromAggregate(_ nonzero: Int) -> FailureBreakdown {
        var b = FailureBreakdown(); b.commandsFailed = nonzero; return b
    }

    public static func make(_ commands: [ObservedCommand]) -> FailureBreakdown {
        var b = FailureBreakdown()
        for c in commands where FailureInspector.isFailure(c) {
            switch (c.kind, stageResult(c)) {
            case ("test", .failed?): b.testsFailed += 1
            case ("test", _): b.testsUnclear += 1
            case ("build", .failed?): b.buildsFailed += 1
            case ("build", _): b.buildsUnclear += 1
            default:
                if FailureInspector.likelyNotAnError(c) { b.likelyNotAnError += 1 } else { b.commandsFailed += 1 }
            }
        }
        return b
    }

    /// "1 test failed", "1 build failed · 1 command failed" — each kind
    /// named on its own, in this fixed order; never a single "N failed".
    /// Definite failures first, then what is unclear, then exits that are
    /// likely not errors.
    public var summary: String {
        func n(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        var parts: [String] = []
        if buildsFailed > 0 { parts.append(n(buildsFailed, "build") + " failed") }
        if testsFailed > 0 { parts.append(n(testsFailed, "test") + " failed") }
        if commandsFailed > 0 { parts.append(n(commandsFailed, "command") + " failed") }
        if buildsUnclear > 0 { parts.append(n(buildsUnclear, "build") + " unclear") }
        if testsUnclear > 0 { parts.append(n(testsUnclear, "test") + " unclear") }
        if likelyNotAnError > 0 { parts.append("\(likelyNotAnError) likely not an error") }
        return parts.joined(separator: " · ")
    }

    /// Phase 15.1: what one recorded test or build line says about the test
    /// or build itself — the one rule every view uses (Failure Inspector,
    /// Evidence Check, the Answer chip, Quick Peek, Copy with Context's
    /// Commands row). `nil` for other kinds, background starts and lines
    /// without an exit code.
    public enum StageResult: Equatable, Sendable { case passed, failed, unclear }

    /// The Core labels a line by its *first* test/build part
    /// (`tools.command_kind`); the shell reports one exit code for the whole
    /// line. Conservative by design — not a shell parser:
    /// - one stage (after `cd`/`set`/`export` setup): its own exit code;
    /// - every stage the same kind (`swift test --filter A && swift test …`):
    ///   the exit code is one of them, so it is theirs;
    /// - an `&&` chain that exited 0: every step ran and exited 0 → passed;
    ///   non-zero: which step failed is not recorded → unclear;
    /// - a pipe under `set -o pipefail` that exited 0: every stage exited 0
    ///   → passed; non-zero: which stage failed is not recorded → unclear;
    /// - otherwise (`|` without pipefail, `;`): the exit code is the last
    ///   stage's — the test's/build's only when that stage is one;
    /// - `||`, `&`, mixed operators: unclear;
    /// - withheld command text: the recorded `compound` flag decides — a
    ///   compound line is unclear, a simple one keeps its exit code.
    public static func stageResult(_ c: ObservedCommand) -> StageResult? {
        guard ["test", "build"].contains(c.kind ?? ""), !c.background else { return nil }
        let code: Int
        if let exit = c.exitCode { code = exit } else if c.outcome == "interrupted" || c.outcome == "failed" { return .unclear } else { return nil }
        let verdict: StageResult = code == 0 ? .passed : .failed
        guard let kind = c.kind else { return nil }
        guard let command = c.command else { return c.compound ? .unclear : verdict }
        let line = FailureInspector.parse(command)
        let stages = line.stages
        if line.operators.contains("&") || line.operators.contains("||") { return .unclear }
        if stages.count <= 1 { return verdict }
        if stages.allSatisfy({ commandKind($0) == kind }) { return verdict }
        let ops = Set(line.operators)
        if ops == ["&&"] { return code == 0 ? .passed : .unclear }
        if ops == ["|"], line.pipefail { return code == 0 ? .passed : .unclear }
        if ops.isSubset(of: ["|", ";"]), let last = stages.last, commandKind(last) == kind {
            return line.pipefail && ops.contains("|") ? (code == 0 ? .passed : .unclear) : verdict
        }
        return .unclear
    }

    /// The Core's prefix table (`plugin/prompt_relay/tools.py`,
    /// `KIND_PREFIXES`), applied to one part of a line. Keep the two in step.
    static let kindPrefixes: [(kind: String, prefixes: [String])] = [
        ("test", ["pytest", "python -m pytest", "python3 -m pytest", "python -m unittest", "python3 -m unittest",
                  "swift test", "xcodebuild test", "npm test", "npm run test", "pnpm test", "pnpm run test",
                  "yarn test", "go test", "cargo test", "scripts/check.sh", "./scripts/check.sh", "make test"]),
        ("build", ["swift build", "xcodebuild", "npm run build", "pnpm build", "pnpm run build", "yarn build",
                   "cargo build", "go build", "make", "scripts/build", "./scripts/build"]),
        ("git", ["git"]),
    ]

    static func commandKind(_ part: String) -> String {
        var words = part.split(separator: " ").map(String.init)
        while let first = words.first, first.contains("="), first.first != "=" { words.removeFirst() }
        let stripped = words.joined(separator: " ")
        for (kind, prefixes) in kindPrefixes {
            for prefix in prefixes where stripped == prefix || stripped.hasPrefix(prefix + " ") { return kind }
        }
        return "other"
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
