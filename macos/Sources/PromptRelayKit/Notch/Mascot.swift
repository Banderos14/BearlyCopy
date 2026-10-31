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

    /// Relay's own idle faces (Phase 7.1, `RelayLife`); moods win over them.
    public enum Expression: String, Equatable, Sendable {
        case none, smile, sleepy, curious
    }

    public internal(set) var mood: Mood = .idle
    public internal(set) var expression: Expression = .none
    /// A curious tilt of the whole head, in degrees (idle beats only).
    public internal(set) var roll: Double = 0
    /// Settings → Relay: Off draws a still bear (no head motion, no hops).
    public internal(set) var still = false
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

    /// Phase 7.1: the turn is drawn in the face (yaw/pitch), so the flat tilt is small.
    static let maxTilt = 3.0
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
        // The 2.5D turn moves the ears by at most ±0.06 of the size (Phase 7.1).
        let yaw = maxShift == 0 ? 0 : dx / maxShift
        for (ex, side) in [(0.05, CGFloat(-1)), (0.67, 1)] {
            let shift = MascotView.Turn(yaw: yaw, pitch: 0).earShift(side: side)
            for i in 0..<36 {
                let t = Double(i) * .pi / 18
                add(x0 + (ex + shift + 0.14) * s + 0.14 * s * cos(t), y0 + (0.17 - earLift) * s + 0.14 * s * sin(t))
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
        let calm = reduceMotion || state.still
        let eyes = calm ? CGPoint.zero : state.gaze
        let head = calm ? CGPoint.zero : state.head
        let roll = calm ? 0 : state.roll
        let expression = state.mood == .idle ? state.expression : .none
        let reaction = ReactionTrigger(cheers: state.cheers, worries: state.worries)
        KeyframeAnimator(initialValue: Reaction(), trigger: reaction) { r in
            if resting {
                // Bounded in the ear: shift, turn around the centre, lift; the
                // limit includes the hop, so a copy never reaches the screen top.
                let pose = RestingPose(head: head, mood: state.mood, lift: -r.lift)
                MascotFace(gazeX: eyes.x, gazeY: eyes.y, eyeOpen: state.isBlinking ? 0 : 1, squint: r.squint, mood: state.mood,
                           yaw: head.x * pose.k, pitch: head.y * pose.k, expression: expression)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(pose.turn + r.shake * 3 + roll * 0.5 * Double(pose.k)), anchor: .center)
                    .offset(x: pose.dx, y: pose.dy)
            } else {
                let pose = MascotPose(gaze: eyes, head: head)
                MascotFace(gazeX: pose.eyes.x, gazeY: pose.eyes.y, eyeOpen: state.isBlinking ? 0 : 1,
                           squint: r.squint, mood: state.mood, yaw: head.x, pitch: head.y, expression: expression)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(pose.tilt + r.shake * 4 + roll), anchor: .bottom)
                    .offset(x: pose.shift.width * size, y: pose.shift.height * size + r.lift)
                    .scaleEffect(r.scale, anchor: .bottom)
            }
        } keyframes: { _ in
            // Amplitudes are zero for the reaction that did not happen, and
            // for every movement under Reduce Motion (the closed eyes stay).
            // At rest the hop has no scale and at most `RestingPose.hop`.
            let hop: CGFloat = state.mood == .pleased && !reduceMotion && !state.still ? 1 : 0
            let grow: CGFloat = resting ? 0 : hop
            let lift: CGFloat = resting ? RestingPose.hop : 1.5
            let shake: CGFloat = state.mood == .concerned && !reduceMotion && !state.still ? 1 : 0
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
        .animation(calm ? nil : .easeInOut(duration: 0.45), value: state.roll)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state.expression)
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
        case .idle: return state.expression == .sleepy ? "Relay is resting" : "Relay, the Prompt Relay bear"
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
    ///
    /// Phase 7.1, the 2.5D head: `yaw` (−1 left … 1 right) and `pitch` (−1 up
    /// … 1 down) turn the head as if in space. Each layer moves by its depth
    /// (nose and muzzle most, eyes less, the head's outline a little, the
    /// ears the other way), the far eye and the far ear are foreshortened,
    /// the outline narrows slightly and the muzzle flattens with the pitch.
    /// A drawing, not a 3D model: no new artwork, the same bear.
    static func draw(in ctx: inout GraphicsContext, size: CGSize, mood: MascotState.Mood, eyeOpen: CGFloat = 1,
                     squint: CGFloat = 0, gaze: CGPoint, yaw: CGFloat = 0, pitch: CGFloat = 0,
                     expression: MascotState.Expression = .none) {
        let s = min(size.width, size.height)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        let g = CGPoint(x: max(-1, min(1, gaze.x)), y: max(-1, min(1, gaze.y)))
        let t = Turn(yaw: yaw, pitch: pitch)
        // Ears (perked a little when curious): behind the head, they move
        // against the turn; the far one shrinks and slides toward the centre.
        let earLift: CGFloat = mood == .curious || expression == .curious ? 0.025 : 0
        for (x, side) in [(0.05, CGFloat(-1)), (0.67, 1)] {
            let k = t.earScale(side: side)
            let ex = x + t.earShift(side: side), ey = 0.03 - earLift + t.earRise
            let w = 0.28 * k
            ctx.fill(Path(ellipseIn: r(ex + (0.28 - w) / 2, ey + (0.28 - w) / 2, w, w)), with: .color(fur))
            let iw = 0.14 * k
            ctx.fill(Path(ellipseIn: r(ex + (0.28 - iw) / 2, ey + 0.07 + (0.14 - iw) / 2, iw, iw)), with: .color(furDark))
        }
        // Head: narrows a touch as it turns, its centre follows a little.
        let hw = 0.82 * t.outlineScale
        ctx.fill(Path(ellipseIn: r(0.5 - hw / 2 + t.outlineShift, 0.13 + t.pitchShift(0.25), hw, 0.8)), with: .color(fur))
        // The muzzle follows the gaze a touch, and the turn most (nearest layer).
        let mx = g.x * 0.025 + t.layer(1.0), my = g.y * 0.015 + t.pitchShift(1.0)
        let mh = 0.3 * t.muzzleSquash
        ctx.fill(Path(ellipseIn: r(0.3 + mx, 0.53 + my + (0.3 - mh) / 2, 0.4 * t.outlineScale, mh)), with: .color(muzzle))
        ctx.fill(Path(ellipseIn: r(0.425 + mx * 1.15, 0.565 + my * 1.1, 0.15, 0.095 * t.muzzleSquash)), with: .color(ink))
        ctx.fill(Path(ellipseIn: r(0.46 + mx * 1.15, 0.575 + my * 1.1, 0.045, 0.03)), with: .color(.white.opacity(0.35)))

        if mood == .pleased || expression == .smile {
            let a = mood == .pleased ? 0.55 : 0.35
            for x in [0.2, 0.68] {
                ctx.fill(Path(ellipseIn: r(x + mx, 0.56 + my, 0.12, 0.07)), with: .color(blush.opacity(a)))
            }
        }

        // Eyes: round, with a highlight; they follow the gaze within the face
        // and the turn (a middle layer); the far eye is narrower.
        let dx = g.x * 0.055 + t.layer(0.7), dy = g.y * 0.04 + t.pitchShift(0.7)
        let sleepy = expression == .sleepy && mood == .idle
        let open = max(0, min(sleepy ? 0.3 : 1, eyeOpen))
        for (x, side) in [(0.335, CGFloat(-1)), (0.665, 1)] {
            let center = CGPoint(x: (x + dx + t.eyeConverge(side: side)) * s, y: (0.45 + dy) * s)
            let wide = t.eyeWidth(side: side)
            if squint > 0.5 {
                // Happy closed eyes (^ ^).
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.065 * s * wide, y: center.y + 0.025 * s))
                p.addQuadCurve(to: CGPoint(x: center.x + 0.065 * s * wide, y: center.y + 0.025 * s),
                               control: CGPoint(x: center.x, y: center.y - 0.065 * s))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.05 * s, lineCap: .round))
            } else if sleepy {
                // Heavy lids: a soft downward arc.
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.06 * s * wide, y: center.y - 0.005 * s))
                p.addQuadCurve(to: CGPoint(x: center.x + 0.06 * s * wide, y: center.y - 0.005 * s),
                               control: CGPoint(x: center.x, y: center.y + 0.04 * s))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.045 * s, lineCap: .round))
            } else if open < 0.25 {
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.06 * s * wide, y: center.y))
                p.addLine(to: CGPoint(x: center.x + 0.06 * s * wide, y: center.y))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.045 * s, lineCap: .round))
            } else {
                let e: CGFloat = mood == .curious || expression == .curious ? 0.145 : 0.125
                let h = e * open
                let w = e * wide
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - w * s / 2, y: center.y - h * s / 2, width: w * s, height: h * s)),
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
            let w: CGFloat = expression == .smile ? 0.09 : (mood == .curious || expression == .curious ? 0.05 : 0.075)
            let depth: CGFloat = expression == .smile ? 0.085 : (sleepy ? 0.03 : 0.065)
            mouth.move(to: CGPoint(x: (cx - w) * s, y: y))
            mouth.addQuadCurve(to: CGPoint(x: (cx + w) * s, y: y), control: CGPoint(x: cx * s, y: y + depth * s))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.04 * s, lineCap: .round))
        }
    }

    /// The parallax of a head turned by `yaw` and `pitch` (each −1…1).
    struct Turn {
        let yaw: CGFloat, pitch: CGFloat
        init(yaw: CGFloat, pitch: CGFloat) {
            self.yaw = max(-1, min(1, yaw)); self.pitch = max(-1, min(1, pitch))
        }
        /// Sideways shift of a face layer at `depth` (1 = the nose, nearest).
        func layer(_ depth: CGFloat) -> CGFloat { yaw * 0.085 * depth }
        func pitchShift(_ depth: CGFloat) -> CGFloat { pitch * 0.06 * depth }
        var outlineShift: CGFloat { yaw * 0.02 }
        var outlineScale: CGFloat { 1 - 0.05 * abs(yaw) }
        var muzzleSquash: CGFloat { 1 - 0.12 * abs(pitch) }
        /// Ears sit behind: they move against the turn; the far one shrinks.
        func earShift(side: CGFloat) -> CGFloat { -yaw * 0.03 + (side * yaw > 0 ? -side * 0.03 * abs(yaw) : 0) }
        func earScale(side: CGFloat) -> CGFloat { side * yaw > 0 ? 1 - 0.14 * abs(yaw) : 1 + 0.04 * abs(yaw) }
        var earRise: CGFloat { pitch * 0.02 }
        /// The far eye moves toward the centre and gets narrower.
        func eyeConverge(side: CGFloat) -> CGFloat { side * yaw > 0 ? -side * 0.025 * abs(yaw) : 0 }
        func eyeWidth(side: CGFloat) -> CGFloat { side * yaw > 0 ? 1 - 0.3 * abs(yaw) : 1 + 0.05 * abs(yaw) }
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
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var expression: MascotState.Expression = .none

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(gazeX, gazeY), eyeOpen) }
        set { gazeX = newValue.first.first; gazeY = newValue.first.second; eyeOpen = newValue.second }
    }

    var body: some View {
        Canvas { context, canvas in
            MascotView.draw(in: &context, size: canvas, mood: mood, eyeOpen: eyeOpen, squint: squint,
                            gaze: CGPoint(x: gazeX, y: gazeY), yaw: yaw, pitch: pitch, expression: expression)
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
