import Foundation

/// Phase 17: Daily Use — one short setup and one honest readiness status.
///
/// - Nothing sensitive is switched on by itself. Global Capture and automatic
///   screenshots are turned on only by the user's own press on "Enable",
///   with the choices in front of them; macOS's Screen Recording consent and
///   the window picker stay macOS's.
/// - "Ready" is derived from the working state (the Core's `doctor`, the
///   capture policy, the plugin version, a real permission check, the window
///   links held now), never from a toggle alone.
/// - Setup only ever switches things on. A setting the user turned off
///   stays off unless they tick it again; repeating setup resets nothing.
extension AppModel {
    // MARK: Setup

    static let dailySetupAnsweredKey = "dailyUse.setupAnswered"

    /// What the user chose in the setup card. Each starts from the current
    /// state, so repeating setup shows what is on already.
    public struct DailyUseChoices: Equatable, Sendable {
        public var globalCapture: Bool
        public var autoScreenshots: Bool
        public var screenshotsInHandoff: Bool

        public init(globalCapture: Bool, autoScreenshots: Bool, screenshotsInHandoff: Bool) {
            self.globalCapture = globalCapture; self.autoScreenshots = autoScreenshots; self.screenshotsInHandoff = screenshotsInHandoff
        }
    }

    /// The card's initial ticks. On a first setup the recommended set is
    /// proposed (never applied until Enable): Global Capture and automatic
    /// screenshots ticked, including screenshots in hand-offs left to the
    /// user. A setting the user already decided keeps its value.
    public var dailyUseProposal: DailyUseChoices {
        let decidedScreenshots = stateDefaults?.object(forKey: Self.autoCaptureKey) != nil
        return DailyUseChoices(globalCapture: captureSettings?.mode == .global || (!dailySetupAnswered && captureSettings?.mode == .selected),
                               autoScreenshots: decidedScreenshots ? autoCaptureFinalWindow : !dailySetupAnswered,
                               screenshotsInHandoff: autoScreenshotsInHandoff)
    }

    /// The user answered the setup card once (Enable or Not Now): it is not
    /// shown by itself again. Settings → Daily Use opens it on request.
    public var dailySetupAnswered: Bool {
        _ = dailyUseVersion
        return stateDefaults?.bool(forKey: Self.dailySetupAnsweredKey) ?? false
    }

    /// The one-time card on Home and in the Inbox.
    public var offersDailyUseSetup: Bool { !dailySetupAnswered && captureSettings != nil }

    public func dismissDailyUseSetup() {
        stateDefaults?.set(true, forKey: Self.dailySetupAnsweredKey)
        // One prompt, not two: the older Global Capture offer is answered with it.
        dismissGlobalCaptureOffer()
        dailyUseVersion += 1
    }

    public enum DailyUseSetupOutcome: Equatable, Sendable {
        /// Everything ticked is on.
        case applied
        /// Global Capture was not switched on: with this plugin it would
        /// stop capture altogether. The rest was applied.
        case pluginUpdateFirst(installed: String, needed: String)
        case failed(String)
    }

    /// Whether switching to Global Capture now would leave the installed
    /// Claude Code plugin storing nothing (it refuses a policy it is too old
    /// to honor). Checked *before* the switch.
    public var globalCaptureBlockedByPlugin: (installed: String, needed: String)? {
        guard let settings = captureSettings, let installed = installedPluginVersion,
              let a = AppBuild.numeric(installed), let b = AppBuild.numeric(settings.minimumPluginVersion),
              a.lexicographicallyPrecedes(b) else { return nil }
        return (installed, settings.minimumPluginVersion)
    }

    /// "Capture All Projects" / the mode menu: the same check first. With a
    /// plugin too old for capture modes the switch is refused and says why
    /// (before Phase 17 it was made, and capture stopped until the update).
    public func requestGlobalCapture() async {
        if doctor.value == nil { await reloadDoctor() }
        if let blocked = globalCaptureBlockedByPlugin {
            captureModeError = "Not switched: the Claude Code plugin is \(blocked.installed) and All Projects needs \(blocked.needed) — an older plugin would store nothing. Update the plugin (Settings → Daily Use → Copy Update Commands), start a new Claude session, then choose All Projects."
            dailyUseVersion += 1
            return
        }
        await setCaptureMode(.mode(.global))
    }

