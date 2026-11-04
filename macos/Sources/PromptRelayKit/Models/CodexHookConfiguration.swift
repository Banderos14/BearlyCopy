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

    static func inspect(at url: URL) -> Self {
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
                        return command.contains("PROMPT_RELAY_PROVIDER=codex")
                            && command.contains("PROMPT_RELAY_HOST=xcode")
                            && command.contains("/plugin/hooks/run-hook")
                    }
                }
            }.count
            return Self(state: count == 3 ? .defined : .partial(count))
        } catch { return Self(state: .unreadable) }
    }

    var summary: String {
        switch state {
        case .absent: return "Xcode hooks.json: absent · setup required"
        case .partial(let count): return "Xcode hooks.json: \(count)/3 Relay event definitions · review required"
        case .defined: return "Xcode hooks.json: 3/3 Relay event definitions · trust not verified"
        case .unreadable: return "Xcode hooks.json: unreadable or invalid · review required"
        }
    }
}
