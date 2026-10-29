import AppKit
import Observation

/// Applies the settings at run time: starts or stops the notch, re-lays it
/// out when the display or motion preference changes, and turns ready-answer
/// tracking on only while something uses it.
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
        observe()
    }

    private func observe() {
        let snapshot = withObservationTracking {
            (settings.notchEnabled, settings.notifyWhenReady, settings.display, settings.animation,
             settings.yieldToOtherNotchApps)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observe() } }
        }
        apply(notch: snapshot.0, notify: snapshot.1)
    }

    private func apply(notch: Bool, notify: Bool) {
        model.tracksReadyAnswers = notch || notify
        if notify { model.startBackgroundObservation() }
        if notch {
            if controller == nil { controller = makeController() }
            controller?.start()
            controller?.relayout()  // display or motion preference may have changed
        } else {
            controller?.stop()
            controller = nil
        }
    }
}
