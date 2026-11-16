import Foundation
import Testing
@testable import PromptRelayKit

struct Phase91Tests {
    @Test func definitionsAreNotConnectionEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hooks.json")
        #expect(CodexHookConfiguration.inspect(at: file).state == .absent)
        let command = "env PROMPT_RELAY_PROVIDER=codex PROMPT_RELAY_HOST=xcode /bin/sh /repo/plugin/hooks/run-hook"
        let group: [[String: Any]] = [["hooks": [["type": "command", "command": command]]]]
        let hooks = Dictionary(uniqueKeysWithValues: ["UserPromptSubmit", "PostToolUse", "Stop"].map { ($0, group) })
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: file)
        let result = CodexHookConfiguration.inspect(at: file)
        #expect(result.state == .defined)
        #expect(result.summary.contains("trust not verified"))
        #expect(!result.summary.contains("Connected"))
    }

    @Test func foreignAndCLIConfigurationsDoNotProveXcode() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let command = "env PROMPT_RELAY_PROVIDER=codex PROMPT_RELAY_HOST=terminal /bin/sh /repo/plugin/hooks/run-hook"
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]).write(to: file)
        #expect(CodexHookConfiguration.inspect(at: file).state == .partial(0))
        try Data("invalid".utf8).write(to: file)
        #expect(CodexHookConfiguration.inspect(at: file).state == .unreadable)
    }
}
