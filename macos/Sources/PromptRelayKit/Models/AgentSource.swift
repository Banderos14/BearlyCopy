import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code", codex, imported, unknown
    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .imported: return "Imported"
        case .unknown: return "Unknown"
        }
    }
}

public enum AgentHost: String, Codable, CaseIterable, Sendable {
    case claudeDesktop = "claude_desktop", xcode, terminal, vscode, other, unknown
    public var title: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .xcode: return "Xcode"
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }
}

/// Optional additive metadata: old sessions retain their original identifiers.
public struct AgentSource: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let host: String
    public let nativeSessionID: String?
    public let installationID: String?
    public let capabilities: [String]
    public let capture: String
    public var agent: AgentProvider { AgentProvider(rawValue: provider) ?? .unknown }
    public var environment: AgentHost { AgentHost(rawValue: host) ?? .unknown }
    public var label: String { "\(agent.title) · \(environment.title) · This Mac" }
    /// Phase 9.4: for tight headers — an unconfirmed host is left out, not shown as "Unknown".
    /// Phase 11: "This Mac" is left out too (the laptop icon says it, and it
    /// is the only possible value today); the full `label` is the tooltip.
    public var compactLabel: String {
        environment == .unknown ? agent.title : "\(agent.title) · \(environment.title)"
    }
    enum CodingKeys: String, CodingKey {
        case provider, host, capabilities, capture
        case nativeSessionID = "native_session_id", installationID = "installation_id"
    }
}

extension SessionSummary {
    public var provider: AgentProvider { source?.agent ?? .claudeCode }
    public var sourceLabel: String { source?.label ?? "Claude Code · Unknown · This Mac" }
    public var compactSourceLabel: String { source?.compactLabel ?? "Claude Code" }
}
