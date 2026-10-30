import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Prompt Relay's mascot: Relay, a small bear cub drawn in vector (SwiftUI
/// Canvas), original artwork. It sits beside the notch and at the top of the
/// open island. It reacts only to facts the app knows: an answer was
/// captured, a copy succeeded, something failed. Nothing about it says that
/// work or tests succeeded.
@MainActor
@Observable
public final class MascotState {
    public enum Mood: Equatable, Sendable {
        case idle
        /// A new answer was captured (Claude stopped; not "tests passed").
        case curious
        /// A copy succeeded.
        case pleased
        /// A copy failed or the Core is unavailable.
        case concerned
    }

    public internal(set) var mood: Mood = .idle
    public internal(set) var isBlinking = false
    /// Where Relay looks now, each axis −1…1 (y down): eased toward
    /// `gazeTarget` at 30 frames a second while they differ (see
    /// `NotchController.setGaze`). Never stored, no history.
    public internal(set) var gaze: CGPoint = .zero
    /// Where the pointer is, seen from Relay.
    public internal(set) var gazeTarget: CGPoint = .zero
    /// Where the head points, each axis −1…1: a slower, slightly springy
    /// follower of `headTarget`, so the head trails the eyes (inertia).
    public internal(set) var head: CGPoint = .zero
    public internal(set) var headTarget: CGPoint = .zero
    /// The followers' exact state. `gaze` and `head` are published only when
    /// they move by `MascotState.step` (≈ 0.07 pt, a seventh of a Retina
    /// pixel) or arrive, so Relay is not redrawn for invisible changes.
    @ObservationIgnored var gazeExact: CGPoint = .zero
    @ObservationIgnored var headExact: CGPoint = .zero
    @ObservationIgnored var headVelocity: CGPoint = .zero
    /// One unit moves the eyes ≈ 1.5 pt and the head ≈ 1.4 pt (28 pt Relay).
    static let step: CGFloat = 0.05
    #if DEBUG
    /// Frames published by the gaze followers (for the performance test).
    @ObservationIgnored var framesPublished = 0
    #endif
    /// Counts successful copies: each one plays the short happy reaction
    /// (a hop with the eyes closed).
    public internal(set) var cheers = 0
    /// Counts failed copies: each one plays a small head shake instead.
    public internal(set) var worries = 0

    public init() {}
}

/// The head in the open band: tilt from the bottom, small shift. There is
/// room above and around it.
struct MascotPose: Equatable {
    /// Eye offset, each axis −1…1.
    var eyes: CGPoint
    /// Head tilt in degrees toward the pointer.
    var tilt: Double
    /// Head shift as a fraction of the mascot's size.
    var shift: CGSize

    static let maxTilt = 6.0
    static let maxShift: CGFloat = 0.03

    init(gaze: CGPoint, head: CGPoint? = nil) {
        let g = CGPoint(x: max(-1, min(1, gaze.x)), y: max(-1, min(1, gaze.y)))
        let h = head.map { CGPoint(x: max(-1, min(1, $0.x)), y: max(-1, min(1, $0.y))) } ?? g
        eyes = g
        tilt = Double(h.x) * Self.maxTilt
        shift = CGSize(width: h.x * Self.maxShift, height: h.y * Self.maxShift * 0.75)
    }
}