    /// "Enable Recommended Daily Use": applies exactly what is ticked.
    /// Unticked items are left as they are — never switched off here.
    @discardableResult
    public func enableDailyUse(_ choices: DailyUseChoices) async -> DailyUseSetupOutcome {
        var outcome = DailyUseSetupOutcome.applied
        if choices.autoScreenshots, !autoCaptureFinalWindow { autoCaptureFinalWindow = true }
        if choices.autoScreenshots, choices.screenshotsInHandoff, !autoScreenshotsInHandoff { autoScreenshotsInHandoff = true }
        if choices.globalCapture, captureSettings?.mode != .global {
            if doctor.value == nil { _ = await reloadDoctor() }
            if let blocked = globalCaptureBlockedByPlugin {
                outcome = .pluginUpdateFirst(installed: blocked.installed, needed: blocked.needed)
            } else {
                await setCaptureMode(.mode(.global))
                if let error = captureModeError { outcome = .failed(error) }
            }
        }
        dismissDailyUseSetup()
        dailyUseOutcome = outcome
        return outcome
    }

    // MARK: Readiness

    public enum DailyUseState: String, Equatable, Sendable {
        case ready, setupIncomplete, pluginUpdateRequired, permissionRequired, windowNotLinked, capturePaused

        public var title: String {
            switch self {
            case .ready: return "Ready"
            case .setupIncomplete: return "Setup incomplete"
            case .pluginUpdateRequired: return "Plugin update required"
            case .permissionRequired: return "Permission required"
            case .windowNotLinked: return "Window not linked"
            case .capturePaused: return "Capture paused"
            }
        }
    }

    /// The one thing to do next, offered beside the status.
    public enum DailyUseAction: String, Equatable, Sendable {
        case openSetup, resumeCapture, showPluginUpdate, openScreenRecordingSettings, linkWindow, connectAgents, turnOnAttachments, followLatest

        public var title: String {
            switch self {
            case .openSetup: return "Set Up…"
            case .resumeCapture: return "Resume Capture"
            case .showPluginUpdate: return "Copy Update Commands"
            case .openScreenRecordingSettings: return "Open Screen Recording Settings"
            case .linkWindow: return "Link Window…"
            case .connectAgents: return "Set Up Agents"
            case .turnOnAttachments: return "Turn On"
            case .followLatest: return "Follow Latest"
            }
        }
    }

    public struct DailyUseCheck: Identifiable, Equatable, Sendable {
        public enum Level: String, Equatable, Sendable { case ok, attention, off, info }
        public let id: String
        public let title: String
        public let level: Level
        public let detail: String
        public var action: DailyUseAction? = nil
    }

    public struct DailyUseReport: Equatable, Sendable {
        public let state: DailyUseState
        /// One sentence: what is missing, or what works.
        public let summary: String
        public let action: DailyUseAction?
        public let checks: [DailyUseCheck]
    }

    /// Terminal commands that bring the Claude Code plugin to the version
    /// this app needs. The second block is for a marketplace that points at
    /// an older checkout (then `update` reports no change).
    public static func pluginUpdateCommands(checkout: String? = nil) -> String {
        """
        claude plugin update prompt-relay@prompt-relay
        claude plugin list | grep -A2 prompt-relay

        # If the version did not change, the marketplace points at an older folder:
        claude plugin marketplace remove prompt-relay
        claude plugin marketplace add \(checkout ?? "<folder of the Prompt Relay checkout this app was built from>")
        claude plugin install prompt-relay@prompt-relay
        """
    }

