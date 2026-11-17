import Foundation

/// Configuration evidence only. Reading a definition cannot establish client
/// trust, runtime availability, or delivery of a real Xcode event.
struct CodexHookConfiguration: Equatable {
    enum State: Equatable { case absent, partial(Int), defined, unreadable }
    let state: State

    static var xcodeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/CodingAssistant/codex/hooks.json")
    }

    /// Codex CLI's user-level hooks (CODEX_HOME defaults to ~/.codex).
    static var cliURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    static func inspect(at url: URL) -> Self { inspect(at: url, host: "xcode") }

    /// Counts BearlyCopy's own definitions for one host label; other
    /// hooks in the file are never read beyond their command strings.
    static func inspect(at url: URL, host: String) -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self(state: .absent) }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = object["hooks"] as? [String: Any] else { return Self(state: .unreadable) }
            let count = ["UserPromptSubmit", "PostToolUse", "Stop"].filter { event in
                guard let groups = hooks[event] as? [[String: Any]] else { return false }
                return groups.contains { group in
                    (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                        guard hook["type"] as? String == "command", let command = hook["command"] as? String else { return false }
                        return Self.isRelayCommand(command, host: host)
                    }
                }
            }.count
            return Self(state: count == 3 ? .defined : .partial(count))
        } catch { return Self(state: .unreadable) }
    }

    /// Token equality with the shape `configure-codex.py` writes:
    /// `env PROMPT_RELAY_PROVIDER=codex PROMPT_RELAY_HOST=<host> /bin/sh <…/plugin/hooks/run-hook>`.
    /// Only a known host label counts; substrings never do.
    static func isRelayCommand(_ command: String, host: String) -> Bool {
        guard AgentHost(rawValue: host) != nil else { return false }
        let tokens = command.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        guard tokens.count >= 5, tokens[0] == "env", tokens[1] == "PROMPT_RELAY_PROVIDER=codex",
              tokens[2] == "PROMPT_RELAY_HOST=\(host)", tokens[3] == "/bin/sh" else { return false }
        return tokens[4...].joined(separator: " ").hasSuffix("/plugin/hooks/run-hook")
    }

    var summary: String {
        switch state {
        case .absent: return "Xcode hooks.json: absent · setup required"
        case .partial(let count): return "Xcode hooks.json: \(count)/3 Bearly event definitions · review required"
        case .defined: return "Xcode hooks.json: 3/3 Bearly event definitions · trust not verified"
        case .unreadable: return "Xcode hooks.json: unreadable or invalid · review required"
        }
    }
}
