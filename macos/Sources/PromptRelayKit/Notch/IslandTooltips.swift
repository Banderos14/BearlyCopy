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
    #if DEBUG
    /// Every control with a tip and where it is now, for layout tests.
    @ObservationIgnored var controls: [UUID: (text: String, anchor: CGRect)] = [:]
    /// Shows a tip at once (layout tests).
    func show(_ owner: UUID, text: String, anchor: CGRect) { pending?.cancel(); tip = Tip(owner: owner, text: text, anchor: anchor) }
    #endif
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pendingOwner: UUID?

    func enter(_ owner: UUID, text: String, anchor: CGRect) {
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

    func body(content: Content) -> some View {
        if let tips {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NotchRootView.space)) }) {
                    frame = $0
                    tips.move(owner, anchor: $0)
                    #if DEBUG
                    tips.controls[owner] = (text, $0)
                    #endif
                }
                .onHover { inside in
                    if inside { tips.enter(owner, text: text, anchor: frame) } else { tips.leave(owner) }
                }
                .simultaneousGesture(TapGesture().onEnded { tips.leave(owner) })
                .onDisappear {
                    tips.leave(owner)
                    #if DEBUG
                    tips.controls[owner] = nil
                    #endif
                }
                .accessibilityHint(text)
        } else {
            // Outside the island (previews, tests): no AppKit tooltip. Its
            // window can reach past the island onto other apps.
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
    static let maxWidth: CGFloat = 220
    @State private var measured: CGSize?
    @State private var measuredOwner: UUID?

    var body: some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                if let tip = tips.tip {
                    let wrap = min(Self.maxWidth, TipPlacement.safeArea(island: size, band: band).width)
                    let ready = measuredOwner == tip.owner ? measured : nil
                    let frame = ready.map { TipPlacement.frame(anchor: tip.anchor, tip: $0, island: size, band: band) }
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
struct TipTextLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, maxWidth)
        return CGSize(width: width, height: child.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Where a tip of a given size goes. Pure, so every edge is tested.
enum TipPlacement {
    /// The flared top sides stand this far in from the window.
    static let sideInset: CGFloat = 14
    /// Radius of the open island's bottom corners.
    static let bottomRadius: CGFloat = 26
    static let gap: CGFloat = 4

    /// The part of the island a tip may cover.
    static func safeArea(island: CGSize, band: CGFloat) -> CGRect {
        CGRect(x: sideInset, y: band + 2, width: max(0, island.width - 2 * sideInset),
               height: max(0, island.height - band - 2 - 6))
    }

    static func frame(anchor: CGRect, tip: CGSize, island: CGSize, band: CGFloat) -> CGRect {
        let safe = safeArea(island: island, band: band)
        let w = min(tip.width, safe.width), h = min(tip.height, safe.height)
        let below = anchor.maxY + gap, above = anchor.minY - gap - h
        let y: CGFloat
        if below + h <= safe.maxY { y = below }
        else if above >= safe.minY { y = above }
        else {   // neither fits whole: the side with more room, kept inside
            let roomBelow = safe.maxY - anchor.maxY, roomAbove = anchor.minY - safe.minY
            y = roomBelow >= roomAbove ? safe.maxY - h : safe.minY
        }
        // Near the bottom the rounded corners take more of the sides.
        let inset = y + h > island.height - bottomRadius ? max(sideInset, bottomRadius) : sideInset
        let width = min(w, max(0, island.width - 2 * inset))
        let x = min(max(inset, anchor.midX - width / 2), max(inset, island.width - inset - width))
        return CGRect(x: x, y: y, width: width, height: h)
    }
}
