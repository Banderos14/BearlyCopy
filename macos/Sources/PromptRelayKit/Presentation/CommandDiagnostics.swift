import Foundation

/// A read-only projection of saved events, not a new source of verification.
enum CommandFilter: String, CaseIterable {
    case all = "All", failed = "Failed", tests = "Tests", builds = "Builds", git = "Git"

    func includes(_ command: ObservedCommand) -> Bool {
        switch self {
        case .all: return true
        case .failed: return FailureInspector.isFailure(command) && !FailureInspector.likelyNotAnError(command)
        case .tests: return command.kind == "test"
        case .builds: return command.kind == "build"
        case .git: return command.kind == "git"
        }
    }
}

enum CommandDiagnostics {
    static func safeText(_ command: ObservedCommand) -> String? {
        guard command.commandWithheld == nil, let text = command.command,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func output(_ command: ObservedCommand) -> String {
        guard command.tailWithheld == nil, let text = command.outputTail, !text.isEmpty else { return "Not captured" }
        return text
    }

    static func summary(_ commands: [ObservedCommand]) -> String {
        "\(commands.count) observed · \(commands.filter(CommandFilter.failed.includes).count) failed · "
        + "\(commands.filter(CommandFilter.tests.includes).count) test commands · \(commands.filter(CommandFilter.builds.includes).count) builds"
    }
}

/// Only omits leading Markdown headings/blank lines in the compact display.
/// The source request, full reader, copy and export remain verbatim.
enum TaskExcerpt {
    static func text(_ source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        // Prefer an explicit goal written by the user, never infer one.
        if let goal = lines.firstIndex(where: { line in
            let label = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "").lowercased()
            return label.hasPrefix("цель:") || label.hasPrefix("goal:") || label.hasPrefix("objective:")
        }) { return lines[goal...].joined(separator: "\n") }
        let first = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        guard let first else { return source }
        return lines[first...].joined(separator: "\n")
    }
}
