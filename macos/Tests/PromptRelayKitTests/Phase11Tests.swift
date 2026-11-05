import Foundation
import Testing
@testable import PromptRelayKit

/// Phase 11: tests use in-memory settings, never real UserDefaults suites.
@MainActor
struct Phase11SettingsStoreTests {
    @Test func memoryStoreBehavesLikeUserDefaultsForTheMethodsTheAppUses() throws {
        let store = MemorySettingsStore()
        #expect(store.object(forKey: "a") == nil)
        #expect(store.bool(forKey: "a") == false)
        store.set(true, forKey: "a")
        #expect(store.bool(forKey: "a"))
        #expect(store.object(forKey: "a") as? Bool == true)
        store.set("x", forKey: "s")
        #expect(store.string(forKey: "s") == "x")
        let none: String? = nil
        store.set(none, forKey: "s")
        #expect(store.object(forKey: "s") == nil, "setting nil removes, as in UserDefaults")
        store.set(Data([1, 2]), forKey: "d")
        #expect(store.data(forKey: "d") == Data([1, 2]))
        store.set(["b", "a"], forKey: "arr")
        #expect(store.stringArray(forKey: "arr") == ["b", "a"])
        store.set(["k": "v"], forKey: "dict")
        #expect(store.dictionary(forKey: "dict") as? [String: String] == ["k": "v"])
        store.removeObject(forKey: "dict")
        #expect(store.dictionary(forKey: "dict") == nil)
    }

    @Test func notchSettingsPersistIntoAnInjectedStore() {
        let store = MemorySettingsStore()
        let settings = NotchSettings(defaults: store)
        settings.notifyWhenReady = true
        settings.relayMotion = .off
        let again = NotchSettings(defaults: store)
        #expect(again.notifyWhenReady)
        #expect(again.relayMotion == .off)
    }

    /// Guard: no test source may create a real suite again.
    @Test func noTestCreatesARealUserDefaultsSuite() throws {
        let dir = Repo.root.appendingPathComponent("macos/Tests/PromptRelayKitTests")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Phase11Tests.swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("UserDefaults(suiteName"), "\(file.lastPathComponent) creates a real suite")
            #expect(!text.contains("removePersistentDomain"), "\(file.lastPathComponent) touches real preferences")
        }
    }
}

/// Phase 11: About says which build runs and when it is not the one installed.
struct Phase11BuildDiagnosticsTests {
    let a = AppBuild.Stamp(version: "0.3.0", commit: "aaaaaaa", builtAt: "2026-11-05T10:00:00Z", coreVersion: "0.3.0")
    let b = AppBuild.Stamp(version: "0.3.0", commit: "bbbbbbb", builtAt: "2026-11-05T12:00:00Z", coreVersion: "0.3.0")
    let installed = "/Users/me/Applications/Prompt Relay.app"

    @Test func sameBuildEverywhereSaysNothing() {
        let notes = AppBuild.diagnose(running: a, runningPath: installed, isDebug: false, onDiskAtRunningPath: a,
                                      installed: [(installed, a)], coreInUse: "0.3.0")
        #expect(notes.isEmpty)
    }

    @Test func xcodeBuildNamesTheStaleInstalledApp() {
        let notes = AppBuild.diagnose(running: b, runningPath: "/DerivedData/Prompt Relay.app", isDebug: true,
                                      onDiskAtRunningPath: b, installed: [(installed, a)], coreInUse: nil)
        #expect(notes.count == 1)
        #expect(notes[0].contains("Xcode build"))
        #expect(notes[0].contains("aaaaaaa") && notes[0].contains("bbbbbbb"))
        #expect(notes[0].contains("install-local.sh"))
    }

    @Test func replacedWhileRunningAsksForARestart() {
        let notes = AppBuild.diagnose(running: a, runningPath: installed, isDebug: false, onDiskAtRunningPath: b,
                                      installed: [(installed, b)], coreInUse: nil)
        #expect(notes.count == 1)
        #expect(notes[0].contains("Quit and reopen"))
    }

    @Test func coreMismatchesAreReportedOnlyWhenKnown() {
        var odd = a
        odd.coreVersion = "0.2.0"
        let notes = AppBuild.diagnose(running: odd, runningPath: installed, isDebug: false, onDiskAtRunningPath: odd,
                                      installed: [], coreInUse: "0.4.0")
        #expect(notes.contains { $0.contains("bundled Core is 0.2.0") })
        #expect(notes.contains { $0.contains("reports 0.4.0") })
        // Unknown facts never produce a claim.
        let unknown = AppBuild.Stamp(version: "0.3.0", commit: nil)
        #expect(AppBuild.diagnose(running: unknown, runningPath: "/x", isDebug: true, onDiskAtRunningPath: nil,
                                  installed: [(installed, AppBuild.Stamp(version: "0.3.0", commit: nil))], coreInUse: nil).isEmpty)
    }

    @Test func stampIsReadFromTheBundleOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pr11-\(UUID().uuidString)/X.app")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let core = dir.appendingPathComponent("Contents/Resources/core/plugin/prompt_relay")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try "\"\"\"doc\"\"\"\n\n__version__ = \"9.8.7\"\n".write(to: core.appendingPathComponent("__init__.py"), atomically: true, encoding: .utf8)
        let plist: NSDictionary = ["CFBundleShortVersionString": "9.8.7", "PRGitCommit": "abc1234", "PRGitDirty": "yes",
                                   "PRBuildDate": "2026-11-05T00:00:00Z"]
        plist.write(to: dir.appendingPathComponent("Contents/Info.plist"), atomically: true)
        let stamp = try #require(AppBuild.Stamp.read(appAt: dir))
        #expect(stamp.version == "9.8.7" && stamp.coreVersion == "9.8.7")
        #expect(stamp.commitText == "abc1234 + uncommitted changes")
    }
}

