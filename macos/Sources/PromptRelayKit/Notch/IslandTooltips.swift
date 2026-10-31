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
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(NotchRootView.space)) }) { frame = $0 }
                .onHover { inside in
                    if inside { tips.enter(owner, text: text, anchor: frame) } else { tips.leave(owner) }
                }
                .simultaneousGesture(TapGesture().onEnded { tips.leave(owner) })
                .onDisappear { tips.leave(owner) }
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

/// The one visible tip: below the control, or above it near the bottom
/// edge; kept inside the island.
struct IslandTooltipOverlay: View {
    let tips: IslandTooltips
    let size: CGSize
    /// Long text wraps; the tip never grows wider than this.
    static let maxWidth: CGFloat = 220

    var body: some View {
        if let tip = tips.tip {
            Text(tip.text)
                .font(.system(size: 10.5))
                .foregroundStyle(Island.primary.opacity(0.92))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: Self.maxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.82)))
                .alignmentGuide(.leading) { d in -Self.x(anchor: tip.anchor, width: d.width, in: size) }
                .alignmentGuide(.top) { d in -Self.y(anchor: tip.anchor, height: d.height, in: size) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
                .id(tip.owner)
        }
    }

    /// Centred on the control, shifted left or right to stay 8 pt inside
    /// the island's sides (which are inside the screen).
    static func x(anchor: CGRect, width: CGFloat, in size: CGSize) -> CGFloat {
        min(max(8, anchor.midX - width / 2), max(8, size.width - width - 8))
    }

    /// Below the control; above it when there is no room below.
    static func y(anchor: CGRect, height: CGFloat, in size: CGSize) -> CGFloat {
        let below = anchor.maxY + 4
        if below + height <= size.height - 6 { return below }
        return max(4, anchor.minY - 4 - height)
    }
}
