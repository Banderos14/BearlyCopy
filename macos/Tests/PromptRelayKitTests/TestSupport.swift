import AppKit
import QuartzCore
import XCTest
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

/// Phase 7.2: Bearly is Core Animation layers; this renders the real layer
/// tree (`RelayLayerView`) into a bitmap, top-left origin.
@MainActor
enum RelayRender {
    static func image(_ state: MascotState, size: CGFloat = 28, reduceMotion: Bool = false, resting: Bool = true,
                      canvas: CGSize = CGSize(width: 28, height: 28), origin: CGPoint = .zero, scale: CGFloat = 4) -> CGImage? {
        let view = RelayLayerView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        view.layoutSubtreeIfNeeded()
        view.layout()
        view.configure(size: size, reduceMotion: reduceMotion, resting: resting,
                       facts: RelayFacts(mood: state.mood, expression: state.expression, roll: state.roll, still: state.still,
                                         cheers: state.cheers, worries: state.worries))
        view.render(at: RelayMotion.clock())
        guard let layer = view.layer else { return nil }
        // `render(in:)` draws y-up and ignores a root layer's geometry flip:
        // place Bearly from the bottom so `origin` is measured from the top.
        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: canvas)
        container.anchorPoint = .zero
        container.position = .zero
        layer.removeFromSuperlayer()
        layer.anchorPoint = .zero
        layer.position = CGPoint(x: origin.x, y: canvas.height - origin.y - size)
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        container.addSublayer(layer)
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        container.render(in: ctx)
        return ctx.makeImage()
    }
}

/// Phase 11: tests never create real UserDefaults suites. A suite name maps
/// to one shared in-memory store for the life of the test process, so a test
/// that builds a second model "after a restart" with the same name sees the
/// same values, exactly as with a real suite — but `cfprefsd` is never asked
/// for a domain and no plist appears in `~/Library/Preferences`.
enum TestDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stores: [String: MemorySettingsStore] = [:]

    /// Optional only so call sites written for the old real-suite initializer
    /// (`try #require`, `XCTUnwrap`, `!`) keep compiling; never nil.
    static func named(_ suite: String) -> MemorySettingsStore? {
        lock.lock(); defer { lock.unlock() }
        if let store = stores[suite] { return store }
        let store = MemorySettingsStore()
        stores[suite] = store
        return store
    }

    static func remove(_ suite: String) {
        lock.lock(); defer { lock.unlock() }
        stores[suite] = nil
    }
}

/// Forgets a test's in-memory suite. Touches nothing on disk.
func removeTestDefaults(_ suite: String) {
    TestDefaults.remove(suite)
}

/// Phase 12.2: tests that post real scroll-wheel events to on-screen windows
/// need an unlocked session with awake displays. Measured 2026-11-06: with
/// the screen locked both scroll tests failed (also on the previous commit);
/// unlocked, both passed. Skipped, with this reason, instead of a false
/// failure — category "environment blocked", never counted as passed.
func requireLiveScreen() throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? ((session["CGSSessionScreenIsLocked"] as? Int) == 1)
    let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    if locked || asleep {
        throw XCTSkip("Environment blocked: the screen is \(locked ? "locked" : "asleep"); scroll events reach no window.")
    }
}
