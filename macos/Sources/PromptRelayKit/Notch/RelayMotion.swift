import CoreGraphics
import Foundation

/// Bearly's motion, frame-rate independent (Phase 7.2).
///
/// Before: a 30 Hz main-queue timer eased the gaze and head and published
/// them as observed state, so each change re-ran SwiftUI; with the pointer
/// throttled to 30 Hz and "publish only visible changes", Bearly redrew about
/// 12 times a second while following the pointer (measured), on a timer not
/// aligned to the display.
///
/// Now: this engine holds the physics and is read by the drawing itself,
/// inside `TimelineView(.animation)`, once per display frame (capped near
/// 60 fps, also on ProMotion). Every step uses the real time since the last
/// frame, in sub-steps of at most 1/240 s, so the speed is the same at 60 and
/// 120 Hz and a late frame does not make Bearly jump or freeze. When
/// everything has settled the view pauses its timeline: at rest nothing is
/// computed or drawn. Techniques adapted from Coucou (MIT, © 2026 Louis
/// Raillé): frame-rate independent exponential smoothing
/// `x += (t − x)·(1 − b^dt)`, time-based tweens with easing for the blink
/// (fast close, softer open, now and then a double blink), and a spring
/// driven by the head's velocity for secondary motion (here: the ears). No
/// Coucou artwork, character or animation is used; Bearly is drawn as before.
@MainActor
final class RelayMotion {
    /// Display frames are asked for at most this often (≈ 60 fps; 10 % short
    /// of 1/60 s, or display jitter would skip every other frame).
    static let frameInterval: TimeInterval = 0.9 / 60
    /// The timeline's clock (its frame dates), so inputs and frames agree.
    nonisolated static func clock() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    // Targets
    private(set) var lookTarget: CGPoint = .zero
    /// R8: when the pointer rests, the head returns first, the eyes linger.
    private(set) var headRelaxed = false
    /// How far the head follows the look (Subtle 0.65, Expressive 1).
    var headScale: CGFloat = 1
    /// Phase 8: 0 (Subtle) … 1 (Expressive). Expressive gives the head a
    /// livelier spring (a little more overshoot on a fast move) and the ears
    /// more swing; Subtle stays as calm as before.
    var liveliness: CGFloat = 0
    private(set) var amountTargets = Amounts()

    // State
    private(set) var gaze: CGPoint = .zero
    private(set) var head: CGPoint = .zero
    private var headVelocity: CGPoint = .zero
    /// The ears lag behind fast head turns (−1…1), then swing back.
    private(set) var earLag: CGFloat = 0
    private var earVelocity: CGFloat = 0
    private(set) var amounts = Amounts()
    private var blinkStart: TimeInterval?
    private var secondBlinkAt: TimeInterval?
    private var lastTime: TimeInterval?
    private(set) var isSettled = true

    /// Continuous face amounts, 0…1: every expression change is a blend.
    struct Amounts: Equatable {
        var smile: CGFloat = 0
        var sleepy: CGFloat = 0
        var curious: CGFloat = 0
    }

    /// A short reaction played over the pose.
    enum Reaction: Equatable {
        case cheer, worry
        /// Phase 8: a small nod when a new answer arrives.
        case nod
        /// Phase 8: the pointer came onto Bearly: a tiny lift, ears up.
        case perk
    }

    /// What one frame draws.
    struct Frame: Equatable {
        var gaze: CGPoint
        var head: CGPoint
        var earLag: CGFloat
        /// 1 open … 0 closed (the blink).
        var eyeOpen: CGFloat
        var amounts: Amounts
        /// The idle tilt, degrees.
        var roll: Double = 0
        /// Reaction: 0 = none. `lift` up in points of a 28-pt Bearly, `shake` −1…1,
        /// `squint` 0…1 (happy closed eyes), `scale` around 1.
        var lift: CGFloat = 0
        var shake: Double = 0
        var squint: CGFloat = 0
        var scale: CGFloat = 1
        /// Added to the head's pitch (the nod), −1…1.
        var nod: CGFloat = 0
    }

    private(set) var rollTarget: Double = 0
    private(set) var roll: Double = 0
    private var reaction: (kind: Reaction, start: TimeInterval)?

    /// The happy hop (copy, Done) or the small worried shake (a failure).
    func react(_ kind: Reaction, now: TimeInterval = RelayMotion.clock()) {
        reaction = (kind, now)
        wake(now)
    }

    func setRoll(_ degrees: Double, now: TimeInterval = RelayMotion.clock()) {
        guard degrees != rollTarget else { return }
        rollTarget = degrees
        wake(now)
    }

