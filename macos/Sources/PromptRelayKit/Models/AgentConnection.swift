import Foundation

/// Phase 11: one honest status per agent and host for first-run setup.
///
/// "Connected" needs delivery evidence — a stored session from that agent
/// and host, or the handler log recording a stored event from it. A plugin
/// record or a hook definition alone is configuration, never connection.
/// Detection only looks at whether well-known paths exist; it never reads
/// credentials, tokens, transcripts or other tools' hook commands.
public enum ConnectionTarget: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codexCLI, codexXcode
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex · Terminal"
        case .codexXcode: return "Codex · Xcode"
        }
    }
    var provider: AgentProvider { self == .claudeCode ? .claudeCode : .codex }
    /// The host label BearlyCopy's Codex hook command carries.
    var codexHost: String? {
        switch self {
        case .claudeCode: return nil
        case .codexCLI: return "terminal"
        case .codexXcode: return "xcode"
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case notDetected
    case installed
    case configurationRequired
    case trustRequired
    case captureDisabled
    case waitingForFirstEvent
    case connected(lastEventAt: String?)
    case error(String)

    public var title: String {
        switch self {
        case .notDetected: return "Not detected"
        case .installed: return "Installed"
        case .configurationRequired: return "Configuration required"
        case .trustRequired: return "Trust required"
        case .captureDisabled: return "Capture disabled"
        case .waitingForFirstEvent: return "Waiting for first event"
        case .connected: return "Connected — events observed"
        case .error: return "Error"
        }
    }
    public var isConnected: Bool { if case .connected = self { return true } else { return false } }
    public var needsAction: Bool {
        switch self {
        case .notDetected, .connected, .installed, .waitingForFirstEvent: return false
        default: return true
        }
    }
}

/// Read-only facts gathered for the evaluation (`AgentFacts.gather`).
public struct AgentFacts: Equatable, Sendable {
    public enum PluginState: Equatable, Sendable { case unknown, missing, installed(version: String?), broken }
    public enum HookDefinitions: Equatable, Sendable { case absent, partial, defined, unreadable }

    public var claudeFootprint: Bool
    public var claudePlugin: PluginState
    /// Handler log events that arrived through the plugin launcher.
    public var claudePluginEvents: Int
    public var codexCLIFootprint: Bool
    public var codexCLIHooks: HookDefinitions
    public var codexXcodeFootprint: Bool
    public var codexXcodeHooks: HookDefinitions
    public var enabledProjects: Int
    public var coreProblem: String?
    /// Latest stored event per target (sessions the Core can read back).
    public var storedLastEvent: [ConnectionTarget: String]
    /// Handler log: per Codex host, the last outcome and when it was stored.
    public var codexObserved: [String: DoctorData.Observed.Source]

    public init(claudeFootprint: Bool = false, claudePlugin: PluginState = .unknown, claudePluginEvents: Int = 0,
                codexCLIFootprint: Bool = false, codexCLIHooks: HookDefinitions = .absent,
                codexXcodeFootprint: Bool = false, codexXcodeHooks: HookDefinitions = .absent,
                enabledProjects: Int = 0, coreProblem: String? = nil,
                storedLastEvent: [ConnectionTarget: String] = [:], codexObserved: [String: DoctorData.Observed.Source] = [:]) {
        self.claudeFootprint = claudeFootprint; self.claudePlugin = claudePlugin; self.claudePluginEvents = claudePluginEvents
        self.codexCLIFootprint = codexCLIFootprint; self.codexCLIHooks = codexCLIHooks
        self.codexXcodeFootprint = codexXcodeFootprint; self.codexXcodeHooks = codexXcodeHooks
        self.enabledProjects = enabledProjects; self.coreProblem = coreProblem
        self.storedLastEvent = storedLastEvent; self.codexObserved = codexObserved
    }

    public func state(of target: ConnectionTarget) -> ConnectionState {
        if let coreProblem { return .error(coreProblem) }
        if let at = storedLastEvent[target] { return .connected(lastEventAt: at) }
        switch target {
        case .claudeCode:
            switch claudePlugin {
            case .unknown: return claudeFootprint ? .installed : .notDetected
            case .missing: return claudeFootprint ? .configurationRequired : .notDetected
            case .broken: return .error("The BearlyCopy plugin record exists but its files are missing. Reinstall it with claude plugin install.")
            case .installed:
                if enabledProjects == 0 { return .captureDisabled }
                return .waitingForFirstEvent
            }
        case .codexCLI, .codexXcode:
            let footprint = target == .codexCLI ? codexCLIFootprint : codexXcodeFootprint
            let hooks = target == .codexCLI ? codexCLIHooks : codexXcodeHooks
            let observed = target.codexHost.flatMap { codexObserved["codex:\($0)"] }
            if !footprint && hooks == .absent && observed == nil { return .notDetected }
            switch hooks {
            case .unreadable: return .error("hooks.json is not valid JSON. Fix or restore it from its backup.")
            case .absent, .partial: return .configurationRequired
            case .defined: break
            }
            if let observed {
                if let error = observed.lastError, observed.lastErrorAt != nil, observed.lastStoredAt == nil {
                    return .error("The hook ran but its event was rejected (\(error)).")
                }
                if observed.lastOutcome == "project_not_enabled" { return .captureDisabled }
                if observed.lastStoredAt != nil { return .connected(lastEventAt: observed.lastStoredAt) }
            }
            if enabledProjects == 0 { return .captureDisabled }
            // Defined, but Codex has never run it: hooks need the user's trust
            // in Codex before they run (Codex asks in /hooks or on the next start).
            return observed == nil ? .trustRequired : .waitingForFirstEvent
        }
    }

    /// The specific problem and the safe next step, in plain words.
    public func diagnosis(of target: ConnectionTarget) -> String {
        switch state(of: target) {
        case .notDetected:
            return target == .claudeCode
                ? "No Claude Code installation found (no ~/.claude folder, no claude command, no Claude app). Install Claude Code first, or skip it."
                : target == .codexCLI
                    ? "No Codex CLI found (no ~/.codex folder). Skip it if you do not use Codex in Terminal."
                    : "No Xcode coding assistant data for Codex found. Skip it if you do not use Codex in Xcode."
        case .installed:
            return "Claude Code is installed. Checking whether the BearlyCopy plugin is installed…"
        case .configurationRequired:
            return target == .claudeCode
                ? "The BearlyCopy plugin is not installed in Claude Code. Copy the two commands below and run them in Terminal; Claude Code shows what it installs."
                : "BearlyCopy's hooks are not in \(target == .codexCLI ? "~/.codex/hooks.json" : "Xcode's Codex hooks.json"). Preview the change with the command below, then apply it; your other hooks are kept and a backup is written."
        case .trustRequired:
            return "The hooks are defined, but Codex has not run them yet. Codex runs new hooks only after you trust them: open Codex, review BearlyCopy's hooks in /hooks (or accept the prompt on the next start)."
        case .captureDisabled:
            return "Capture is off for every project. Enable the project you work in (step 3); BearlyCopy ignores everything else."
        case .waitingForFirstEvent:
            return "Set up. Send any prompt to \(target.provider.title) in an enabled project; the status turns Connected when its first event is stored."
        case .connected(let at):
            return "Events from \(target.title) are stored" + (at.map { " — last at \($0)" } ?? "") + "."
        case .error(let message):
            return message
        }
    }
}

extension AgentFacts {
    /// Read-only gathering. Existence checks only; the Codex hook files are
    /// parsed just to count BearlyCopy's own commands (as before).
    @MainActor
    static func gather(model: AppModel, fileManager: FileManager = .default,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentFacts {
        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: path) }
        let claudeCommands = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                              home.appendingPathComponent(".claude/local/claude").path,
                              home.appendingPathComponent(".local/bin/claude").path]
        let claudeFootprint = exists(home.appendingPathComponent(".claude").path)
            || claudeCommands.contains(where: exists)
            || exists("/Applications/Claude.app") || exists(home.appendingPathComponent("Applications/Claude.app").path)
        var facts = AgentFacts(claudeFootprint: claudeFootprint)
        facts.codexCLIFootprint = exists(home.appendingPathComponent(".codex").path)
            || ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].contains(where: exists)
        facts.codexXcodeFootprint = exists(home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/codex").path)
        facts.codexCLIHooks = .init(CodexHookConfiguration.inspect(at: home.appendingPathComponent(".codex/hooks.json"), host: "terminal").state)
        facts.codexXcodeHooks = .init(CodexHookConfiguration.inspect(
            at: home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/codex/hooks.json"), host: "xcode").state)
        if let doctor = model.doctor.value {
            if let record = doctor.configuration.plugin.records.first(where: { $0.id.hasPrefix("prompt-relay@") }) {
                facts.claudePlugin = record.manifestFound && record.launcherFound ? .installed(version: record.version) : .broken
            } else {
                facts.claudePlugin = .missing
            }
            facts.claudePluginEvents = doctor.observed.byVia["plugin"]?.events ?? 0
            facts.enabledProjects = doctor.capture.enabledProjects.count
            facts.codexObserved = doctor.observed.bySource ?? [:]
            if let error = doctor.capture.configError { facts.coreProblem = "Capture configuration error: \(error)" }
            else if !doctor.storage.writable { facts.coreProblem = "BearlyCopy cannot write its history folder (\(doctor.storage.dataDir))." }
        } else if let error = model.doctor.error {
            facts.coreProblem = error.title
        }
        for session in model.allSessions {
            let target: ConnectionTarget?
            switch (session.provider, session.source?.environment) {
            case (.claudeCode, _): target = .claudeCode
            case (.codex, .xcode?): target = .codexXcode
            case (.codex, .terminal?): target = .codexCLI
            default: target = nil
            }
            guard let target, let at = session.lastEventAt else { continue }
            if (facts.storedLastEvent[target] ?? "") < at { facts.storedLastEvent[target] = at }
        }
        return facts
    }
}

extension AgentFacts.HookDefinitions {
    init(_ state: CodexHookConfiguration.State) {
        switch state {
        case .absent: self = .absent
        case .partial: self = .partial
        case .defined: self = .defined
        case .unreadable: self = .unreadable
        }
    }
}
