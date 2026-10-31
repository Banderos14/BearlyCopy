import SwiftUI

// Tooltips drawn inside the island. AppKit's tooltips (SwiftUI `.help`)
// appear only while the app is active; the island is a non-activating
// panel of an accessory app, so over Quick Peek they never showed and in
// Details only after a click had activated the app — "sometimes yes,
// sometimes no" (Phase 6 audit). One tip at a time, after 180 ms; moving to
// a neighbour while one is shown switches at once; gone on leaving, on
// clicking and when the island closes or changes view. No window of its
// own, so nothing can stay behind; never hit-testable, so it never covers
// an action.

@MainActor
@Observable
final class IslandTooltips {
    struct Tip: Equatable {
        let owner: UUID
        let text: String
        /// The hovered control, in the island's coordinate space.
        let anchor: CGRect
    }

    static let delay: UInt64 = 180_000_000

    private(set) var tip: Tip?
    /// Every control with a tip and where it is now. A tip is placed clear
    /// of the other controls (Phase 8: tips covered Copy Answer and the
    /// footer icons); layout tests read it too.
    @ObservationIgnored var controls: [UUID: (text: String, anchor: CGRect)] = [:]
    #if DEBUG
    /// Shows a tip at once (layout tests).
    func show(_ owner: UUID, text: String, anchor: CGRect) { pending?.cancel(); tip = Tip(owner: owner, text: text, anchor: anchor) }
    #endif
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingOwner: UUID?

    func enter(_ owner: UUID, text: String, anchor: CGRect) {
        // An empty tip is only its black background: the small black box
        // over Observed Work's file list (Phase 8, a withheld command's row).
        guard !Self.isBlank(text) else { leave(owner); return }
        pending?.cancel()
        let next = Tip(owner: owner, text: text, anchor: anchor)
        if tip != nil { tip = next; return }   // already reading tips: switch at once
        pendingOwner = owner
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.delay)
            guard !Task.isCancelled, let self, self.pendingOwner == owner else { return }
            self.tip = next
        }
    }

    /// The control moved while its tip is shown (a list scrolled, the
    /// island resized): the tip follows it instead of staying behind.
    func move(_ owner: UUID, anchor: CGRect) {
        guard let tip, tip.owner == owner, tip.anchor != anchor else { return }
        self.tip = Tip(owner: owner, text: tip.text, anchor: anchor)
    }

    func leave(_ owner: UUID) {
        if pendingOwner == owner { pending?.cancel(); pendingOwner = nil }
        if tip?.owner == owner { tip = nil }
    }

    static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func hideAll() {
        pending?.cancel()
        pendingOwner = nil
        tip = nil
    }
}

struct IslandTooltipsKey: EnvironmentKey {
    static let defaultValue: IslandTooltips? = nil
}

extension EnvironmentValues {
    var islandTooltips: IslandTooltips? {
        get { self[IslandTooltipsKey.self] }
        set { self[IslandTooltipsKey.self] = newValue }
    }
}

struct IslandHelp: ViewModifier {
    let text: String
    @Environment(\.islandTooltips) private var tips
    @State private var owner = UUID()
    @State private var frame: CGRect = .zero
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if let tips, !IslandTooltips.isBlank(text) {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NotchRootView.space)) }) {
                    frame = $0
                    tips.move(owner, anchor: $0)
                    tips.controls[owner] = (text, $0)
                }
                .onHover { inside in
                    if inside { tips.enter(owner, text: text, anchor: frame) } else { tips.leave(owner) }
                }
                // Keyboard: the tip of the focused control (Full Keyboard Access).
                .focused($focused)
                .onChange(of: focused) { _, now in
                    if now { tips.enter(owner, text: text, anchor: frame) } else { tips.leave(owner) }
                }
                .simultaneousGesture(TapGesture().onEnded { tips.leave(owner) })
                .onDisappear {
                    tips.leave(owner)
                    tips.controls[owner] = nil
                }
                .accessibilityHint(text)
        } else {
            // Outside the island (previews, tests), or nothing to say: no tip.
            // No AppKit tooltip either; its window can reach past the island.
            content.accessibilityHint(text)
        }
    }
}

extension View {
    /// The island's tooltip (and the accessibility hint) for a control.
    func islandHelp(_ text: String) -> some View { modifier(IslandHelp(text: text)) }
}

/// The one visible tip, placed from its *measured* size inside the part of
/// the island that is really black: below the camera band, inside the
/// flared top sides and clear of the rounded bottom corners. Below the
/// control, above it when there is no room below, never over it. Phase 7:
/// the earlier version clamped to the island's bounding rectangle and
/// placed the tip with alignment guides, so a wrapped tip near a corner
/// could sit on the transparent corner of the window (cut by the island's
/// clip) and a first, unmeasured frame could flash in the wrong place.
struct IslandTooltipOverlay: View {
    let tips: IslandTooltips
    let size: CGSize
    /// Height of the camera band at the top of the island.
    var band: CGFloat = 32
    /// Long text wraps; the tip never grows wider than this.
    static let maxWidth: CGFloat = 200
    @State private var measured: CGSize?
    @State private var measuredOwner: UUID?

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                if let tip = tips.tip {
                    let wrap = min(Self.maxWidth, TipPlacement.safeArea(island: size, band: band).width)
                    let ready = measuredOwner == tip.owner ? measured : nil
                    let others = tips.controls.filter { $0.key != tip.owner }.map(\.value.anchor)
                    let frame = ready.map { TipPlacement.frame(anchor: tip.anchor, tip: $0, island: size, band: band, avoid: others) }
                    // As wide as its text (like inline-block), wrapping at
                    // `wrap`. Phase 7.1: `.frame(maxWidth:)` took the whole
                    // maximum, so "Back (Esc)" sat in a 208-pt box.
                    TipTextLayout(maxWidth: wrap - 14) {
                        Text(tip.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Island.primary.opacity(0.92))
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.82)))
                        .onGeometryChange(for: CGSize.self, of: { $0.size }) { measured = $0; measuredOwner = tip.owner }
                        .islandFrame("tooltip")
                        .offset(x: frame?.minX ?? 0, y: frame?.minY ?? 0)
                        // Drawn only once measured, so no frame shows in a wrong place.
                        .opacity(frame == nil ? 0 : 1)
                        .id(tip.owner)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Its one child at its ideal width, but never wider than `maxWidth`; the
