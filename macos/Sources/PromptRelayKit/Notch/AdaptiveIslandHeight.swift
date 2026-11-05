import SwiftUI

/// Only visible, intrinsically sized additions contribute. Measuring before
/// the window cap makes this independent of the animated panel's current size.
struct IslandExtraHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

struct IslandExtraHeight: ViewModifier {
    let id: String
    /// The additional stack gap, not padding already included in the view.
    let spacing: CGFloat
    /// Ordinary footprint replaced by this view (e.g. the 28 pt action row).
    let replacing: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: IslandExtraHeightKey.self,
                        value: [id: max(0, geometry.size.height + spacing - replacing).rounded(.up)])
                }
            }
    }
}

extension View {
    func islandExtraHeight(_ id: String, spacing: CGFloat = 0, replacing: CGFloat = 0) -> some View {
        modifier(IslandExtraHeight(id: id, spacing: spacing, replacing: replacing))
    }
}

/// A stable scroll container: changing the budget does not replace the view
/// tree (or its focused controls). Normally it fits its child exactly. When
/// fixed chrome cannot fit the screen, every row remains reachable by scrolling.
struct AdaptiveIslandViewport<Content: View>: View {
    let budget: CGFloat
    @ViewBuilder let content: Content
    @State private var measuredHeight: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            HeightBudget(maxHeight: budget, allowsOverflow: true) { content }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { height in
                    if measuredHeight != height { measuredHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Before the first measurement keep the proposed (current) window
        // size; requesting the whole budget here briefly enlarged short Peek.
        .frame(height: measuredHeight.map { min($0, budget) }, alignment: .top)
        .islandFrame("island.viewport")
    }
}