/// Phase 11 onboarding: "Connected" only after delivery; per host.
struct Phase11ConnectionStatusTests {
    func observed(_ outcome: String, stored: String? = nil, errorAt: String? = nil, error: String? = nil) -> DoctorData.Observed.Source {
        let json = """
        {"events":1,"last_at":"2026-11-05T10:00:00Z","last_event":"Stop","last_outcome":"\(outcome)",
         "last_stored_at":\(stored.map { "\"\($0)\"" } ?? "null"),"last_error_at":\(errorAt.map { "\"\($0)\"" } ?? "null"),
         "last_error":\(error.map { "\"\($0)\"" } ?? "null")}
        """
        return try! JSONDecoder().decode(DoctorData.Observed.Source.self, from: Data(json.utf8))
    }

    @Test func nothingInstalledIsNotDetectedEverywhere() {
        let facts = AgentFacts(claudePlugin: .missing)
        for target in ConnectionTarget.allCases { #expect(facts.state(of: target) == .notDetected) }
    }

    @Test func claudeStepsFromInstalledToConnectedOnlyWithStoredEvents() {
        var facts = AgentFacts(claudeFootprint: true)
        #expect(facts.state(of: .claudeCode) == .installed)            // doctor not loaded yet
        facts.claudePlugin = .missing
        #expect(facts.state(of: .claudeCode) == .configurationRequired)
        facts.claudePlugin = .installed(version: "0.3.0")
        #expect(facts.state(of: .claudeCode) == .captureDisabled)
        facts.enabledProjects = 1
        #expect(facts.state(of: .claudeCode) == .waitingForFirstEvent, "a plugin record is configuration, not connection")
        facts.storedLastEvent[.claudeCode] = "2026-11-05T10:00:00Z"
        #expect(facts.state(of: .claudeCode) == .connected(lastEventAt: "2026-11-05T10:00:00Z"))
        facts.claudePlugin = .broken
        facts.storedLastEvent = [:]
        if case .error = facts.state(of: .claudeCode) {} else { Issue.record("broken plugin must be an error") }
    }

    @Test func codexNeedsDefinitionsThenTrustThenDelivery() {
        var facts = AgentFacts(codexXcodeFootprint: true, enabledProjects: 1)
        #expect(facts.state(of: .codexXcode) == .configurationRequired)
        facts.codexXcodeHooks = .partial
        #expect(facts.state(of: .codexXcode) == .configurationRequired)
        facts.codexXcodeHooks = .defined
        #expect(facts.state(of: .codexXcode) == .trustRequired, "defined but never run")
        facts.codexObserved["codex:xcode"] = observed("project_not_enabled")
        #expect(facts.state(of: .codexXcode) == .captureDisabled)
        facts.codexObserved["codex:xcode"] = observed("stored", stored: "2026-11-05T11:00:00Z")
        #expect(facts.state(of: .codexXcode) == .connected(lastEventAt: "2026-11-05T11:00:00Z"))
        facts.codexXcodeHooks = .unreadable
        facts.codexObserved = [:]
        if case .error = facts.state(of: .codexXcode) {} else { Issue.record("unreadable hooks.json must be an error") }
    }

    @Test func aCLIDeliveryNeverConnectsXcode() {
        var facts = AgentFacts(codexCLIFootprint: true, codexCLIHooks: .defined,
                               codexXcodeFootprint: true, codexXcodeHooks: .defined, enabledProjects: 1)
        facts.codexObserved["codex:terminal"] = observed("stored", stored: "2026-11-05T12:00:00Z")
        facts.storedLastEvent[.codexCLI] = "2026-11-05T12:00:00Z"
        #expect(facts.state(of: .codexCLI).isConnected)
        #expect(facts.state(of: .codexXcode) == .trustRequired)
    }

    @Test func aRejectedEventIsAnErrorWithItsReason() {
        var facts = AgentFacts(codexCLIFootprint: true, codexCLIHooks: .defined, enabledProjects: 1)
        facts.codexObserved["codex:terminal"] = observed("invalid_json", errorAt: "2026-11-05T12:00:00Z", error: "invalid_json")
        #expect(facts.state(of: .codexCLI) == .error("The hook ran but its event was rejected (invalid_json)."))
        #expect(facts.diagnosis(of: .codexCLI).contains("invalid_json"))
    }

    @Test func aCoreProblemIsReportedForEveryAgent() {
        let facts = AgentFacts(claudeFootprint: true, claudePlugin: .installed(version: nil), enabledProjects: 1,
                               coreProblem: "Python 3.9 or newer was not found")
        #expect(facts.state(of: .claudeCode) == .error("Python 3.9 or newer was not found"))
    }

    @Test func setupCommandsAreReversibleAndScoped() {
        #expect(SetupView.claudeConnect.contains("claude plugin install prompt-relay@prompt-relay"))
        #expect(!SetupView.claudeConnect.contains("--scope project"), "never turn the plugin on for a shared repo")
        #expect(SetupView.claudeUndo.contains("uninstall"))
        let xcode = SetupView.codexConnect(.codexXcode)
        #expect(xcode.contains("--host xcode") && xcode.contains("CodingAssistant/codex/hooks.json"))
        #expect(xcode.contains("preview, changes nothing"))
        #expect(SetupView.codexConnect(.codexCLI).contains("--host terminal"))
        #expect(SetupView.codexUndo(.codexCLI).contains("--disable --apply"))
    }
}
