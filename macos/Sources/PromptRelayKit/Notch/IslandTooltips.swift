import SwiftUI

// Tooltips drawn inside the island. AppKit's tooltips (SwiftUI `.help`)
// appear only while the app is active; the island is a non-activating
// panel of an accessory app, so over Quick Peek they never showed and in
// Details only after a click had activated the app — "sometimes yes,
// sometimes no" (Phase 6 audit). One tip at a time, after 180 ms; moving to
// a neighbour while one is shown switches at once; a 120 ms exit grace
// bridges the gap. Cleared on
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
    static let exitDelay: UInt64 = 120_000_000
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private(set) var tip: Tip?
    /// Every control with a tip and where it is now. A tip is placed clear
    /// of content in the bottom inset; layout tests read these anchors too.
    @ObservationIgnored var controls: [UUID: (text: String, anchor: CGRect)] = [:]
    #if DEBUG
    /// Shows a tip at once (layout tests).
    func show(_ owner: UUID, text: String, anchor: CGRect) {
        pending?.cancel(); dismissal?.cancel()
        tip = Self.isBlank(text) ? nil : Tip(owner: owner, text: text, anchor: anchor)
    }
    #endif
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingOwner: UUID?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func enter(_ owner: UUID, text: String, anchor: CGRect) {
        // An empty tip is only its black background: the small black box
        // over Observed Work's file list (Phase 8, a withheld command's row).
        guard !Self.isBlank(text) else { leave(owner); return }
        pending?.cancel()
        dismissal?.cancel()
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

    func leave(_ owner: UUID, immediately: Bool = false) {
        if pendingOwner == owner { pending?.cancel(); pendingOwner = nil }
        guard tip?.owner == owner else { return }
        dismissal?.cancel()
        if immediately { tip = nil; return }
        // Bridge the small gap between neighbouring controls without a blank frame.
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.exitDelay)
            guard !Task.isCancelled, self?.tip?.owner == owner else { return }
            self?.tip = nil
        }
    }

    static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func hideAll() {
        pending?.cancel()
        dismissal?.cancel()
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
    @State private var hovered = false

    func body(content: Content) -> some View {
        if let tips, !IslandTooltips.isBlank(text) {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NotchRootView.space)) }) {
                    frame = $0
                    tips.move(owner, anchor: $0)
                    tips.controls[owner] = (text, $0)
                }
                .onHover { inside in
                    hovered = inside
                    if inside { tips.enter(owner, text: text, anchor: frame) } else if !focused { tips.leave(owner) }
                }
                // Keyboard: the tip of the focused control (Full Keyboard Access).
                .focused($focused)
                .onChange(of: focused) { _, now in
                    if now { tips.enter(owner, text: text, anchor: frame) } else if !hovered { tips.leave(owner) }
                }
                .simultaneousGesture(TapGesture().onEnded { tips.leave(owner, immediately: true) })
                .onDisappear {
                    tips.leave(owner, immediately: true)
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

/// One measured help label, sharing the island's normal bottom inset. Only
/// a second line needs additional space; that space comes from the content
/// budget, not a taller panel. The clip follows the same layout animation as
/// the inset, so text cannot draw over controls during a height transition.
struct IslandTooltipOverlay: View {
    let tips: IslandTooltips
    let size: CGSize
    var band: CGFloat = 32
    var helpArea: CGRect? = nil
    var onMeasure: ((CGFloat) -> Void)? = nil
    static let maxWidth: CGFloat = 200

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                if let tip = tips.tip {
                    let width = helpArea?.width ?? min(Self.maxWidth, TipPlacement.safeArea(island: size, band: band).width)
                    TipTextLayout(maxWidth: width - (helpArea == nil ? 14 : 0), balancesLines: helpArea == nil) {
                        Text(verbatim: tip.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Island.primary.opacity(0.92))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, helpArea == nil ? 7 : 0)
                    .padding(.vertical, helpArea == nil ? 4 : 0)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onMeasure?($0) }
                    .frame(height: helpArea?.height, alignment: .topLeading)
                    .clipped()
                    .islandFrame("tooltip")
                    .offset(x: helpArea?.minX ?? TipPlacement.sideInset,
                            y: helpArea?.minY ?? size.height - 44)
                    // Keep identity when switching owners: no overlapping fading labels.
                    .transition(.identity)
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
    var balancesLines = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        func height(_ w: CGFloat) -> CGFloat { child.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        let ideal = child.sizeThatFits(.unspecified).width
        guard ideal > maxWidth else { return CGSize(width: ideal, height: height(ideal)) }
        let target = height(maxWidth)
        if !balancesLines { return CGSize(width: maxWidth, height: target) }
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