    /// The reaction's curves at `t` seconds after it began (the timings of
    /// the Phase 5 keyframes: hop 0.14 s up, 0.3 s down; shake 0.35 s;
    /// squint held 0.8 s).
    static func reactionCurve(_ kind: Reaction, t: TimeInterval) -> (lift: CGFloat, shake: Double, squint: CGFloat, scale: CGFloat) {
        let c = curve(kind, t: t)
        return (c.lift, c.shake, c.squint, c.scale)
    }

    /// Every reaction's curves at `t`, the nod included.
    static func curve(_ kind: Reaction, t: TimeInterval) -> (lift: CGFloat, shake: Double, squint: CGFloat, scale: CGFloat, nod: CGFloat) {
        func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
        func seg(_ t: Double, _ keys: [(Double, Double)], from: Double = 0) -> Double {
            var start = 0.0, value = from
            for (to, d) in keys {
                if t < start + d { return value + (to - value) * ease((t - start) / d) }
                start += d; value = to
            }
            return value
        }
        switch kind {
        case .cheer:
            let lift = seg(t, [(1, 0.14), (0, 0.3)])
            let scale = seg(t, [(1.08, 0.14), (0.97, 0.14), (1, 0.22)], from: 1)
            let squint = t < 0.06 ? t / 0.06 : (t < 0.86 ? 1 : max(0, 1 - (t - 0.86) / 0.12))
            return (CGFloat(lift), 0, CGFloat(squint), CGFloat(scale), 0)
        case .worry:
            let shake = seg(t, [(-1, 0.07), (1, 0.1), (-0.6, 0.09), (0, 0.09)])
            return (0, shake, 0, 1, 0)
        case .nod:
            // Down, a little up past rest, back: 0.7 s.
            return (0, 0, 0, 1, CGFloat(seg(t, [(0.55, 0.16), (-0.15, 0.22), (0, 0.32)])))
        case .perk:
            let lift = seg(t, [(0.45, 0.12), (0, 0.33)])
            let scale = seg(t, [(1.04, 0.12), (1, 0.33)], from: 1)
            return (CGFloat(lift), 0, 0, CGFloat(scale), 0)
        }
    }

    /// Frame intervals while animating, for the frame-pacing check (kept
    /// in Release too, so Release can be measured; at most 4,000 numbers).
    private(set) var intervals: [TimeInterval] = []
    func resetIntervals() { intervals = [] }

    // MARK: Inputs

    /// Where to look, each axis −1…1 (y down). Returns true when it changed.
    @discardableResult
    func look(at target: CGPoint, now: TimeInterval = RelayMotion.clock()) -> Bool {
        guard target != lookTarget || headRelaxed && target != .zero else { return false }
        lookTarget = target
        if target != .zero { headRelaxed = false }
        wake(now)
        return true
    }

    /// The head goes back to neutral now; the eyes stay where they look.
    func relaxHead(now: TimeInterval = RelayMotion.clock()) {
        guard !headRelaxed else { return }
        headRelaxed = true
        wake(now)
    }

    func setAmounts(_ target: Amounts, now: TimeInterval = RelayMotion.clock()) {
        guard target != amountTargets else { return }
        amountTargets = target
        wake(now)
    }

    /// A blink: 70 ms closing, 130 ms opening; one in five is a double blink.
    func blink(now: TimeInterval = RelayMotion.clock(), double: Bool = false) {
        blinkStart = now
        secondBlinkAt = double ? now + 0.23 : nil
        wake(now)
    }

    /// Puts the eyes and head somewhere at once, settled (renders, tests).
    func place(gaze: CGPoint, head: CGPoint) {
        self.gaze = gaze; self.head = head; lookTarget = gaze
        headScale = gaze.x == 0 ? headScale : head.x / gaze.x
        headVelocity = .zero; earLag = 0; earVelocity = 0
        isSettled = true
    }

    /// Everything back to neutral at once (Reduce Motion, Bearly off).
    func reset() {
        lookTarget = .zero; gaze = .zero; head = .zero; headVelocity = .zero; headRelaxed = false
        earLag = 0; earVelocity = 0
        amounts = amountTargets
        blinkStart = nil; secondBlinkAt = nil
        reaction = nil; roll = rollTarget
        isSettled = true
        lastTime = nil
    }

    private func wake(_ now: TimeInterval) {
        if isSettled { lastTime = now }
        isSettled = false
    }

    // MARK: Stepping

