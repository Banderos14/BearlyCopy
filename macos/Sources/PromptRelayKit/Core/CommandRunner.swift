import Foundation

/// The raw result of one CLI run.
public struct CommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum RunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(seconds: Int)
    case outputTooLarge
}

/// Runs one program with arguments. No shell is involved anywhere.
public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String],
             timeout: TimeInterval) async throws -> CommandOutput
}

/// `Process`-based runner. stdout and stderr are drained on background
/// threads so a large answer can never dead-lock on a full pipe, and the
/// caller awaits without blocking the main thread.
public struct ProcessRunner: CommandRunning {
    /// Hard cap on stdout (the hook accepts payloads up to 64 MiB; the JSON
    /// escaping can roughly double that).
    public static let maxOutputBytes = 256 * 1024 * 1024

    public init() {}

    public func run(executable: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(executable, arguments, environment, timeout) })
            }
        }
    }

    static func runBlocking(_ executable: String, _ arguments: [String], _ environment: [String: String],
                            _ timeout: TimeInterval) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        // `doctor` without --project would inspect the current directory; the
        // client always passes explicit options, and this keeps the cwd neutral.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        var stdoutData = Data(), stderrData = Data()
        var tooLarge = false
        let lock = NSLock()
        group.enter()
        DispatchQueue.global().async {
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if stdoutData.count + chunk.count > maxOutputBytes { tooLarge = true } else { stdoutData.append(chunk) }
                lock.unlock()
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); stderrData = data.prefix(64 * 1024); lock.unlock()
            group.leave()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.wait()
            throw RunnerError.launchFailed(String(describing: type(of: error)))
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            group.wait()
            throw RunnerError.timedOut(seconds: Int(timeout))
        }
        group.wait()
        lock.lock(); defer { lock.unlock() }
        if tooLarge { throw RunnerError.outputTooLarge }
        return CommandOutput(exitCode: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
    }
}
