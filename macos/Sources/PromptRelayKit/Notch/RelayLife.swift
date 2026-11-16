import CoreGraphics
import Foundation

/// Relay's own small life at rest (Phase 7.1): now and then a glance, a look
/// around, a curious tilt or a smile, and a sleepy face after a long quiet
/// time. One timer at a time, scheduled far apart; nothing runs between
/// beats, so idle costs no CPU. The user always wins: pointer movement and
/// reactions to events cancel the current beat and push the next one back.
///
/// `Idle → (Glance | Looking Around | Curious | Smiling) → Idle`, and
/// `Idle → Sleepy` after `sleepAfter` without activity; any activity wakes it.
@MainActor
final class RelayLife {
    enum Phase: String, Equatable, Sendable {
        case idle, glance, lookingUp, lookingAround, curious, smiling, sleepy
    }

    /// What a beat asks of the face; applied by the controller.
    struct Pose: Equatable {
        var look: CGPoint = .zero
        var roll: Double = 0
        var expression: MascotState.Expression = .none
    }

    private(set) var phase: Phase = .idle
    private(set) var isRunning = false
    private let scheduler: NotchScheduling
    private let now: () -> TimeInterval
    private var random: () -> Double
    private var timer: NotchTimer?
    private var lastActivity: TimeInterval
    /// Applies a pose (the controller eases toward it).
    var apply: (Pose) -> Void = { _ in }
    var expressive = false

    /// Seconds between beats.
    var gap: ClosedRange<Double> { expressive ? 9...18 : 16...34 }
    static let sleepAfter: TimeInterval = 300
    /// Recent pointer movement keeps idle beats away this long.
    static let quietNeeded: TimeInterval = 5

    init(scheduler: NotchScheduling, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.scheduler = scheduler
        self.now = now
        self.random = random
        lastActivity = now()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleNext()
    }

    func stop() {
        isRunning = false
        timer?.cancel(); timer = nil
        if phase != .idle { phase = .idle; apply(Pose()) }
    }

    /// The pointer moved, an answer arrived, something was copied: idle
    /// beats yield to it, and a sleepy Relay wakes up.
    func activity() {
        lastActivity = now()
        if phase != .idle {
            phase = .idle
            timer?.cancel(); timer = nil
            apply(Pose())
        }
        if isRunning, timer == nil { scheduleNext() }
    }

    private func scheduleNext() {
        guard isRunning else { return }
        let delay = gap.lowerBound + (gap.upperBound - gap.lowerBound) * random()
        timer = scheduler.schedule(after: delay) { [weak self] in
            self?.timer = nil
            self?.beat()
        }
    }

    /// One idle moment, chosen by weight; a sequence of poses, then back.
    func beat() {
        guard isRunning else { return }
        let quiet = now() - lastActivity
        if quiet < Self.quietNeeded { scheduleNext(); return }
        if quiet >= Self.sleepAfter {
            phase = .sleepy
            apply(Pose(look: CGPoint(x: 0, y: 0.55), roll: 0, expression: .sleepy))
            return   // stays until activity
        }
        let r = random()
        let side: CGFloat = random() < 0.5 ? -1 : 1
        let steps: [(Pose, TimeInterval)]
        switch r {
        case ..<0.24:
            phase = .glance
            steps = [(Pose(look: CGPoint(x: 0.75 * side, y: -0.15)), 1.6)]
        case ..<0.35:
            // Phase 8: now and then a look up, as if at something above the screen.
            phase = .lookingUp
            steps = [(Pose(look: CGPoint(x: 0.15 * side, y: -0.85)), 1.3)]
        case ..<0.6:
            phase = .lookingAround
            steps = [(Pose(look: CGPoint(x: -0.8 * side, y: 0.05)), 0.9),
                     (Pose(look: CGPoint(x: 0.8 * side, y: -0.25)), 1.1),
                     (Pose(look: CGPoint(x: 0, y: -0.35)), 0.7)]
        case ..<0.82:
            phase = .curious
            steps = [(Pose(look: CGPoint(x: 0.25 * side, y: -0.45), roll: 7 * Double(side), expression: .curious), 1.5)]
        default:
            phase = .smiling
            steps = [(Pose(look: .zero, expression: .smile), 2.2)]
        }
        run(steps)
    }

    private func run(_ steps: [(Pose, TimeInterval)]) {
        guard let (pose, duration) = steps.first else {
            phase = .idle
            apply(Pose())
            scheduleNext()
            return
        }
        apply(pose)
        timer = scheduler.schedule(after: duration) { [weak self] in
            self?.timer = nil
            self?.run(Array(steps.dropFirst()))
        }
    }
}