    public var dailyUse: DailyUseReport {
        _ = dailyUseVersion
        var checks: [DailyUseCheck] = []
        let doctorData = doctor.value
        let status = captureStatus

        // 1. App and bundled Core.
        if let core = doctorData?.core {
            // The Core answering now against the one this build bundled
            // (unknown outside an app bundle: then nothing to compare).
            let bundled = bundledCoreVersion
            let same = bundled == nil || bundled == core.promptRelayVersion
            checks.append(DailyUseCheck(id: "core", title: "App and Core", level: same && core.python.supported ? .ok : .attention,
                                        detail: !core.python.supported ? "Python \(core.python.version) is too old for the Core."
                                            : same ? "Core \(core.promptRelayVersion)."
                                            : "This app bundles Core \(bundled ?? "?"), but Core \(core.promptRelayVersion) answers: reinstall Prompt Relay."))
        } else {
            checks.append(DailyUseCheck(id: "core", title: "App and Core", level: .attention,
                                        detail: doctor.error == nil ? "Checking…" : "The Core could not be asked for its diagnostics."))
        }

        // 2. Capture mode (the policy the hooks follow).
        switch status {
        case .paused:
            checks.append(DailyUseCheck(id: "capture", title: "Capture", level: .attention, detail: "Paused: nothing new is stored.", action: .resumeCapture))
        case .pluginUpdateRequired(let installed, let needed):
            checks.append(DailyUseCheck(id: "capture", title: "Capture", level: .attention,
                                        detail: "The mode is set, but plugin \(installed) cannot honor it (needs \(needed)): nothing is stored.",
                                        action: .showPluginUpdate))
        case .allProjects(let excluded):
            checks.append(DailyUseCheck(id: "capture", title: "Capture", level: .ok,
                                        detail: excluded == 0 ? "All projects." : "All projects, \(excluded) excluded."))
        case .selectedProjects(let count):
            checks.append(DailyUseCheck(id: "capture", title: "Capture", level: count > 0 ? .ok : .attention,
                                        detail: count > 0 ? "Selected projects only (\(count)). A new repository must be switched on."
                                            : "No project is switched on: nothing is captured.",
                                        action: count > 0 ? nil : .openSetup))
        case .unknown:
            checks.append(DailyUseCheck(id: "capture", title: "Capture", level: .attention, detail: "The capture mode could not be read."))
        }

        // 3. Claude Code plugin and real hook deliveries.
        let plugin = installedPluginVersion
        let stored = doctorData?.observed.outcomes["stored"] ?? 0
        if let blocked = globalCaptureBlockedByPlugin {
            checks.append(DailyUseCheck(id: "plugin", title: "Claude Code plugin", level: status == .pluginUpdateRequired(installed: blocked.installed, needed: blocked.needed) ? .attention : .info,
                                        detail: "Installed \(blocked.installed). All Projects needs \(blocked.needed) or newer.", action: .showPluginUpdate))
        } else if let plugin {
            checks.append(DailyUseCheck(id: "plugin", title: "Claude Code plugin", level: .ok, detail: "Installed \(plugin)."))
        } else if doctorData != nil {
            checks.append(DailyUseCheck(id: "plugin", title: "Claude Code plugin", level: stored > 0 ? .info : .attention,
                                        detail: stored > 0 ? "Not installed as a plugin; events arrive another way." : "Not installed.",
                                        action: stored > 0 ? nil : .connectAgents))
        }
        if doctorData != nil {
            checks.append(DailyUseCheck(id: "hooks", title: "Hook deliveries", level: stored > 0 ? .ok : .attention,
                                        detail: stored > 0 ? "\(stored) stored events seen in the hook log."
                                            : "No stored event yet. Ask an agent something in a captured project.",
                                        action: stored > 0 ? nil : .connectAgents))
        }

        // 4. Latest and attachments (work without setup).
        checks.append(sessionPinned
            ? DailyUseCheck(id: "latest", title: "Latest answer", level: .info,
                            detail: "Staying on a pinned conversation; newer answers elsewhere wait behind \u{201C}New\u{201D}.", action: .followLatest)
            : DailyUseCheck(id: "latest", title: "Latest answer", level: .ok, detail: "Opens on the newest final answer of any project."))
        if reportStore == nil {
            checks.append(DailyUseCheck(id: "attachments", title: "Result files", level: .attention, detail: "The attachment folder is not available."))
        } else if !autoSelectResultAttachments {
            checks.append(DailyUseCheck(id: "attachments", title: "Result files", level: .off,
                                        detail: "Off: files are offered under From this turn, with Add.", action: .turnOnAttachments))
        } else {
            checks.append(DailyUseCheck(id: "attachments", title: "Result files", level: .ok,
                                        detail: autoSelectPreparedAttachments ? "Attached and selected when the answer arrives."
                                            : "Attached when the answer arrives; you tick what to hand over."))
        }

        // 5. Automatic screenshots: permission and a live window link.
        var screenshotBlock: DailyUseState?
        if !autoCaptureFinalWindow {
            checks.append(DailyUseCheck(id: "screenshots", title: "Automatic screenshots", level: .off, detail: "Off.",
                                        action: dailySetupAnswered ? nil : .openSetup))
        } else if autoCapturePermissionBlocked || (!autoCaptureBindings.isEmpty && !screenRecordingPermission.isGranted()) {
            screenshotBlock = .permissionRequired
            checks.append(DailyUseCheck(id: "screenshots", title: "Automatic screenshots", level: .attention,
                                        detail: "macOS has not allowed Prompt Relay to capture the linked window.", action: .openScreenRecordingSettings))
        } else if autoCaptureBindings.isEmpty {
            screenshotBlock = .windowNotLinked
            checks.append(DailyUseCheck(id: "screenshots", title: "Automatic screenshots", level: .attention,
                                        detail: "On, but no window is linked (links end when Prompt Relay quits). Open a conversation and link its window.",
                                        action: .linkWindow))
        } else {
            let n = autoCaptureBindings.count
            checks.append(DailyUseCheck(id: "screenshots", title: "Automatic screenshots", level: .ok,
                                        detail: "\(n == 1 ? "1 window" : "\(n) windows") linked. "
                                            + (autoScreenshotsInHandoff ? "Screenshots start ticked for hand-offs." : "Screenshots wait unticked until you tick them.")))
        }

        // The state: the first thing that stops daily use, in order of harm.
        let state: DailyUseState
        let summary: String
        let action: DailyUseAction?
        func first(_ id: String) -> DailyUseCheck? { checks.first { $0.id == id } }
        if status == .paused {
            (state, summary, action) = (.capturePaused, "Capture is paused: nothing new is stored.", .resumeCapture)
        } else if case .pluginUpdateRequired(let installed, let needed) = status {
            (state, summary, action) = (.pluginUpdateRequired, "Plugin \(installed) cannot honor the capture mode (needs \(needed)); nothing is stored until it is updated.", .showPluginUpdate)
        } else if let failing = ["core", "capture", "plugin", "hooks", "attachments"].compactMap(first).first(where: { $0.level == .attention }) {
            (state, summary, action) = (.setupIncomplete, failing.title + ": " + failing.detail, failing.action ?? .connectAgents)
        } else if !dailySetupAnswered {
            (state, summary, action) = (.setupIncomplete, "Choose once how Prompt Relay captures projects and screenshots.", .openSetup)
        } else if let screenshotBlock, let check = first("screenshots") {
            (state, summary, action) = (screenshotBlock, check.detail, check.action)
        } else {
            (state, summary, action) = (.ready, "New answers, their files\(autoCaptureFinalWindow ? " and screenshots" : "") arrive by themselves.", nil)
        }
        return DailyUseReport(state: state, summary: summary, action: action, checks: checks)
    }

