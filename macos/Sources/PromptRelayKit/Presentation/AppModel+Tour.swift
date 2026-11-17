import Foundation

/// Phase 19: the Quick Tour — nine short pages on the basics, shown once on
/// the first launch and reopened from Settings or the ⋯ menu. It only
/// explains; it changes no setting and reads nothing.
extension AppModel {
    static let tourSeenKey = "tour.seen"
    /// How many times the tour has been shown by itself (a second chance if the
    /// first one closed because the pointer or focus left the island).
    static let tourShownKey = "tour.shown"
    static let tourAutoShowLimit = 2

    public struct TourPage: Equatable, Identifiable, Sendable {
        public let id: Int
        public let symbol: String
        public let title: String
        public let text: String
    }

    /// The page icon that is Relay the bear instead of an SF Symbol.
    public static let tourBearSymbol = "relay.bear"

    public static let tourPages: [TourPage] = [
        TourPage(id: 0, symbol: tourBearSymbol, title: "Welcome to BearlyCopy",
                 text: "It keeps the final answer of Claude Code or Codex exactly as written, one click from any other chat."),
        TourPage(id: 1, symbol: "macbook", title: "The notch is the app",
                 text: "Hover the notch to open BearlyCopy. Press Esc or click anywhere else to close it."),
        TourPage(id: 2, symbol: "eye", title: "Quick Peek",
                 text: "The latest answer, the request it answered, and two buttons. Click Details for everything."),
        TourPage(id: 3, symbol: "doc.on.doc", title: "Copy Answer",
                 text: "Copies the agent's answer verbatim. Nothing is shortened, reformatted or summarized."),
        TourPage(id: 4, symbol: "checklist", title: "Copy with Context",
                 text: "Adds the request, project, commands and files, and labels each claim Confirmed locally or Reported by Claude. A secret check runs first."),
        TourPage(id: 5, symbol: "paperclip", title: "Details and attachments",
                 text: "See the task, the answer and the files the agent wrote. An optional screenshot of the agent's window stays in memory only."),
        TourPage(id: 6, symbol: "tray.full", title: "Inbox and History",
                 text: "Every agent and project in one place, with search. Follow the latest answer or stay on one conversation."),
        TourPage(id: 7, symbol: tourBearSymbol, title: "Relay the bear tells you what is happening",
                 text: "Resting, working, waiting for your input, done, or an error. A glance is enough."),
        TourPage(id: 8, symbol: "lock.shield", title: "Set up once, stays private",
                 text: "Connect your agent in Set Up. Everything stays on this Mac: no account, no network. Settings → Daily Use shows Ready."),
    ]

    /// The tour was finished or skipped once; it is not shown by itself again.
    public var tourSeen: Bool {
        _ = tourVersion
        if stateDefaults?.bool(forKey: Self.tourSeenKey) ?? false { return true }
        return ((stateDefaults?.object(forKey: Self.tourShownKey) as? Int) ?? 0) >= Self.tourAutoShowLimit
    }

    /// The first-launch tour: only where the choice can be remembered (the
    /// real app), and only once.
    public var shouldAutoShowTour: Bool { stateDefaults != nil && !tourSeen }

    public var tourIsLastPage: Bool { tourPage >= Self.tourPages.count - 1 }

    public func startTour() {
        tourPage = 0
        navigate(to: .tour)
    }

    /// Opening it counts as seen: it never pops up again by itself, even if
    /// the person leaves with the island's own Back.
    public func markTourSeen() {
        guard !tourSeen else { return }
        // Shown by itself at most twice: a first launch whose island closed
        // at once (focus left it) gets one more chance; Done or Skip ends it.
        stateDefaults?.set(((stateDefaults?.object(forKey: Self.tourShownKey) as? Int) ?? 0) + 1, forKey: Self.tourShownKey)
        tourVersion += 1
    }

    public func tourNext() { if tourPage < Self.tourPages.count - 1 { tourPage += 1 } }
    public func tourBack() { if tourPage > 0 { tourPage -= 1 } }

    /// Done or Skip: marks it seen and goes back to the answer.
    public func finishTour(openSetup: Bool = false) {
        stateDefaults?.set(true, forKey: Self.tourSeenKey)
        tourVersion += 1
        tourPage = 0
        navigate(to: openSetup ? .setup : .home)
    }
}
