import Foundation

/// Where the Core lives and which Python runs it.
public struct CoreLocation: Equatable, Sendable {
    public let python: String
    public let cli: String
    /// Extra environment for the CLI (only `PROMPT_RELAY_HOME`, for tests).
    public let environment: [String: String]

    public init(python: String, cli: String, environment: [String: String] = [:]) {
        self.python = python
        self.cli = cli
        self.environment = environment
    }
}

public enum LocatorError: Error, Equatable, Sendable {
    case cliNotFound(searched: [String])
    case pythonNotFound(searched: [String])
}

/// Finds the CLI and a Python 3.9+ the same way the plugin launcher does
/// (`plugin/hooks/run-hook`): the pin written by `prompt-relay enable`, then
/// well-known locations, and `/usr/bin/python3` only when the Xcode Command
/// Line Tools are installed (otherwise it is an installer stub).
public struct CoreLocator: Sendable {
    public static let cliOverrideKey = "PromptRelayCLIPath"
    public static let pythonOverrideKey = "PromptRelayPythonPath"

    let fileManager: FileManagerProbe
    let processEnvironment: [String: String]
    let bundleResourceURL: URL?
    let defaults: @Sendable (String) -> String?
    let versionCheck: @Sendable (String) -> Bool

    public init(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        defaults: @escaping @Sendable (String) -> String? = { UserDefaults.standard.string(forKey: $0) },
        fileManager: FileManagerProbe = .live,
        versionCheck: @escaping @Sendable (String) -> Bool = CoreLocator.pythonIsSupported
    ) {
        self.processEnvironment = processEnvironment
        self.bundleResourceURL = bundleResourceURL
        self.defaults = defaults
        self.fileManager = fileManager
        self.versionCheck = versionCheck
    }

    /// The data dir rule of `paths.data_dir` (macOS branch).
    public var dataDirectory: URL {
        if let home = processEnvironment["PROMPT_RELAY_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = processEnvironment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/PromptRelay", isDirectory: true)
    }

    public func locate() throws -> CoreLocation {
        let cli = try locateCLI()
        let python = try locatePython()
        var env: [String: String] = [:]
        if let home = processEnvironment["PROMPT_RELAY_HOME"], !home.isEmpty { env["PROMPT_RELAY_HOME"] = home }
        return CoreLocation(python: python, cli: cli, environment: env)
    }

    func cliCandidates() -> [String] {
        var list: [String] = []
        if let override = defaults(Self.cliOverrideKey), !override.isEmpty { list.append(override) }
        // Development runs (`swift run`) point at a checkout's bin/prompt-relay.
        if let dev = processEnvironment["PROMPT_RELAY_CLI"], !dev.isEmpty { list.append(dev) }
        // The Core copied into the app bundle at build time (same layout as the repository).
        if let res = bundleResourceURL {
            list.append(res.appendingPathComponent("core/bin/prompt-relay").path)
        }
        return list
    }

    func locateCLI() throws -> String {
        let candidates = cliCandidates()
        for path in candidates where path.hasPrefix("/") && fileManager.isFile(path) {
            return path
        }
        throw LocatorError.cliNotFound(searched: candidates)
    }

    func pythonCandidates() -> [String] {
        var list: [String] = []
        if let override = defaults(Self.pythonOverrideKey), !override.isEmpty { list.append(override) }
        let pin = dataDirectory.appendingPathComponent("python-path").path
        if fileManager.isOwnedByCurrentUser(pin), let line = fileManager.firstLine(pin) {
            list.append(line)
        }
        list += [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        ]
        if fileManager.commandLineToolsInstalled() { list.append("/usr/bin/python3") }
        return list
    }

    func locatePython() throws -> String {
        let candidates = pythonCandidates()
        for path in candidates where path.hasPrefix("/") && fileManager.isExecutable(path) && versionCheck(path) {
            return path
        }
        throw LocatorError.pythonNotFound(searched: candidates)
    }

    /// `python -I -S -c 'version >= 3.9'`, bounded to a few seconds.
    public static let pythonIsSupported: @Sendable (String) -> Bool = { path in
        let result = runSync(path, ["-I", "-S", "-c", "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"], timeout: 5)
        return result == 0
    }

    static func runSync(_ executable: String, _ args: [String], timeout: TimeInterval) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        return process.terminationStatus
    }
}

/// File-system questions, injectable for tests.
public struct FileManagerProbe: Sendable {
    public var isFile: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool
    public var isOwnedByCurrentUser: @Sendable (String) -> Bool
    public var firstLine: @Sendable (String) -> String?
    public var commandLineToolsInstalled: @Sendable () -> Bool

    public init(
        isFile: @escaping @Sendable (String) -> Bool,
        isExecutable: @escaping @Sendable (String) -> Bool,
        isOwnedByCurrentUser: @escaping @Sendable (String) -> Bool,
        firstLine: @escaping @Sendable (String) -> String?,
        commandLineToolsInstalled: @escaping @Sendable () -> Bool
    ) {
        self.isFile = isFile
        self.isExecutable = isExecutable
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
        self.firstLine = firstLine
        self.commandLineToolsInstalled = commandLineToolsInstalled
    }

    public static let live = FileManagerProbe(
        isFile: { path in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
        },
        isExecutable: { path in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        },
        isOwnedByCurrentUser: { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
            return owner.uint32Value == getuid()
        },
        firstLine: { path in
            guard let data = FileManager.default.contents(atPath: path), data.count < 4096,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            return line?.trimmingCharacters(in: .whitespaces)
        },
        commandLineToolsInstalled: {
            CoreLocator.runSync("/usr/bin/xcode-select", ["-p"], timeout: 5) == 0
        }
    )
}
