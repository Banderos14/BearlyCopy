import SwiftUI

/// Phase 19: the Quick Tour. One short page at a time inside the island:
/// an icon, a title, two plain sentences, dots, Back / Next, Skip.
struct TourView: View {
    let model: AppModel
    let presentation: NotchPresentation

    var body: some View {
        let pages = AppModel.tourPages
        let page = pages[min(max(model.tourPage, 0), pages.count - 1)]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(page.id + 1) of \(pages.count)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Island.tertiary)
                    .monospacedDigit()
                Spacer()
                Button("Skip") { model.finishTour() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Island.secondary)
                    .islandHelp("Close the tour. Settings → Show Quick Tour opens it again.")
                    .accessibilityLabel("Skip the tour")
            }
            HStack(alignment: .center, spacing: 16) {
                Group {
                    if page.symbol == AppModel.tourBearSymbol {
                        MascotView(state: presentation.mascot, size: 52, reduceMotion: presentation.reduceMotion)
                    } else {
                        Image(systemName: page.symbol)
                            .font(.system(size: 34, weight: .medium)).foregroundStyle(Island.accent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 76, height: 76)
                .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.card))
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Island.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.text).font(.system(size: 12.5)).foregroundStyle(Island.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Island.cardRadius).fill(Island.cardRaised.opacity(0.5)))
            .id(page.id)
            .transition(.opacity)
            HStack(spacing: 10) {
                Button("Back") { model.tourBack() }.buttonStyle(IslandPillStyle(prominent: false)).disabled(page.id == 0)
                HStack(spacing: 5) {
                    ForEach(pages) { p in
                        Circle().fill(p.id == page.id ? Island.accent : Island.tertiary.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                if model.tourIsLastPage {
                    Button("Open Set Up") { model.finishTour(openSetup: true) }.buttonStyle(IslandPillStyle(prominent: false))
                    Button("Done") { model.finishTour() }.buttonStyle(IslandPillStyle(prominent: true))
                } else {
                    Button("Next") { model.tourNext() }.buttonStyle(IslandPillStyle(prominent: true))
                }
            }
        }
        .animation(presentation.reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.tourPage)
        .islandPadding(presentation)
        .onAppear { model.markTourSeen() }
    }
}
