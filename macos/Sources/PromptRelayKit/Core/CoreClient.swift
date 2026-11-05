import Foundation

/// Everything that can go wrong between the app and the Core, in words the
/// UI can show. Messages never contain captured text.
public enum CoreError: Error, Equatable, Sendable {
    /// The CLI was not found (app bundle incomplete, or override path wrong).
    case cliMissing(searched: [String])
    /// No Python 3.9+ was found.
    case pythonMissing(searched: [String])
    /// The process could not start or did not finish.
    case launchFailed(String)
    case timedOut(seconds: Int)
    case outputTooLarge
    /// stdout was not a JSON API document (for example a Python traceback).
    case malformedOutput(exitCode: Int32)
    /// The document's `api_version` is not one this app understands.
    case unsupportedAPIVersion(Int)
    /// A well-formed API error document (`ok: false`).
    case api(code: String, message: String)

    public var title: String {
        switch self {
        case .cliMissing: return "Prompt Relay Core not found"
        case .pythonMissing: return "Python 3.9 or newer is needed"
        case .launchFailed: return "Could not start the Prompt Relay Core"
        case .timedOut: return "The Prompt Relay Core did not answer in time"
        case .outputTooLarge: return "The answer is too large to load"
        case .malformedOutput: return "The Prompt Relay Core returned an unreadable answer"
        case .unsupportedAPIVersion: return "This app is too old for the installed Core"
        case .api(let code, _):
            switch code {
            case "not_found": return "Nothing found"
            case "no_final_response": return "No final response"
            case "storage_error", "unsafe_path": return "History cannot be read"
            case "config_error": return "Prompt Relay settings are damaged"
            default: return "Prompt Relay reported an error"
            }
        }
    }

    public var detail: String {
        switch self {
        case .cliMissing(let searched):
            return "Looked for: " + (searched.isEmpty ? "(no locations)" : searched.joined(separator: ", "))
        case .pythonMissing:
            return "Install the Xcode Command Line Tools (xcode-select --install) or Python from Homebrew or python.org, then refresh."
        case .launchFailed(let reason): return reason
        case .timedOut(let seconds): return "No answer after \(seconds) s. Try Refresh."
        case .outputTooLarge: return "The Core's output exceeded the app's limit."
        case .malformedOutput(let code): return "Exit code \(code). Open Status for diagnostics."
        case .unsupportedAPIVersion(let v): return "The Core speaks JSON API version \(v); this app knows version \(supportedAPIVersion)."
        case .api(_, let message): return message
        }
    }

    public var apiCode: String? {
        if case .api(let code, _) = self { return code }
        return nil
    }
}

/// A decoded successful result plus its warnings.
public struct CoreResult<Payload: Sendable>: Sendable {
    public let data: Payload
    public let warnings: [APIWarning]
}

/// What the presentation layer needs from the Core. The live implementation
/// runs `prompt-relay … --json`; tests substitute fakes.
public protocol CoreProviding: Sendable {
    func projects() async throws -> CoreResult<ProjectsData>
    func sessions(project: String?) async throws -> CoreResult<SessionsData>
    func turns(sessionKey: String) async throws -> CoreResult<TurnsData>
    func show(sessionKey: String, turn: Int) async throws -> CoreResult<ShowData>
    func context(sessionKey: String, turn: Int) async throws -> CoreResult<ContextData>
    /// Copy with Context at a detail level (Phase 7); Full is `context` as before.
    func context(sessionKey: String, turn: Int, detail: ContextDetail) async throws -> CoreResult<ContextData>
    func doctor() async throws -> CoreResult<DoctorData>
    /// Phase 12: final results of every session, newest first (`results`).
    func results(limit: Int) async throws -> CoreResult<ResultsData>
    /// `prompt-relay enable|disable <dir>` (text commands): returns the Core's
    /// one-line confirmation. The folder's contents are never read.
    func setCapture(_ enabled: Bool, path: String) async throws -> String
}

extension CoreProviding {
    /// Doubles (and Previews) without a `results` command: the same list,
    /// built from `sessions` and `turns` — final answers only, newest first.
    public func results(limit: Int) async throws -> CoreResult<ResultsData> {
        try await synthesizedResults(limit: limit)
    }

    public func synthesizedResults(limit: Int) async throws -> CoreResult<ResultsData> {
        var rows: [ResultSummary] = []
        for session in try await sessions(project: nil).data.sessions {
            guard let turns = try? await turns(sessionKey: session.sessionKey).data.turns else { continue }
            for t in turns where t.finalResponse != nil {
                switch t.completion {
                case .answer, .answerBackgroundRunning, .waitingBackground: rows.append(ResultSummary(session: session, turn: t))
                default: continue
                }
            }
        }
        rows.sort { a, b in
            if (a.answeredAt ?? "") != (b.answeredAt ?? "") { return (a.answeredAt ?? "") > (b.answeredAt ?? "") }
            return (a.sessionKey, a.turn) < (b.sessionKey, b.turn)
        }
        return CoreResult(data: ResultsData(total: rows.count, limit: limit, results: Array(rows.prefix(limit))), warnings: [])
    }

    /// Doubles without detail levels build the Full package.
    public func context(sessionKey: String, turn: Int, detail: ContextDetail) async throws -> CoreResult<ContextData> {
        try await context(sessionKey: sessionKey, turn: turn)
    }
}

