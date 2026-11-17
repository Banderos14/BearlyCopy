import AppKit
import Observation
import QuartzCore
import SwiftUI

/// BearlyCopy's mascot: Relay, a small bear cub drawn in vector (SwiftUI
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
    /// Phase 7.2: the motion engine, stepped by the layer view's display
    /// link while `animating`; not observed, so moving it never re-runs
    /// SwiftUI. `animating`: a frame clock is running now.
    @ObservationIgnored let motion = RelayMotion()
    public internal(set) var animating = false
    /// Where Relay looks and points its head now (read from the engine).
    public var gaze: CGPoint {
        get { motion.gaze }
        set { motion.place(gaze: newValue, head: motion.head) }
    }
    public var head: CGPoint {
        get { motion.head }
        set { motion.place(gaze: motion.gaze, head: newValue) }
    }
    /// Frames drawn (for the frame-pacing check; Release too).
    @ObservationIgnored var framesDrawn = 0

    /// The layer views drawing this Relay (the resting ear, the open band).
    @ObservationIgnored private var views = NSHashTable<RelayLayerView>.weakObjects()

    func attach(_ view: RelayLayerView) { views.add(view) }

    /// Starts the frame clock of every view showing Relay, if the engine has
    /// something to do. Without a view on screen nothing runs.
    func wake() {
        for view in views.allObjects { view.wake() }
    }

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
        shift = CGSize(width: h.x * Self.maxShift, height: h.y * Self.maxShift)   // Phase 8: full nod (was 0.75)
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

    /// Breathing (resting only): a render-server animation, no frames drawn.
    var breathes = false

    /// Phase 7.2: Relay is Core Animation shape layers updated once per
    /// display frame by `NSView.displayLink` while it moves, and paused when
    /// it rests. SwiftUI only passes the facts (mood, face, settings) down:
    /// a TimelineView + Canvas re-ran SwiftUI every frame (13–17 % CPU at 60
    /// fps in an optimized probe; ≈ 88 % in the Debug test), the layers cost
    /// ≈ 2 % (probe). The drawing is the same `MascotView.shapes`.
    var body: some View {
        RelayLayerRepresentable(state: state, size: size, reduceMotion: reduceMotion, resting: resting, breathes: breathes,
                                facts: .init(mood: state.mood, expression: state.mood == .idle ? state.expression : .none,
                                             roll: state.roll, still: state.still, cheers: state.cheers, worries: state.worries))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(label)
    }

    private var label: String {
        switch state.mood {
        case .idle: return state.expression == .sleepy ? "Relay is resting" : "Relay, the BearlyCopy bear"
        case .curious: return "Relay: a new answer was captured"
        case .pleased: return "Relay: copied"
        case .concerned: return "Relay: something needs attention"
        }
    }

    static let fur = CGColor(srgbRed: 0.80, green: 0.62, blue: 0.45, alpha: 1)
    static let furDark = CGColor(srgbRed: 0.62, green: 0.45, blue: 0.31, alpha: 1)
    static let muzzle = CGColor(srgbRed: 0.95, green: 0.86, blue: 0.74, alpha: 1)
    static let ink = CGColor(srgbRed: 0.11, green: 0.08, blue: 0.07, alpha: 1)
    static let blush = CGColor(srgbRed: 0.96, green: 0.52, blue: 0.50, alpha: 1)

    /// The face for one frame. `eyeOpen` 0…1 (a blink), `squint` 0…1 (the
    /// happy closed eyes); `gaze` moves the eyes within the face.
    ///
    /// Phase 7.1, the 2.5D head: `yaw` (−1 left … 1 right) and `pitch` (−1 up
    /// … 1 down) turn the head as if in space. Each layer moves by its depth
    /// (nose and muzzle most, eyes less, the head's outline a little, the
    /// ears the other way), the far eye and the far ear are foreshortened,
    /// the outline narrows slightly and the muzzle flattens with the pitch.
    /// A drawing, not a 3D model: no new artwork, the same bear.
    static func shapes(size: CGSize, mood: MascotState.Mood, eyeOpen: CGFloat = 1,
                     squint: CGFloat = 0, gaze: CGPoint, yaw: CGFloat = 0, pitch: CGFloat = 0,
                     expression: MascotState.Expression = .none, amounts: RelayMotion.Amounts? = nil,
                     earLag: CGFloat = 0) -> [RelayShape] {
        var out = RelayShapes()
        // Phase 7.2: faces are amounts 0…1 that blend frame by frame; a
        // still picture (the renders) maps the expression to full amounts.
        let a = amounts ?? RelayMotion.Amounts(smile: expression == .smile ? 1 : 0, sleepy: expression == .sleepy ? 1 : 0,
                                               curious: expression == .curious ? 1 : 0)
        let curiousness = max(mood == .curious ? 1 : 0, a.curious)
        let sleepiness = mood == .idle ? a.sleepy : 0
        let s = min(size.width, size.height)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        let g = CGPoint(x: max(-1, min(1, gaze.x)), y: max(-1, min(1, gaze.y)))
        let t = Turn(yaw: yaw, pitch: pitch)
        // Ears (perked a little when curious): behind the head, they move
        // against the turn; the far one shrinks and slides toward the centre.
        let earLift: CGFloat = 0.025 * curiousness
        for (x, side) in [(0.05, CGFloat(-1)), (0.67, 1)] {
            let k = t.earScale(side: side)
            // Ear inertia: they swing a little behind a fast turn, then settle.
            let ex = x + t.earShift(side: side) + earLag * 0.035, ey = 0.03 - earLift + t.earRise + abs(earLag) * 0.01
            let w = 0.28 * k
            out.fill(ellipse: r(ex + (0.28 - w) / 2, ey + (0.28 - w) / 2, w, w), fur)
            let iw = 0.14 * k
            out.fill(ellipse: r(ex + (0.28 - iw) / 2, ey + 0.07 + (0.14 - iw) / 2, iw, iw), furDark)
        }
        // Head: narrows a touch as it turns, its centre follows a little.
        let hw = 0.82 * t.outlineScale
        out.fill(ellipse: r(0.5 - hw / 2 + t.outlineShift, 0.13 + t.pitchShift(0.25), hw, 0.8), fur)
        // The muzzle follows the gaze a touch, and the turn most (nearest layer).
        let mx = g.x * 0.025 + t.layer(1.0), my = g.y * 0.015 + t.pitchShift(1.0)
        let mh = 0.3 * t.muzzleSquash
        out.fill(ellipse: r(0.3 + mx, 0.53 + my + (0.3 - mh) / 2, 0.4 * t.outlineScale, mh), muzzle)
        out.fill(ellipse: r(0.425 + mx * 1.15, 0.565 + my * 1.1, 0.15, 0.095 * t.muzzleSquash), ink)
        out.fill(ellipse: r(0.46 + mx * 1.15, 0.575 + my * 1.1, 0.045, 0.03), CGColor(gray: 1, alpha: 0.35))

        let blushAlpha = mood == .pleased ? 0.55 : 0.35 * Double(a.smile)
        if blushAlpha > 0.02 {
            for x in [0.2, 0.68] {
                out.fill(ellipse: r(x + mx, 0.56 + my, 0.12, 0.07), blush.copy(alpha: CGFloat(blushAlpha))!)
            }
        }

        // Eyes: round, with a highlight; they follow the gaze within the face
        // and the turn (a middle layer); the far eye is narrower.
        let dx = g.x * 0.055 + t.layer(0.7), dy = g.y * 0.055 + t.pitchShift(0.7)
        // Heavy lids close gradually; past 80 % they become the soft arc.
        let sleepy = sleepiness > 0.8
        let open = max(0, min(1 - 0.7 * sleepiness, eyeOpen))
        for (x, side) in [(0.335, CGFloat(-1)), (0.665, 1)] {
            let center = CGPoint(x: (x + dx + t.eyeConverge(side: side)) * s, y: (0.45 + dy) * s)
            let wide = t.eyeWidth(side: side)
            if squint > 0.5 {
                // Happy closed eyes (^ ^).
                let p = CGMutablePath()
                p.move(to: CGPoint(x: center.x - 0.065 * s * wide, y: center.y + 0.025 * s))
                p.addQuadCurve(to: CGPoint(x: center.x + 0.065 * s * wide, y: center.y + 0.025 * s),
                               control: CGPoint(x: center.x, y: center.y - 0.065 * s))
                out.stroke(p, ink, width: 0.05 * s)
            } else if sleepy {
                // Heavy lids: a soft downward arc.
                let p = CGMutablePath()
                p.move(to: CGPoint(x: center.x - 0.06 * s * wide, y: center.y - 0.005 * s))
                p.addQuadCurve(to: CGPoint(x: center.x + 0.06 * s * wide, y: center.y - 0.005 * s),
                               control: CGPoint(x: center.x, y: center.y + 0.04 * s))
                out.stroke(p, ink, width: 0.045 * s)
            } else if open < 0.25 {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: center.x - 0.06 * s * wide, y: center.y))
                p.addLine(to: CGPoint(x: center.x + 0.06 * s * wide, y: center.y))
                out.stroke(p, ink, width: 0.045 * s)
            } else {
                let e: CGFloat = 0.125 + 0.02 * curiousness
                let h = e * open * t.eyeFlatten
                let w = e * wide
                out.fill(ellipse: CGRect(x: center.x - w * s / 2, y: center.y - h * s / 2, width: w * s, height: h * s), ink)
                if open > 0.6 {
                    // The highlight shifts with the gaze, so the eyes read as turning.
                    let hx = center.x - 0.015 * s + g.x * 0.012 * s, hy = center.y - 0.045 * s + g.y * 0.01 * s
                    out.fill(ellipse: CGRect(x: hx, y: hy, width: 0.045 * s, height: 0.045 * s), CGColor(gray: 1, alpha: 0.92))
                }
            }
        }
        // Brows only when concerned: inner ends raised (worried, not angry), no red.
        if mood == .concerned {
            for (x, dir) in [(0.335, 1.0), (0.665, -1.0)] {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: (x - 0.075 + dx) * s, y: (0.31 + 0.025 * dir) * s))
                p.addLine(to: CGPoint(x: (x + 0.075 + dx) * s, y: (0.31 - 0.025 * dir) * s))
                out.stroke(p, furDark, width: 0.05 * s)
            }
        }
        // Mouth: a small smile, an open happy one when pleased, a flat line when concerned.
        let y = (0.725 + my) * s, cx = 0.5 + mx
        let mouth = CGMutablePath()
        switch mood {
        case .pleased:
            mouth.move(to: CGPoint(x: (cx - 0.1) * s, y: y - 0.01 * s))
            mouth.addQuadCurve(to: CGPoint(x: (cx + 0.1) * s, y: y - 0.01 * s), control: CGPoint(x: cx * s, y: y + 0.11 * s))
            mouth.closeSubpath()
            out.fill(path: mouth, ink)
        case .concerned:
            mouth.move(to: CGPoint(x: (cx - 0.06) * s, y: y + 0.01 * s))
            mouth.addLine(to: CGPoint(x: (cx + 0.06) * s, y: y + 0.01 * s))
            out.stroke(mouth, ink, width: 0.04 * s)
        default:
            let w: CGFloat = 0.075 + 0.015 * a.smile - 0.025 * curiousness
            let depth: CGFloat = 0.065 + 0.02 * a.smile - 0.035 * sleepiness
            mouth.move(to: CGPoint(x: (cx - w) * s, y: y))
            mouth.addQuadCurve(to: CGPoint(x: (cx + w) * s, y: y), control: CGPoint(x: cx * s, y: y + depth * s))
            out.stroke(mouth, ink, width: 0.04 * s)
        }
        return out.list
    }

    /// The same face into a SwiftUI Canvas (renders, previews, tests).
    static func draw(in ctx: inout GraphicsContext, size: CGSize, mood: MascotState.Mood, eyeOpen: CGFloat = 1,
                     squint: CGFloat = 0, gaze: CGPoint, yaw: CGFloat = 0, pitch: CGFloat = 0,
                     expression: MascotState.Expression = .none, amounts: RelayMotion.Amounts? = nil,
                     earLag: CGFloat = 0) {
        for shape in shapes(size: size, mood: mood, eyeOpen: eyeOpen, squint: squint, gaze: gaze, yaw: yaw, pitch: pitch,
                            expression: expression, amounts: amounts, earLag: earLag) {
            let path = Path(shape.path)
            if let width = shape.lineWidth {
                ctx.stroke(path, with: .color(Color(cgColor: shape.color)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            } else {
                ctx.fill(path, with: .color(Color(cgColor: shape.color)))
            }
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
        /// Phase 8: 0.085 (was 0.06): up and down read as clearly as left and right.
        func pitchShift(_ depth: CGFloat) -> CGFloat { pitch * 0.085 * depth }
        var outlineShift: CGFloat { yaw * 0.02 }
        var outlineScale: CGFloat { 1 - 0.05 * abs(yaw) }
        var muzzleSquash: CGFloat { 1 - 0.16 * abs(pitch) }
        /// Ears sit behind: they move against the turn; the far one shrinks.
        func earShift(side: CGFloat) -> CGFloat { -yaw * 0.03 + (side * yaw > 0 ? -side * 0.03 * abs(yaw) : 0) }
        func earScale(side: CGFloat) -> CGFloat { side * yaw > 0 ? 1 - 0.14 * abs(yaw) : 1 + 0.04 * abs(yaw) }
        /// Phase 8: the ears sit behind the face, so they move against the
        /// pitch: looking up they drop back as the face rises. Looking down
        /// only the face drops away; the ears never rise (in the notch ear
        /// there is no room above them — the top of the screen).
        var earRise: CGFloat { max(0, -pitch) * 0.025 }
        /// Eyes seen from above or below look a little flatter.
        var eyeFlatten: CGFloat { 1 - 0.1 * abs(pitch) }
        /// The far eye moves toward the centre and gets narrower.
        func eyeConverge(side: CGFloat) -> CGFloat { side * yaw > 0 ? -side * 0.025 * abs(yaw) : 0 }
        func eyeWidth(side: CGFloat) -> CGFloat { side * yaw > 0 ? 1 - 0.3 * abs(yaw) : 1 + 0.05 * abs(yaw) }
    }
}

/// One filled or stroked part of Relay's face.
struct RelayShape {
    let path: CGPath
    let color: CGColor
    /// nil: filled; else stroked with round caps.
    let lineWidth: CGFloat?
}

struct RelayShapes {
    private(set) var list: [RelayShape] = []
    mutating func fill(ellipse rect: CGRect, _ color: CGColor) {
        list.append(RelayShape(path: CGPath(ellipseIn: rect, transform: nil), color: color, lineWidth: nil))
    }
    mutating func fill(path: CGPath, _ color: CGColor) { list.append(RelayShape(path: path, color: color, lineWidth: nil)) }
    mutating func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
        list.append(RelayShape(path: path, color: color, lineWidth: width))
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
    var amounts: RelayMotion.Amounts? = nil
    var earLag: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(gazeX, gazeY), eyeOpen) }
        set { gazeX = newValue.first.first; gazeY = newValue.first.second; eyeOpen = newValue.second }
    }

    var body: some View {
        Canvas { context, canvas in
            MascotView.draw(in: &context, size: canvas, mood: mood, eyeOpen: eyeOpen, squint: squint,
                            gaze: CGPoint(x: gazeX, y: gazeY), yaw: yaw, pitch: pitch, expression: expression,
                            amounts: amounts, earLag: earLag)
        }
    }
}