/// The head beside the camera (R8, PHASE5_PROPOSAL §7.1). The ear is 38 ×
/// 32 pt; its visible side is 6 pt in from the window edge (the outline's
/// top flare) and the camera housing starts at 38 pt. Relay (28 pt) sits at
/// x = 8 so it has 3.4 pt on both sides. The head shifts up to ±1.4 pt,
/// turns up to ±4° around its centre and moves 0.8 pt up / 1 pt down. Before
/// a pose is drawn, its silhouette (ears and head) is checked against a safe
/// area 1 pt inside the outline, the housing and the top of the screen; if
/// it would leave it, shift, turn and lift shrink together by a factor `k`.
/// The head never stops moving; the worst case computed is k ≈ 0.54.
struct RestingPose: Equatable {
    static let size: CGFloat = 28
    static let origin = CGPoint(x: 8, y: 2)
    static let maxShift: CGFloat = 1.4
    static let maxTurn = 4.0
    static let up: CGFloat = 0.8
    static let down: CGFloat = 1.0
    /// Breathing scales the height from the bottom by at most this.
    static let breath: CGFloat = 1.015
    /// The copy hop at rest (no scale: it would reach the top of the screen).
    static let hop: CGFloat = 1.5
    /// 1 pt inside the visible outline (x ≥ 6), the housing (x < 38), the
    /// top of the screen and the bottom of the ear (32).
    static let safe = CGRect(x: 7, y: 1, width: 30, height: 30)

    var dx: CGFloat
    var dy: CGFloat
    var turn: Double
    /// How much of the budget was usable (1 = all).
    var k: CGFloat

    init(head: CGPoint, mood: MascotState.Mood, lift: CGFloat = 0) {
        let h = CGPoint(x: max(-1, min(1, head.x)), y: max(-1, min(1, head.y)))
        let base = (dx: Self.maxShift * h.x, dy: h.y < 0 ? Self.up * h.y : Self.down * h.y, turn: Self.maxTurn * Double(h.x))
        func pose(_ k: CGFloat) -> (CGFloat, CGFloat, Double, CGFloat) { (base.dx * k, base.dy * k, base.turn * Double(k), lift * k) }
        let ears = mood == .curious ? 0.025 : 0
        var k: CGFloat = 1
        if !Self.fits(pose(1), earLift: ears) {
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<8 {
                let mid = (lo + hi) / 2
                if Self.fits(pose(mid), earLift: ears) { lo = mid } else { hi = mid }
            }
            k = lo
        }
        let p = pose(k)
        dx = p.0; dy = p.1 - p.3; turn = p.2; self.k = k
    }

    /// Points on the outline of both ears and the head (36 each), in ear
    /// coordinates (y down), for a pose at the breathing peak.
    static func silhouette(dx: CGFloat, dy: CGFloat, turn: Double, lift: CGFloat, earLift: Double) -> [CGPoint] {
        let s = size, x0 = origin.x, y0 = origin.y
        let cx = x0 + s / 2, cy = y0 + s / 2, by = y0 + s
        let a = turn * .pi / 180
        var out: [CGPoint] = []
        func add(_ x: CGFloat, _ y: CGFloat) {
            let y1 = by + (y - by) * breath   // breathing scales from the frame's bottom
            let rx = cx + (x - cx) * cos(a) - (y1 - cy) * sin(a)
            let ry = cy + (x - cx) * sin(a) + (y1 - cy) * cos(a)
            out.append(CGPoint(x: rx + dx, y: ry + dy - lift))
        }
        for ex in [0.05, 0.67] {
            for i in 0..<36 {
                let t = Double(i) * .pi / 18
                add(x0 + (ex + 0.14) * s + 0.14 * s * cos(t), y0 + (0.17 - earLift) * s + 0.14 * s * sin(t))
            }
        }
        for i in 0..<36 {
            let t = Double(i) * .pi / 18
            add(x0 + 0.5 * s + 0.41 * s * cos(t), y0 + 0.53 * s + 0.4 * s * sin(t))
        }
        return out
    }

    static func fits(_ p: (CGFloat, CGFloat, Double, CGFloat), earLift: Double) -> Bool {
        silhouette(dx: p.0, dy: p.1, turn: p.2, lift: p.3, earLift: earLift).allSatisfy {
            $0.x >= safe.minX && $0.x <= safe.maxX && $0.y >= safe.minY && $0.y <= safe.maxY
        }
    }
}

struct MascotView: View {
    let state: MascotState
    var size: CGFloat = MascotView.preferredSize
    var reduceMotion = false
    /// Beside the camera: the bounded resting pose (R8) and a hop without scale.
    var resting = false

