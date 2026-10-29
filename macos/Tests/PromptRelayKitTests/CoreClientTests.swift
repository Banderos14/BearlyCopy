import XCTest
@testable import PromptRelayKit

/// The adapter: how it runs the CLI and how it maps every failure.
final class CoreClientTests: XCTestCase {
    let location = CoreLocation(python: "/opt/py/bin/python3", cli: "/opt/pr/bin/prompt-relay",
                                environment: ["PROMPT_RELAY_HOME": "/tmp/pr-test"])

    func client(_ runner: FakeRunner, resolve: (@Sendable () throws -> CoreLocation)? = nil) -> CoreClient {
        let loc = location
        return CoreClient(runner: runner, resolve: resolve ?? { loc })
    }

    func testRunsIsolatedInterpreterWithExplicitArgumentsAndJSON() async throws {
        let runner = FakeRunner([CommandOutput(exitCode: 0, stdout: envelope(command: "show", data: try showData()))])
        _ = try await client(runner).show(sessionKey: "abc", turn: 3)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, "/opt/py/bin/python3")
        XCTAssertEqual(call.arguments, ["-I", "-S", "-B", "/opt/pr/bin/prompt-relay", "show", "--session", "abc", "--turn", "3", "--json"])
        XCTAssertEqual(call.environment["PROMPT_RELAY_HOME"], "/tmp/pr-test")
        XCTAssertEqual(call.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(call.environment["LC_ALL"], "en_US.UTF-8")
        XCTAssertNil(call.environment["PYTHONPATH"])
    }

    func testDoctorNeverInspectsTheCurrentDirectory() async throws {
        let runner = FakeRunner([CommandOutput(exitCode: 1, stdout: Data("x".utf8))])
        _ = try? await client(runner).doctor()
        XCTAssertEqual(Array(runner.calls.first!.arguments.suffix(3)), ["doctor", "--no-project", "--json"])
    }

    func testApiErrorIsMappedWithCodeAndMessage() async {
        let doc = envelope(command: "turns", ok: false, error: #"{"code":"not_found","message":"no captured sessions"}"#)
        let runner = FakeRunner([CommandOutput(exitCode: 3, stdout: doc)])
        do {
            _ = try await client(runner).turns(sessionKey: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CoreError, .api(code: "not_found", message: "no captured sessions"))
        }
    }

    func testTracebackOrEmptyOutputIsMalformed() async {
        for stdout in [Data(), Data("Traceback (most recent call last):\n".utf8), Data("{\"ok\":true}".utf8)] {
            let runner = FakeRunner([CommandOutput(exitCode: 1, stdout: stdout)])
            do {
                _ = try await client(runner).projects()
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? CoreError, .malformedOutput(exitCode: 1))
            }
        }
    }

    func testFutureApiVersionIsRefused() async {
        let runner = FakeRunner([CommandOutput(exitCode: 0, stdout: envelope(command: "projects", data: "{}", version: 2))])
        do {
            _ = try await client(runner).projects()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CoreError, .unsupportedAPIVersion(2))
        }
    }

    func testOkWithNonZeroExitIsAnError() async {
        let runner = FakeRunner([CommandOutput(exitCode: 1, stdout: envelope(command: "projects", data: "null"))])
        do {
            _ = try await client(runner).projects()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? CoreError)?.apiCode, "internal_error")
        }
    }

    func testMissingPythonOrCliAndRunnerFailures() async {
        let cases: [(@Sendable () throws -> CoreLocation, CoreError)] = [
            ({ throw LocatorError.pythonNotFound(searched: ["/a"]) }, .pythonMissing(searched: ["/a"])),
            ({ throw LocatorError.cliNotFound(searched: ["/b"]) }, .cliMissing(searched: ["/b"])),
        ]
        for (resolve, expected) in cases {
            do {
                _ = try await client(FakeRunner(), resolve: resolve).projects()
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? CoreError, expected)
                XCTAssertFalse(expected.title.isEmpty)
            }
        }
        for (runnerError, expected) in [(RunnerError.timedOut(seconds: 30), CoreError.timedOut(seconds: 30)),
                                         (.launchFailed("POSIX"), .launchFailed("POSIX")),
                                         (.outputTooLarge, .outputTooLarge)] {
            do {
                _ = try await client(FakeRunner(error: runnerError)).projects()
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? CoreError, expected)
            }
        }
    }

    func testProcessRunnerDrainsLargeOutputAndTimesOut() async throws {
        let big = try await ProcessRunner().run(executable: "/usr/bin/head", arguments: ["-c", "3000000", "/dev/zero"],
                                                environment: [:], timeout: 20)
        XCTAssertEqual(big.exitCode, 0)
        XCTAssertEqual(big.stdout.count, 3_000_000)
        do {
            _ = try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["5"], environment: [:], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? RunnerError, .timedOut(seconds: 0))
        }
        do {
            _ = try await ProcessRunner().run(executable: "/no/such/python", arguments: [], environment: [:], timeout: 2)
            XCTFail("expected a launch failure")
        } catch {
            guard case .launchFailed = error as? RunnerError else { return XCTFail("\(error)") }
        }
    }

    private func showData() throws -> String {
        let call = try GoldenCall.named("01", "show")
        let raw = try JSONSerialization.jsonObject(with: call.stdout) as! [String: Any]
        return String(data: try JSONSerialization.data(withJSONObject: raw["data"]!), encoding: .utf8)!
    }
}