/// What SwiftUI passes to Relay's layers; a change redraws one frame (or
/// starts a reaction), nothing else.
struct RelayFacts: Equatable {
    var mood: MascotState.Mood
    var expression: MascotState.Expression
    var roll: Double
    var still: Bool
    var cheers: Int
    var worries: Int
}

struct RelayLayerRepresentable: NSViewRepresentable {
    let state: MascotState
    let size: CGFloat
    let reduceMotion: Bool
    let resting: Bool
    let breathes: Bool
    let facts: RelayFacts

    func makeNSView(context: Context) -> RelayLayerView {
        let view = RelayLayerView(state: state)
        view.configure(size: size, reduceMotion: reduceMotion, resting: resting, facts: facts)
        view.setBreathing(breathes && !reduceMotion)
        return view
    }

    func updateNSView(_ view: RelayLayerView, context: Context) {
        view.configure(size: size, reduceMotion: reduceMotion, resting: resting, facts: facts)
        view.setBreathing(breathes && !reduceMotion)
    }
}

/// Relay as Core Animation layers. `displayLink` (the system frame clock,
/// aligned to the display's refresh) steps the motion engine while it
/// moves, asking for about 60 fps (also on ProMotion); once settled the link
/// is paused, so a resting Relay costs nothing but breathing on the render
/// server. Layer changes are committed without implicit animations.
@MainActor
final class RelayLayerView: NSView {
    let state: MascotState
    private let breathLayer = CALayer()
    private let face = CALayer()
    private var pool: [CAShapeLayer] = []
    private var link: CADisplayLink?
    private var size: CGFloat = MascotView.preferredSize
    private var reduceMotion = false
    private var resting = false
    private var facts: RelayFacts?
    private(set) var isBreathing = false
    static let breathKey = "relay.breathing"
    /// The link is running (Relay moves).
    var isAnimating: Bool { link.map { !$0.isPaused } ?? false }

