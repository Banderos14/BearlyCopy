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
            // Outside the island (previews, other hosts): the system tooltip.
            content.help(text)
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

    var body: some View {
        if let tip = tips.tip {
            Text(tip.text)
                .font(.system(size: 11))
                .foregroundStyle(Island.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Island.cardRaised))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Island.hairline))
                .alignmentGuide(.leading) { d in
                    -min(max(8, tip.anchor.midX - d.width / 2), size.width - d.width - 8)
                }
                .alignmentGuide(.top) { d in
                    let below = tip.anchor.maxY + 6
                    return -(below + d.height <= size.height - 8 ? below : max(4, tip.anchor.minY - 6 - d.height))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
                .id(tip.owner)
        }
    }
}