    /// Runs the readiness action. `linkWindow` needs an open conversation
    /// (the macOS picker links a window to it); the rest act directly.
    public func perform(_ action: DailyUseAction) {
        switch action {
        case .openSetup: dailySetupOpen = true
        case .resumeCapture: Task { await setCaptureMode(.resume); dailyUseVersion += 1 }
        case .showPluginUpdate:
            do {
                _ = try clipboard.copy(Self.pluginUpdateCommands())
                dailyUseNotice = "Commands copied. Run them in Terminal, start a new Claude session, then Check Again."
            } catch {
                dailyUseNotice = "The commands could not be copied. They are in docs/PHASE17.md, section 8."
            }
        case .openScreenRecordingSettings: openScreenRecordingSettings()
        case .linkWindow:
            if autoCaptureBlocker == nil { chooseAutoCaptureWindow() } else { dailyUseNotice = autoCaptureBlocker }
        case .connectAgents: navigate(to: .setup)
        case .turnOnAttachments: autoSelectResultAttachments = true
        case .followLatest: followLatestNow()
        }
        dailyUseVersion += 1
    }

    /// "Check Again": re-reads the Core's diagnostics and the capture policy.
    public func recheckDailyUse() async {
        dailyUseNotice = nil
        await refreshNow()
        await reloadDoctor()
        dailyUseVersion += 1
    }
}
