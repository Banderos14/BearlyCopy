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
    /// Where the eyes look, each axis −1…1. Only set from pointer events
    /// inside the island; never stored.
    public internal(set) var gaze: CGPoint = .zero

    public init() {}
}

struct MascotView: View {
    let state: MascotState
    var size: CGFloat = 18
    var reduceMotion = false

    var body: some View {
        Canvas { context, canvas in
            Self.draw(in: &context, size: canvas, mood: state.mood, blink: state.isBlinking, gaze: state.gaze)
        }
        .frame(width: size, height: size)
        .scaleEffect(state.mood == .pleased && !reduceMotion ? 1.08 : 1)
        .offset(y: state.mood == .curious && !reduceMotion ? -1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: state.mood)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.gaze)
        .accessibilityElement()
        .accessibilityLabel(label)
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

    static func draw(in ctx: inout GraphicsContext, size: CGSize, mood: MascotState.Mood, blink: Bool, gaze: CGPoint) {
        let s = min(size.width, size.height)
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        // Ears, head, muzzle.
        for x in [0.06, 0.66] {
            ctx.fill(Path(ellipseIn: r(x, 0.04, 0.28, 0.28)), with: .color(fur))
            ctx.fill(Path(ellipseIn: r(x + 0.07, 0.11, 0.14, 0.14)), with: .color(furDark))
        }
        ctx.fill(Path(ellipseIn: r(0.1, 0.14, 0.8, 0.78)), with: .color(fur))
        ctx.fill(Path(ellipseIn: r(0.3, 0.52, 0.4, 0.3)), with: .color(muzzle))
        ctx.fill(Path(ellipseIn: r(0.43, 0.56, 0.14, 0.09)), with: .color(ink))   // nose

        // Eyes: small, round, follow the gaze a little.
        let dx = max(-1, min(1, gaze.x)) * 0.035, dy = max(-1, min(1, gaze.y)) * 0.025
        for x in [0.33, 0.67] {
            let center = CGPoint(x: (x + dx) * s, y: (0.44 + dy) * s)
            if blink {
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.06 * s, y: center.y))
                p.addLine(to: CGPoint(x: center.x + 0.06 * s, y: center.y))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.05 * s, lineCap: .round))
            } else if mood == .pleased {
                // Happy closed eyes (^ ^).
                var p = Path()
                p.move(to: CGPoint(x: center.x - 0.06 * s, y: center.y + 0.02 * s))
                p.addQuadCurve(to: CGPoint(x: center.x + 0.06 * s, y: center.y + 0.02 * s),
                               control: CGPoint(x: center.x, y: center.y - 0.06 * s))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.05 * s, lineCap: .round))
            } else {
                let e = mood == .curious ? 0.13 : 0.11
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - e * s / 2, y: center.y - e * s / 2, width: e * s, height: e * s)),
                         with: .color(ink))
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - 0.01 * s, y: center.y - 0.04 * s, width: 0.035 * s, height: 0.035 * s)),
                         with: .color(.white.opacity(0.9)))
            }
        }
        // Brows only when concerned: tilted inward, no frown, no red.
        if mood == .concerned {
            for (x, dir) in [(0.33, 1.0), (0.67, -1.0)] {
                var p = Path()
                p.move(to: CGPoint(x: (x - 0.07) * s, y: (0.31 - 0.02 * dir) * s))
                p.addLine(to: CGPoint(x: (x + 0.07) * s, y: (0.31 + 0.02 * dir) * s))
                ctx.stroke(p, with: .color(furDark), style: StrokeStyle(lineWidth: 0.045 * s, lineCap: .round))
            }
        }
        // Mouth: a small smile, a little wider when pleased, a flat line when concerned.
        var mouth = Path()
        let y = 0.71 * s, w: CGFloat = mood == .pleased ? 0.1 : 0.07
        mouth.move(to: CGPoint(x: (0.5 - w) * s, y: y))
        if mood == .concerned {
            mouth.addLine(to: CGPoint(x: (0.5 + w) * s, y: y))
        } else {
            mouth.addQuadCurve(to: CGPoint(x: (0.5 + w) * s, y: y), control: CGPoint(x: 0.5 * s, y: y + 0.06 * s))
        }
        ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.035 * s, lineCap: .round))
    }
}
