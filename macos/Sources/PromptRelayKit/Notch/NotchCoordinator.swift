import AppKit
import Observation

/// Applies the settings at run time: starts the island, and re-lays it out
/// when the hover, display or motion preference changes.
@MainActor
public final class NotchCoordinator {
    public let settings: NotchSettings
    public let notifier: ReadyNotifier
    private let model: AppModel
    private let makeController: @MainActor () -> NotchController
    public private(set) var controller: NotchController?

    public init(model: AppModel, settings: NotchSettings, notifier: ReadyNotifier,
                makeController: @escaping @MainActor () -> NotchController) {
        self.model = model
        self.settings = settings
        self.notifier = notifier
        self.makeController = makeController
        model.onNewAnswer = { [weak self] answer in
            guard let self, self.settings.notifyWhenReady else { return }
            self.notifier.announce(answer)
        }
        model.onNeedsInput = { [weak self] agent in
            guard let self, self.settings.notifyNeedsInput else { return }
            self.notifier.announceNeedsInput(agent)
        }
        observe()
    }

    private func observe() {
        let snapshot = withObservationTracking {
            (settings.notchEnabled, settings.notifyWhenReady || settings.notifyNeedsInput, settings.display, settings.animation,
             settings.yieldToOtherNotchApps, settings.mascotEnabled, settings.relayMotion, settings.relayIdle,
             settings.relayFollowsPointer, settings.relayWithoutNotch)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
        apply(notch: snapshot.0, notify: snapshot.1)
    }

    /// The island is the app's interface, so its controller always runs; the
    /// "open on hover" setting only decides whether the notch has a resting
    /// hover target (the controller reads it on relayout).
    private func apply(notch: Bool, notify: Bool) {
        model.tracksReadyAnswers = true
        if notify { model.startBackgroundObservation() }
        if controller == nil { controller = makeController() }
        controller?.start()
        controller?.relayout()  // hover setting, display or motion preference may have changed
    }
}
