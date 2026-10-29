import Foundation
import UserNotifications

/// Optional "answer ready" banner. The banner names the project only: the
/// answer text never goes to Notification Center (it could stay in its
/// history or show on a locked screen).
@MainActor
public final class ReadyNotifier {
    /// UNUserNotificationCenter aborts the process outside an `.app` bundle
    /// (`swift run`, xctest), so it is only created inside one, on first use.
    public let isAvailable: Bool
    private var center: UNUserNotificationCenter? {
        isAvailable ? UNUserNotificationCenter.current() : nil
    }

    public init(bundle: Bundle = .main) {
        isAvailable = bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier != nil
    }

    /// Asks once, when the user turns the setting on.
    public func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    public func announce(_ answer: AppModel.ReadyAnswer) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude Code answer ready"
        content.body = "\(answer.projectName) — open Prompt Relay to copy it."
        content.threadIdentifier = "prompt-relay.ready"
        let request = UNNotificationRequest(identifier: "prompt-relay.ready.\(answer.sessionKey)", content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