/// Adapter over the CLI JSON API v1. It never reads the JSONL store and never
/// re-implements correlation; it only runs the CLI and decodes its answer.
public struct CoreClient: CoreProviding {
    public let runner: CommandRunning
    public let resolve: @Sendable () throws -> CoreLocation
    public let timeout: TimeInterval

    public init(runner: CommandRunning = ProcessRunner(), timeout: TimeInterval = 30,
                resolve: @escaping @Sendable () throws -> CoreLocation) {
        self.runner = runner
        self.resolve = resolve
        self.timeout = timeout
    }

    public static func live(locator: CoreLocator = CoreLocator()) -> CoreClient {
        CoreClient { try locator.locate() }
    }

    public func projects() async throws -> CoreResult<ProjectsData> {
        try await call(["projects"])
    }

    public func sessions(project: String?) async throws -> CoreResult<SessionsData> {
        var args = ["sessions"]
        if let project { args += ["--project", project] }
        return try await call(args)
    }

    public func turns(sessionKey: String) async throws -> CoreResult<TurnsData> {
        try await call(["turns", "--session", sessionKey])
    }

    /// Phase 12. A Core older than 0.3 + Phase 12 answers `usage_error`
    /// (unknown command); the app then builds the list itself.
    public func results(limit: Int) async throws -> CoreResult<ResultsData> {
        do {
            return try await call(["results", "--limit", String(limit)])
        } catch CoreError.api(let code, _) where code == "usage_error" {
            return try await synthesizedResults(limit: limit)
        }
    }

    public func show(sessionKey: String, turn: Int) async throws -> CoreResult<ShowData> {
        try await call(["show", "--session", sessionKey, "--turn", String(turn)])
    }

    public func context(sessionKey: String, turn: Int) async throws -> CoreResult<ContextData> {
        try await call(["context", "--session", sessionKey, "--turn", String(turn)])
    }

    public func context(sessionKey: String, turn: Int, detail: ContextDetail) async throws -> CoreResult<ContextData> {
        try await call(["context", "--session", sessionKey, "--turn", String(turn), "--detail", detail.rawValue])
    }

    public func doctor() async throws -> CoreResult<DoctorData> {
        try await call(["doctor", "--no-project"])
    }

    public func setCapture(_ enabled: Bool, path: String) async throws -> String {
        let output = try await run([enabled ? "enable" : "disable", path])
        let say = { (data: Data) in
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map { $0.replacingOccurrences(of: "prompt-relay: ", with: "") }
                .first { !$0.hasPrefix("warning:") && !$0.isEmpty } ?? ""
        }
        guard output.exitCode == 0 else {
            let reason = say(output.stderr)
            throw CoreError.api(code: "capture_change_failed",
                                message: reason.isEmpty ? "exit code \(output.exitCode)" : reason)
        }
        return say(output.stdout)
    }

    func call<P: Decodable & Sendable>(_ args: [String]) async throws -> CoreResult<P> {
        try Self.decode(try await run(args + ["--json"]))
    }

    /// Runs the CLI with the isolated interpreter and a minimal environment.
    func run(_ args: [String]) async throws -> CommandOutput {
        let location: CoreLocation
        do {
            location = try resolve()
        } catch let error as LocatorError {
            switch error {
            case .cliNotFound(let searched): throw CoreError.cliMissing(searched: searched)
            case .pythonNotFound(let searched): throw CoreError.pythonMissing(searched: searched)
            }
        }
        // -I -S: the interpreter ignores PYTHON* variables and user site
        // packages, as the plugin launcher does. -B: no __pycache__ inside the
        // signed app bundle. A minimal environment keeps the user's shell
        // settings out of the Core.
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        env.merge(location.environment) { _, new in new }
        do {
            return try await runner.run(executable: location.python,
                                        arguments: ["-I", "-S", "-B", location.cli] + args,
                                        environment: env, timeout: timeout)
        } catch let error as RunnerError {
            switch error {
            case .launchFailed(let reason): throw CoreError.launchFailed(reason)
            case .timedOut(let s): throw CoreError.timedOut(seconds: s)
            case .outputTooLarge: throw CoreError.outputTooLarge
            }
        }
    }

    /// Envelope checks in the order JSON_API.md prescribes: parse, version,
    /// then `ok`/`error`, then the payload.
    public static func decode<P: Decodable & Sendable>(_ output: CommandOutput) throws -> CoreResult<P> {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: output.stdout) else {
            throw CoreError.malformedOutput(exitCode: output.exitCode)
        }
        guard probe.apiVersion == supportedAPIVersion else {
            throw CoreError.unsupportedAPIVersion(probe.apiVersion)
        }
        let header: Envelope<IgnoredPayload>
        do {
            header = try decoder.decode(Envelope<IgnoredPayload>.self, from: output.stdout)
        } catch {
            throw CoreError.malformedOutput(exitCode: output.exitCode)
        }
        if !header.ok || output.exitCode != 0 {
            let info = header.error ?? APIErrorInfo(code: "internal_error", message: "exit code \(output.exitCode)")
            throw CoreError.api(code: info.code, message: info.message)
        }
        do {
            let full = try decoder.decode(Envelope<P>.self, from: output.stdout)
            guard let data = full.data else { throw CoreError.malformedOutput(exitCode: output.exitCode) }
            return CoreResult(data: data, warnings: full.warnings)
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.malformedOutput(exitCode: output.exitCode)
        }
    }
}

/// Decodes any `data` without interpreting it.
struct IgnoredPayload: Decodable {
    init(from decoder: Decoder) throws {}
}