    /// Advances to `now` and returns the frame to draw. Called by the
    /// timeline once per display frame.
    func frame(at now: TimeInterval) -> Frame {
        let last = lastTime ?? now
        let elapsed = max(0, min(now - last, 0.1))   // a long gap (sleep, hidden) is not replayed
        lastTime = now
        if !isSettled, elapsed > 0 { intervals.append(elapsed); if intervals.count > 4000 { intervals.removeFirst(1000) } }
        if !isSettled, elapsed > 0 {
            var left = elapsed
            while left > 1e-9 {
                let dt = min(left, 1.0 / 240)
                step(dt)
                left -= dt
            }
            isSettled = settled(now)
        }
        var f = Frame(gaze: gaze, head: head, earLag: earLag, eyeOpen: eyeOpen(now), amounts: amounts, roll: roll)
        if let reaction {
            let c = Self.curve(reaction.kind, t: now - reaction.start)
            f.lift = c.lift; f.shake = c.shake; f.squint = c.squint; f.scale = c.scale; f.nod = c.nod
        }
        return f
    }

    var headTarget: CGPoint { headRelaxed ? .zero : CGPoint(x: lookTarget.x * headScale, y: lookTarget.y * headScale) }

    private func step(_ dt: Double) {
        let d = CGFloat(dt)
        // Eyes: fast exponential approach (≈ 90 % in 0.13 s), no overshoot.
        let kEyes = 1 - pow(0.0002, d)
        gaze.x += (lookTarget.x - gaze.x) * kEyes
        gaze.y += (lookTarget.y - gaze.y) * kEyes
        // Head: a damped spring (ω 12, ζ 0.78), slower than the eyes, with a
        // touch of overshoot, so it trails and settles. Expressive: ω 13.5,
        // ζ 0.64 — a visible, still soft overshoot on a quick move.
        let target = headTarget
        let omega: CGFloat = 12 + 1.5 * liveliness, zeta: CGFloat = 0.78 - 0.14 * liveliness
        headVelocity.x += (omega * omega * (target.x - head.x) - 2 * zeta * omega * headVelocity.x) * d
        headVelocity.y += (omega * omega * (target.y - head.y) - 2 * zeta * omega * headVelocity.y) * d
        head.x += headVelocity.x * d
        head.y += headVelocity.y * d
        // Ears: a soft spring pulled against the head's sideways speed (and,
        // a little, its nodding speed).
        let earTarget = max(-1, min(1, -headVelocity.x * (0.16 + 0.08 * liveliness) - headVelocity.y * 0.05))
        earVelocity += (120 * (earTarget - earLag) - 18 * earVelocity) * d   // ζ ≈ 0.82: one soft swing, settled in ≈ 0.6 s
        earLag += earVelocity * d
        // Faces blend (≈ 0.35 s).
        let kFace = 1 - pow(0.002, d)
        amounts.smile += (amountTargets.smile - amounts.smile) * kFace
        amounts.sleepy += (amountTargets.sleepy - amounts.sleepy) * kFace * 0.6   // eyelids grow heavy slowly
        amounts.curious += (amountTargets.curious - amounts.curious) * kFace
        // The idle tilt eases in and out (≈ 0.45 s).
        roll += (rollTarget - roll) * Double(1 - pow(0.001, d))
    }

    private func settled(_ now: TimeInterval) -> Bool {
        let eps: CGFloat = 0.002
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }
        let target = headTarget
        let face = abs(amounts.smile - amountTargets.smile) < eps && abs(amounts.sleepy - amountTargets.sleepy) < eps
            && abs(amounts.curious - amountTargets.curious) < eps
        let blinking = blinkStart.map { now - $0 < 0.2 } ?? false || secondBlinkAt.map { now < $0 + 0.2 } ?? false
        let reacting = reaction.map { now - $0.start < ($0.kind == .cheer || $0.kind == .worry ? 1.0 : 0.75) } ?? false
        if !reacting { reaction = nil }
        let done = near(gaze, lookTarget) && near(head, target) && abs(headVelocity.x) < 0.01 && abs(headVelocity.y) < 0.01
            && abs(earLag) < eps && abs(earVelocity) < 0.01 && face && !blinking && !reacting && abs(roll - rollTarget) < 0.01
        if done {
            // Land exactly: the last frame is the resting pose, not 0.2 % off it.
            gaze = lookTarget; head = target; headVelocity = .zero; earLag = 0; earVelocity = 0; amounts = amountTargets
            roll = rollTarget
            blinkStart = nil; secondBlinkAt = nil
        }
        return done
    }

    /// The blink's lids: closing eases in and out over 70 ms, opening eases
    /// out over 130 ms.
    private func eyeOpen(_ now: TimeInterval) -> CGFloat {
        var open: CGFloat = 1
        for start in [blinkStart, secondBlinkAt].compactMap({ $0 }) {
            let t = now - start
            guard t >= 0, t < 0.2 else { continue }
            let v: CGFloat
            if t < 0.07 {
                let p = CGFloat(t / 0.07)
                v = 1 - 0.94 * (p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2)
            } else {
                let p = CGFloat((t - 0.07) / 0.13)
                v = 0.06 + 0.94 * (1 - pow(1 - p, 3))
            }
            open = min(open, v)
        }
        return open
    }
}
