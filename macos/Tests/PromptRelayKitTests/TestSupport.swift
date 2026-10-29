import Foundation
@testable import PromptRelayKit

/// Paths into the repository (the package lives in <repo>/macos).
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let golden = root.appendingPathComponent("tests/golden/expected")
    static let cli = root.appendingPathComponent("bin/prompt-relay").path
}

/// One recorded CLI call from a golden file: argv, exit code, stdout.
struct GoldenCall {
    let file: String
    let name: String
    let argv: [String]
    let exitCode: Int32
    let stdout: Data

    var command: String { argv.first ?? "" }

    static func all() throws -> [GoldenCall] {
        let files = try FileManager.default.contentsOfDirectory(at: Repo.golden, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var calls: [GoldenCall] = []
        for url in files {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: [String: Any]]
            for (name, call) in object.sorted(by: { $0.key < $1.key }) {
                let response = try JSONSerialization.data(withJSONObject: call["response"]!)
                calls.append(GoldenCall(file: url.lastPathComponent, name: name, argv: call["argv"] as! [String],
                                        exitCode: Int32(call["exit_code"] as! Int), stdout: response))
            }
        }
        return calls
    }

    static func named(_ file: String, _ name: String) throws -> GoldenCall {
        try all().first { $0.file.hasPrefix(file) && $0.name == name }!
    }

    var output: CommandOutput { CommandOutput(exitCode: exitCode, stdout: stdout) }
}

/// Returns canned outputs and records every call.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    var outputs: [CommandOutput]
    var error: RunnerError?
    private(set) var calls: [(executable: String, arguments: [String], environment: [String: String])] = []

    init(_ outputs: [CommandOutput] = [], error: RunnerError? = nil) {
        self.outputs = outputs
        self.error = error
    }

    func run(executable: String, arguments: [String], environment: [String: String],
             timeout: TimeInterval) async throws -> CommandOutput {
        calls.append((executable, arguments, environment))
        if let error { throw error }
        return outputs.isEmpty ? CommandOutput(exitCode: 0, stdout: Data()) : outputs.removeFirst()
    }
}

func envelope(command: String, ok: Bool = true, data: String = "null", error: String = "null",
              warnings: String = "[]", version: Int = 1) -> Data {
    Data("{\"api_version\":\(version),\"command\":\"\(command)\",\"data\":\(data),\"error\":\(error),\"ok\":\(ok),\"warnings\":\(warnings)}".utf8)
}