    /// Beside the camera housing (resting ear) and in the island's band: as
    /// large as the housing's height allows, 2 pt clear above and below.
    static let preferredSize: CGFloat = 28
    static func size(notchHeight: CGFloat) -> CGFloat { min(preferredSize, max(16, notchHeight - 4)) }

    var body: some View {
        let eyes = reduceMotion ? CGPoint.zero : state.gaze
        let head = reduceMotion ? CGPoint.zero : state.head
        let reaction = ReactionTrigger(cheers: state.cheers, worries: state.worries)
        KeyframeAnimator(initialValue: Reaction(), trigger: reaction) { r in
            if resting {
                // Bounded in the ear: shift, turn around the centre, lift; the
                // limit includes the hop, so a copy never reaches the screen top.
                let pose = RestingPose(head: head, mood: state.mood, lift: -r.lift)
                MascotFace(gazeX: eyes.x, gazeY: eyes.y, eyeOpen: state.isBlinking ? 0 : 1, squint: r.squint, mood: state.mood)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(pose.turn + r.shake * 3), anchor: .center)
                    .offset(x: pose.dx, y: pose.dy)
            } else {
                let pose = MascotPose(gaze: eyes, head: head)
                MascotFace(gazeX: pose.eyes.x, gazeY: pose.eyes.y, eyeOpen: state.isBlinking ? 0 : 1,
                           squint: r.squint, mood: state.mood)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(pose.tilt + r.shake * 4), anchor: .bottom)
                    .offset(x: pose.shift.width * size, y: pose.shift.height * size + r.lift)
                    .scaleEffect(r.scale, anchor: .bottom)
            }
        } keyframes: { _ in
            // Amplitudes are zero for the reaction that did not happen, and
            // for every movement under Reduce Motion (the closed eyes stay).
            // At rest the hop has no scale and at most `RestingPose.hop`.
            let hop: CGFloat = state.mood == .pleased && !reduceMotion ? 1 : 0
            let grow: CGFloat = resting ? 0 : hop
            let lift: CGFloat = resting ? RestingPose.hop : 1.5
            let shake: CGFloat = state.mood == .concerned && !reduceMotion ? 1 : 0
            let squint: CGFloat = state.mood == .pleased ? 1 : 0
            KeyframeTrack(\.scale) {
                SpringKeyframe(1 + 0.08 * grow, duration: 0.14)
                SpringKeyframe(1 - 0.03 * grow, duration: 0.14)
                SpringKeyframe(1, duration: 0.22)
            }
            KeyframeTrack(\.lift) {
                CubicKeyframe(-lift * hop, duration: 0.14)
                CubicKeyframe(0, duration: 0.3)
            }
            KeyframeTrack(\.shake) {
                LinearKeyframe(-1 * shake, duration: 0.07)
                LinearKeyframe(1 * shake, duration: 0.1)
                LinearKeyframe(-0.6 * shake, duration: 0.09)
                LinearKeyframe(0, duration: 0.09)
            }
            KeyframeTrack(\.squint) {
                LinearKeyframe(squint, duration: 0.06)
                LinearKeyframe(squint, duration: 0.8)
                LinearKeyframe(0, duration: 0.12)
            }
        }
        // No SwiftUI animation on the gaze: it is eased at 30 fps by the
        // controller and only while moving (a spring here redrew the panel
        // at the display's full rate, ≈ 23 % CPU while the pointer moved).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.07), value: state.isBlinking)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.mood)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private struct ReactionTrigger: Equatable { var cheers: Int; var worries: Int }

    struct Reaction {
        var scale: CGFloat = 1
        var lift: CGFloat = 0
        var shake: Double = 0
        /// 1: the happy closed eyes (^ ^).
        var squint: CGFloat = 0
    }

    private var label: String {
        switch state.mood {
        case .idle: return "Relay, the Prompt Relay bear"
        case .curious: return "Relay: a new answer was captured"
        case .pleased: return "Relay: copied"
        case .concerned: return "Relay: something needs attention"
        }
    }

    static let fur = Color(red: 0.80, green: 0.62, blue: 0.45)
    static let furDark = Color(red: 0.62, green: 0.45, blue: 0.31)
    static let muzzle = Color(red: 0.95, green: 0.86, blue: 0.74)
    static let ink = Color(red: 0.11, green: 0.08, blue: 0.07)
    static let blush = Color(red: 0.96, green: 0.52, blue: 0.50)

    /// The face for one frame. `eyeOpen` 0…1 (a blink), `squint` 0…1 (the
    /// happy closed eyes); `gaze` moves the eyes within the face.
    static func draw(in ctx: inout GraphicsContext, size: CGSize, mood: MascotState.Mood, eyeOpen: CGFloat = 1,
                     squint: CGFloat = 0, gaze: CGPoint) {
        let s = min(size.width, size.height)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        let g = CGPoint(x: max(-1, min(1, gaze.x)), y: max(-1, min(1, gaze.y)))
        // Ears (perked a little when curious), head, muzzle, nose.
        let earLift: CGFloat = mood == .curious ? 0.025 : 0
        for x in [0.05, 0.67] {
            ctx.fill(Path(ellipseIn: r(x, 0.03 - earLift, 0.28, 0.28)), with: .color(fur))
            ctx.fill(Path(ellipseIn: r(x + 0.07, 0.10 - earLift, 0.14, 0.14)), with: .color(furDark))
        }
        ctx.fill(Path(ellipseIn: r(0.09, 0.13, 0.82, 0.8)), with: .color(fur))
        // The muzzle follows the gaze a touch less than the eyes: the face turns.
        let mx = g.x * 0.025, my = g.y * 0.015
        ctx.fill(Path(ellipseIn: r(0.3 + mx, 0.53 + my, 0.4, 0.3)), with: .color(muzzle))
        ctx.fill(Path(ellipseIn: r(0.425 + mx, 0.565 + my, 0.15, 0.095)), with: .color(ink))
        ctx.fill(Path(ellipseIn: r(0.46 + mx, 0.575 + my, 0.045, 0.03)), with: .color(.white.opacity(0.35)))

        if mood == .pleased {
            for x in [0.2, 0.68] {
                ctx.fill(Path(ellipseIn: r(x + mx, 0.56 + my, 0.12, 0.07)), with: .color(blush.opacity(0.55)))
            }
        }

        // Eyes: round, with a highlight; they follow the gaze within the face.
        let dx = g.x * 0.055, dy = g.y * 0.04
        let open = max(0, min(1, eyeOpen))
        for x in [0.335, 0.665] {
            let center = CGPoint(x: (x + dx) * s, y: (0.45 + dy) * s)
            if squint > 0.5 {
                // Happy closed eyes (^ ^).
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.065 * s, y: center.y + 0.025 * s))
                p.addQuadCurve(to: CGPoint(x: center.x + 0.065 * s, y: center.y + 0.025 * s),
                               control: CGPoint(x: center.x, y: center.y - 0.065 * s))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.05 * s, lineCap: .round))
            } else if open < 0.25 {
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.06 * s, y: center.y))
                p.addLine(to: CGPoint(x: center.x + 0.06 * s, y: center.y))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.045 * s, lineCap: .round))
            } else {
                let e: CGFloat = mood == .curious ? 0.145 : 0.125
                let h = e * open
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - e * s / 2, y: center.y - h * s / 2, width: e * s, height: h * s)),
                         with: .color(ink))
                if open > 0.6 {
                    // The highlight shifts with the gaze, so the eyes read as turning.
                    let hx = center.x - 0.015 * s + g.x * 0.012 * s, hy = center.y - 0.045 * s
                    ctx.fill(Path(ellipseIn: CGRect(x: hx, y: hy, width: 0.045 * s, height: 0.045 * s)),
                             with: .color(.white.opacity(0.92)))
                }
            }
        }
        // Brows only when concerned: inner ends raised (worried, not angry), no red.
        if mood == .concerned {
            for (x, dir) in [(0.335, 1.0), (0.665, -1.0)] {
                var p = Path()
                p.move(to: CGPoint(x: (x - 0.075 + dx) * s, y: (0.31 + 0.025 * dir) * s))
                p.addLine(to: CGPoint(x: (x + 0.075 + dx) * s, y: (0.31 - 0.025 * dir) * s))
                ctx.stroke(p, with: .color(furDark), style: StrokeStyle(lineWidth: 0.05 * s, lineCap: .round))
            }
        }
        // Mouth: a small smile, an open happy one when pleased, a flat line when concerned.
        let y = (0.725 + my) * s, cx = 0.5 + mx
        var mouth = Path()
        switch mood {
        case .pleased:
            mouth.move(to: CGPoint(x: (cx - 0.1) * s, y: y - 0.01 * s))
            mouth.addQuadCurve(to: CGPoint(x: (cx + 0.1) * s, y: y - 0.01 * s), control: CGPoint(x: cx * s, y: y + 0.11 * s))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(ink))
        case .concerned:
            mouth.move(to: CGPoint(x: (cx - 0.06) * s, y: y + 0.01 * s))
            mouth.addLine(to: CGPoint(x: (cx + 0.06) * s, y: y + 0.01 * s))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.04 * s, lineCap: .round))
        default:
            let w: CGFloat = mood == .curious ? 0.05 : 0.075
            mouth.move(to: CGPoint(x: (cx - w) * s, y: y))
            mouth.addQuadCurve(to: CGPoint(x: (cx + w) * s, y: y), control: CGPoint(x: cx * s, y: y + 0.065 * s))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.04 * s, lineCap: .round))
        }
    }
}