final class CoreLocatorTests: XCTestCase {
    func probe(files: Set<String>, executables: Set<String>, pin: String? = nil, pinOwned: Bool = true,
               clt: Bool) -> FileManagerProbe {
        FileManagerProbe(
            isFile: { files.contains($0) },
            isExecutable: { executables.contains($0) },
            isOwnedByCurrentUser: { _ in pinOwned },
            firstLine: { $0.hasSuffix("/python-path") ? pin : nil },
            commandLineToolsInstalled: { clt }
        )
    }

    func testBundledCoreAndPinnedPythonAreUsed() throws {
        let res = URL(fileURLWithPath: "/Apps/PR.app/Contents/Resources")
        let cli = "/Apps/PR.app/Contents/Resources/core/bin/prompt-relay"
        let locator = CoreLocator(processEnvironment: ["HOME": "/Users/u"], bundleResourceURL: res, defaults: { _ in nil },
                                  fileManager: probe(files: [cli], executables: ["/pinned/python3", "/opt/homebrew/bin/python3"],
                                                     pin: "/pinned/python3", clt: true),
                                  versionCheck: { _ in true })
        XCTAssertEqual(try locator.locate(), CoreLocation(python: "/pinned/python3", cli: cli))
        XCTAssertEqual(locator.dataDirectory.path, "/Users/u/Library/Application Support/PromptRelay")
    }

    func testStubPythonIsNotUsedWithoutCommandLineTools() {
        let locator = CoreLocator(processEnvironment: ["HOME": "/Users/u"], bundleResourceURL: nil, defaults: { _ in nil },
                                  fileManager: probe(files: [], executables: ["/usr/bin/python3"], clt: false),
                                  versionCheck: { _ in true })
        XCTAssertFalse(locator.pythonCandidates().contains("/usr/bin/python3"))
        XCTAssertThrowsError(try locator.locatePython())
    }

    func testForeignPinIsIgnoredAndOldPythonSkipped() throws {
        let locator = CoreLocator(processEnvironment: ["HOME": "/Users/u"], bundleResourceURL: nil, defaults: { _ in nil },
                                  fileManager: probe(files: [], executables: ["/evil/python", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"],
                                                     pin: "/evil/python", pinOwned: false, clt: false),
                                  versionCheck: { $0 != "/opt/homebrew/bin/python3" })
        XCTAssertEqual(try locator.locatePython(), "/usr/local/bin/python3")
    }

    func testOverridesAndTestHome() throws {
        let locator = CoreLocator(processEnvironment: ["HOME": "/Users/u", "PROMPT_RELAY_HOME": "/tmp/iso", "PROMPT_RELAY_CLI": "/dev/cli"],
                                  bundleResourceURL: nil,
                                  defaults: { $0 == CoreLocator.pythonOverrideKey ? "/custom/python" : nil },
                                  fileManager: probe(files: ["/dev/cli"], executables: ["/custom/python"], clt: false),
                                  versionCheck: { _ in true })
        let location = try locator.locate()
        XCTAssertEqual(location, CoreLocation(python: "/custom/python", cli: "/dev/cli", environment: ["PROMPT_RELAY_HOME": "/tmp/iso"]))
        XCTAssertEqual(locator.dataDirectory.path, "/tmp/iso")
    }

    func testMissingCliListsWhereItLooked() {
        let locator = CoreLocator(processEnvironment: [:], bundleResourceURL: URL(fileURLWithPath: "/R"), defaults: { _ in nil },
                                  fileManager: probe(files: [], executables: [], clt: false), versionCheck: { _ in true })
        XCTAssertThrowsError(try locator.locateCLI()) {
            XCTAssertEqual($0 as? LocatorError, .cliNotFound(searched: ["/R/core/bin/prompt-relay"]))
        }
    }
}