/// height is what that width needs (the text wraps instead of truncating).
/// Wrapped text gets the narrowest width that keeps the same number of
/// lines, so the box ends where the longest line ends (Phase 8: a wrapped
/// tip kept the whole maximum, with an empty strip on the right).
struct TipTextLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        func height(_ w: CGFloat) -> CGFloat { child.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        let ideal = child.sizeThatFits(.unspecified).width
        guard ideal > maxWidth else { return CGSize(width: ideal, height: height(ideal)) }
        let target = height(maxWidth)
        var low = maxWidth / 2, high = maxWidth
        while high - low > 1 {
            let mid = ((low + high) / 2).rounded(.up)
            if height(mid) <= target + 0.5 { high = mid } else { low = mid }
        }
        return CGSize(width: high, height: height(high))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Where a tip of a given size goes. Pure, so every edge is tested.
/// Below its control, else above, else beside it, whichever covers the
/// fewest other controls (Phase 8: the Full Report tip lay on Copy Answer),
/// always inside the black part of the island and never over its own
/// control when there is any room for that.
enum TipPlacement {
    /// The island's visible side (the flared top's foot) plus a margin, so
    /// a tip never touches the island's edge.
    static let sideInset: CGFloat = 20
    /// Radius of the open island's bottom corners.
    static let bottomRadius: CGFloat = 26
    static let gap: CGFloat = 4

    /// The part of the island a tip may cover.
    static func safeArea(island: CGSize, band: CGFloat) -> CGRect {
        CGRect(x: sideInset, y: band + 2, width: max(0, island.width - 2 * sideInset),
               height: max(0, island.height - band - 2 - 6))
    }

    static func frame(anchor: CGRect, tip: CGSize, island: CGSize, band: CGFloat, avoid: [CGRect] = []) -> CGRect {
        let safe = safeArea(island: island, band: band)
        let w = min(tip.width, safe.width), h = min(tip.height, safe.height)
        /// Kept inside the safe area; near the bottom the rounded corners
        /// take more of the sides.
        func clamp(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            let y = min(max(safe.minY, y), safe.maxY - h)
            let inset = y + h > island.height - bottomRadius ? max(sideInset, bottomRadius) : sideInset
            let width = min(w, max(0, island.width - 2 * inset))
            let x = min(max(inset, x), max(inset, island.width - inset - width))
            return CGRect(x: x, y: y, width: width, height: h)
        }
        let centeredX = anchor.midX - w / 2, centeredY = anchor.midY - h / 2
        let own = anchor.insetBy(dx: 1, dy: 1)
        // The row the control sits in (a footer of buttons of other heights):
        // above or below the whole row, so the tip clears its neighbours too.
        let row = avoid.filter { $0.minY < anchor.maxY - 1 && $0.maxY > anchor.minY + 1 && !$0.contains(anchor) }
        let rowTop = row.map(\.minY).reduce(anchor.minY, min), rowBottom = row.map(\.maxY).reduce(anchor.maxY, max)
        let wanted = [CGRect(x: centeredX, y: anchor.maxY + gap, width: w, height: h),
                      CGRect(x: centeredX, y: anchor.minY - gap - h, width: w, height: h),
                      CGRect(x: centeredX, y: rowBottom + gap, width: w, height: h),
                      CGRect(x: centeredX, y: rowTop - gap - h, width: w, height: h),
                      CGRect(x: anchor.maxX + gap, y: centeredY, width: w, height: h),
                      CGRect(x: anchor.minX - gap - w, y: centeredY, width: w, height: h)]
        func covered(_ r: CGRect) -> CGFloat {
            avoid.reduce(0) { sum, other in
                let i = r.intersection(other)
                guard !i.isNull, !other.intersects(own) else { return sum }
                // A neighbour in the control's own row is where the pointer
                // goes next: covering it costs more than covering a card.
                let sameRow = other.minY < anchor.maxY && other.maxY > anchor.minY
                return sum + i.width * i.height * (sameRow ? 12 : 1)
            }
        }
        // First the places where the tip fits as wanted (only moved
        // sideways to stay inside), then any place clear of its control.
        let placed = wanted.map { ($0, clamp($0.minX, $0.minY)) }
        let exact = placed.filter { abs($0.1.minY - $0.0.minY) < 0.5 && ($0.0.minX == centeredX || abs($0.1.minX - $0.0.minX) < 0.5) }
            .map(\.1).filter { !$0.intersects(own) }
        if let best = exact.min(by: { covered($0) < covered($1) }) { return best }
        let free = placed.map(\.1).filter { !$0.intersects(own) }
        if let best = free.min(by: { covered($0) < covered($1) }) { return best }
        // Neither side has room for the whole tip: the side with more room.
        let roomBelow = safe.maxY - anchor.maxY, roomAbove = anchor.minY - safe.minY
        return clamp(centeredX, roomBelow >= roomAbove ? safe.maxY - h : safe.minY)
    }
}