    init(state: MascotState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        // Breathing scales from the bottom: AppKit keeps this layer's anchor
        // at (0, 0), its bottom edge (y up).
        breathLayer.anchorPoint = .zero
        face.anchorPoint = .zero
        face.isGeometryFlipped = true   // the drawing is y-down
        layer?.addSublayer(breathLayer)
        breathLayer.addSublayer(face)
        state.attach(self)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        breathLayer.frame = bounds
        face.bounds = CGRect(origin: .zero, size: bounds.size)
        face.position = .zero
        CATransaction.commit()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { link?.invalidate(); link = nil } else { render(); wake() }
    }

    func configure(size: CGFloat, reduceMotion: Bool, resting: Bool, facts: RelayFacts) {
        let old = self.facts
        self.size = size; self.reduceMotion = reduceMotion; self.resting = resting
        self.facts = facts
        let motion = state.motion
        let calm = reduceMotion || facts.still
        if let old {
            if facts.cheers != old.cheers, facts.mood == .pleased, !calm { motion.react(.cheer) }
            if facts.worries != old.worries, facts.mood == .concerned, !calm { motion.react(.worry) }
        }
        motion.setRoll(calm ? 0 : facts.roll)
        if calm { motion.reset() }
        render()
        wake()
    }

    /// Starts the frame clock if the engine has something to do.
    func wake() {
        guard window != nil else { return }
        guard !state.motion.isSettled else { link?.isPaused = true; return }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(step(_:)))
            // About 60 fps on any display: on ProMotion one frame in two, which
            // halves the work; the motion is time-based, so its speed is the same.
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
        if !state.animating { state.animating = true }
    }

    @objc private func step(_ link: CADisplayLink) {
        render(at: RelayMotion.clock())
        if state.motion.isSettled {
            link.isPaused = true
            if state.animating { state.animating = false }
        }
    }

    /// Draws the frame for `now` into the layers.
    func render(at now: TimeInterval = RelayMotion.clock()) {
        guard let facts, bounds.width > 0 else { return }
        let f = state.motion.frame(at: now)
        state.framesDrawn += 1
        let calm = reduceMotion || facts.still
        let eyes = calm ? CGPoint.zero : f.gaze
        let head = calm ? CGPoint.zero : CGPoint(x: f.head.x, y: f.head.y + f.nod)
        let s = bounds.width
        var transform = CGAffineTransform.identity
        let shapes: [RelayShape]
        if resting {
            // Bounded in the ear: shift, turn around the centre, lift; the
            // limit includes the hop, so a copy never reaches the screen top.
            let pose = RestingPose(head: head, mood: facts.mood, lift: -f.lift * RestingPose.hop)
            shapes = MascotView.shapes(size: CGSize(width: s, height: s), mood: facts.mood, eyeOpen: f.eyeOpen,
                                       squint: f.squint, gaze: eyes, yaw: head.x * pose.k, pitch: head.y * pose.k,
                                       expression: facts.expression, amounts: f.amounts, earLag: calm ? 0 : f.earLag * pose.k)
            let angle = (pose.turn + f.shake * 3 + f.roll * 0.5 * Double(pose.k)) * .pi / 180
            transform = transform.translatedBy(x: pose.dx + s / 2, y: pose.dy + s / 2).rotated(by: angle).translatedBy(x: -s / 2, y: -s / 2)
        } else {
            let pose = MascotPose(gaze: eyes, head: head)
            shapes = MascotView.shapes(size: CGSize(width: s, height: s), mood: facts.mood, eyeOpen: f.eyeOpen,
                                       squint: f.squint, gaze: pose.eyes, yaw: head.x, pitch: head.y,
                                       expression: facts.expression, amounts: f.amounts, earLag: calm ? 0 : f.earLag)
            let angle = (pose.tilt + f.shake * 4 + f.roll) * .pi / 180
            let grow = resting ? 1 : f.scale
            // Rotate and scale around the bottom centre, then shift and lift.
            transform = transform
                .translatedBy(x: pose.shift.width * s + s / 2, y: pose.shift.height * s - f.lift * 1.5 + s)
                .rotated(by: angle).scaledBy(x: grow, y: grow)
                .translatedBy(x: -s / 2, y: -s)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while pool.count < shapes.count {
            let l = CAShapeLayer()
            l.lineCap = .round
            face.addSublayer(l)
            pool.append(l)
        }
        for (i, layer) in pool.enumerated() {
            guard i < shapes.count else { layer.isHidden = true; continue }
            let shape = shapes[i]
            layer.isHidden = false
            layer.path = shape.path
            if let width = shape.lineWidth {
                layer.fillColor = nil; layer.strokeColor = shape.color; layer.lineWidth = width
            } else {
                layer.fillColor = shape.color; layer.strokeColor = nil
            }
        }
        face.setAffineTransform(transform)
        CATransaction.commit()
    }

    func setBreathing(_ on: Bool) {
        guard on != isBreathing else { return }
        isBreathing = on
        if on {
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 1.0
            breathe.toValue = RestingPose.breath
            breathe.duration = 2.25
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathLayer.add(breathe, forKey: Self.breathKey)
        } else {
            breathLayer.removeAnimation(forKey: Self.breathKey)
        }
    }
}
