import Observation
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
    /// Counts successful copies: each one plays the short happy reaction
    /// (a hop with the eyes closed).
    public internal(set) var cheers = 0
    /// Counts failed copies: each one plays a small head shake instead.
    public internal(set) var worries = 0

    public init() {}
}

/// How far the head and eyes turn for a gaze: bounded, so Relay never looks
/// unnatural, and zero when the pointer is gone.
struct MascotPose: Equatable {
    /// Eye offset, each axis −1…1.
    var eyes: CGPoint
    /// Head tilt in degrees toward the pointer.
    var tilt: Double
    /// Head shift as a fraction of the mascot's size.
    var shift: CGSize

    static let maxTilt = 6.0
    static let maxShift: CGFloat = 0.03

    init(gaze: CGPoint) {
        let g = CGPoint(x: max(-1, min(1, gaze.x)), y: max(-1, min(1, gaze.y)))
        eyes = g
        tilt = Double(g.x) * Self.maxTilt
        shift = CGSize(width: g.x * Self.maxShift, height: g.y * Self.maxShift * 0.75)
    }
}

struct MascotView: View {
    let state: MascotState
    var size: CGFloat = MascotView.preferredSize
    var reduceMotion = false

    /// Beside the camera housing (resting ear) and in the island's band: as
    /// large as the housing's height allows, 2 pt clear above and below.
    static let preferredSize: CGFloat = 28
    static func size(notchHeight: CGFloat) -> CGFloat { min(preferredSize, max(16, notchHeight - 4)) }

    var body: some View {
        let pose = MascotPose(gaze: reduceMotion ? .zero : state.gaze)
        let reaction = ReactionTrigger(cheers: state.cheers, worries: state.worries)
        KeyframeAnimator(initialValue: Reaction(), trigger: reaction) { r in
            MascotFace(gazeX: pose.eyes.x, gazeY: pose.eyes.y, eyeOpen: state.isBlinking ? 0 : 1,
                       squint: r.squint, mood: state.mood)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(pose.tilt + r.shake * 4), anchor: .bottom)
                .offset(x: pose.shift.width * size, y: pose.shift.height * size + r.lift)
                .scaleEffect(r.scale, anchor: .bottom)
        } keyframes: { _ in
            // Amplitudes are zero for the reaction that did not happen, and
            // for every movement under Reduce Motion (the closed eyes stay).
            let hop: CGFloat = state.mood == .pleased && !reduceMotion ? 1 : 0
            let shake: CGFloat = state.mood == .concerned && !reduceMotion ? 1 : 0
            let squint: CGFloat = state.mood == .pleased ? 1 : 0
            KeyframeTrack(\.scale) {
                SpringKeyframe(1 + 0.08 * hop, duration: 0.14)
                SpringKeyframe(1 - 0.03 * hop, duration: 0.14)
                SpringKeyframe(1, duration: 0.22)
            }
            KeyframeTrack(\.lift) {
                CubicKeyframe(-1.5 * hop, duration: 0.14)
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