/// The face, interpolated frame by frame: gaze, blink and squint animate
/// smoothly instead of jumping between pointer events.
struct MascotFace: View, Animatable {
    var gazeX: CGFloat
    var gazeY: CGFloat
    var eyeOpen: CGFloat
    var squint: CGFloat
    let mood: MascotState.Mood

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(gazeX, gazeY), eyeOpen) }
        set { gazeX = newValue.first.first; gazeY = newValue.first.second; eyeOpen = newValue.second }
    }

    var body: some View {
        Canvas { context, canvas in
            MascotView.draw(in: &context, size: canvas, mood: mood, eyeOpen: eyeOpen, squint: squint,
                            gaze: CGPoint(x: gazeX, y: gazeY))
        }
    }
}

/// Breathing on the render server: a slow, repeating Core Animation scale of
/// the layer that holds Relay (≤ 1.5 % of its height, from the bottom). The
/// panel is not redrawn for it and the app's CPU stays idle; nothing runs
/// under Reduce Motion or while it is hidden.
struct Breathing<Content: View>: NSViewRepresentable {
    let active: Bool
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> BreathingHost<Content> {
        BreathingHost(rootView: content)
    }

    func updateNSView(_ view: BreathingHost<Content>, context: Context) {
        view.hosting.rootView = content
        view.setBreathing(active)
    }
}

final class BreathingHost<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    private(set) var isBreathing = false
    static var key: String { "relay.breathing" }

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        hosting.wantsLayer = true
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { nil }

    /// No size of its own: the caller gives it a fixed frame. Asking the
    /// hosted view for its fitting size ran a SwiftUI layout pass on every
    /// update while the pointer moved (Phase 5.11 profile).
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        // AppKit keeps the layer's anchor at (0, 0): its bottom edge (y up),
        // which is where breathing scales from.
        hosting.frame = bounds
    }

    func setBreathing(_ on: Bool) {
        guard on != isBreathing, let layer = hosting.layer else { return }
        isBreathing = on
        if on {
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 1.0
            breathe.toValue = RestingPose.breath
            breathe.duration = 2.25
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(breathe, forKey: Self.key)
        } else {
            layer.removeAnimation(forKey: Self.key)
        }
    }
}
