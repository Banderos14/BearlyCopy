import Foundation

/// Phase 14: Automatic final screenshots, extending Phase 9.4's opt-in
/// Auto-capture final window and Phase 10's in-memory snapshots.
///
/// - Off by default. The user links windows in macOS's own picker, one per
///   agent · profile · host · project (or one conversation); links last for
///   this app run only.
/// - After every new **final** answer (never an intermediate Stop, a wait for
///   background work, an API error, a question or a plan approval), the
///   linked window is captured once, after it had a moment to settle, and the
///   image is kept with that answer in memory (never a file, never the
///   clipboard, never the network).
/// - When the window cannot be told apart from another active conversation's,
///   nothing is taken ("Window association required"); the answer's text is
///   unaffected either way.
extension AppModel {
    /// The capture identity of a conversation: agent, local profile, host and
    /// project as BearlyCopy groups it.
    func captureKey(for session: SessionSummary) -> CaptureSourceKey? {
        guard let path = projectPath(for: session) ?? session.project.path else { return nil }
        return CaptureSourceKey(provider: session.provider, profileID: session.profile?.id ?? ProfileKey.unassigned,
                                host: session.source?.environment ?? .unknown, projectPath: path)
    }

    func captureKey(for answer: ReadyAnswer) -> CaptureSourceKey? {
        guard let path = answer.projectPath else { return nil }
        return CaptureSourceKey(provider: answer.provider, profileID: answer.profileID, host: answer.host, projectPath: path)
    }

    /// The open conversation can be linked to a window: its host is recorded.
    public var autoCaptureBlocker: String? {
        guard selectedImportID == nil, let session = selectedSession else { return "Open a conversation first." }
        guard (session.source?.environment ?? .unknown) != .unknown else {
            return "Its app is not recorded for this conversation, so no window can be linked to its answers."
        }
        return nil
    }

    /// "Claude · Work · Claude Desktop · prompt-relay" for a link.
    public func describe(_ binding: WindowBinding) -> String {
        let agent = profileTitle(ProfileKey(provider: binding.key.provider, profileID: binding.key.profileID))
        let project = (binding.key.projectPath as NSString).lastPathComponent
        let scope = binding.sessionKey == nil ? "" : " · this conversation"
        return "\(agent) · \(binding.key.host.title) · \(project)\(scope)"
    }

    /// Settings → Link Window…: the system picker; the window is linked to
    /// the agent · profile · host · project of the conversation open now.
    public func chooseAutoCaptureWindow() { linkAutoCaptureWindow(conversationOnly: false) }

    /// Link a window to the open conversation only (Attachments, when two
    /// conversations of one agent share an app and could not be told apart).
    public func linkAutoCaptureWindowToConversation() { linkAutoCaptureWindow(conversationOnly: true) }

    func linkAutoCaptureWindow(conversationOnly: Bool) {
        guard autoCaptureFinalWindow, autoCaptureBlocker == nil, let session = selectedSession,
              let key = captureKey(for: session), !isPresentingSystemDialog else { return }
        let sessionKey = conversationOnly ? session.sessionKey : nil
        isPresentingSystemDialog = true
        windowCapture.pickWindow { [weak self] result in
            guard let self else { return }
            self.isPresentingSystemDialog = false
            switch result {
            case .success(let window)?:
                // A new link for the same agent (or conversation) replaces the old one.
                for old in self.autoCaptureBindings where old.key == key && old.sessionKey == sessionKey {
                    self.unlink(old, forgetWindow: old.window.handle != window.handle)
                }
                self.autoCaptureBindings.append(WindowBinding(key: key, sessionKey: sessionKey, window: window,
                                                              createdAt: self.captureNow()))
                self.autoCaptureMessage = nil
                self.autoCapturePermissionBlocked = false
            case .failure(let error)?:
                let denied = (error as? WindowCaptureError) == .permissionDenied
                self.autoCapturePermissionBlocked = denied
                self.autoCaptureMessage = denied
                    ? AutoCaptureStatus.permissionRequired.message
                    : "The window could not be linked (screen capture may be off for BearlyCopy)."
            case nil: break
            }
        }
    }

    // MARK: Phase 18 — the window where the agent is working

    /// A conversation that started working just now (its prompt was sent
    /// seconds ago) is linked to the window of the app in front: that is where
    /// the person typed it — Claude Desktop, a terminal, an editor, anything.
    /// One link per conversation, replaced when a later prompt is sent from
    /// another window; never when BearlyCopy itself is in front, never for a
    /// conversation that was already working, never a window of another app.
    func autoLinkWorkingWindows() {
        // Never reads the window list unless the person turned this on AND
        // macOS already allows capture (a non-prompting check): no dialog.
        guard autoCaptureFinalWindow, autoLinkWindowEnabled, screenRecordingPermission.isGranted() else { return }
        let now = captureNow()
        let running = allSessions.filter { $0.running == true }
        autoLinkedRunning.formIntersection(Set(running.map(\.sessionKey)))   // a finished run may link again next time
        let fresh = running.filter { s in
            !autoLinkedRunning.contains(s.sessionKey) && (s.source?.environment ?? .unknown) != .unknown
                && (s.lastEventAt.flatMap(Wording.date).map { (0...6).contains(now.timeIntervalSince($0)) } ?? false)
        }
        // Two prompts at the same moment: the front window cannot be told to belong to either.
        guard fresh.count == 1, let session = fresh.first, let key = captureKey(for: session), !isPresentingSystemDialog else { return }
        autoLinkedRunning.insert(session.sessionKey)
        Task { @MainActor [weak self] in
            guard let self, let window = await self.windowCapture.frontmostWindow() else { return }
            // The switches may have changed while the window list was read.
            guard self.autoCaptureFinalWindow, self.autoLinkWindowEnabled else { self.windowCapture.forget(window); return }
            for old in self.autoCaptureBindings where old.key == key && old.sessionKey == session.sessionKey {
                self.unlink(old, forgetWindow: old.window.handle != window.handle)
            }
            self.autoCaptureBindings.append(WindowBinding(key: key, sessionKey: session.sessionKey, window: window,
                                                          createdAt: self.captureNow()))
            self.autoCaptureMessage = nil
            self.autoCapturePermissionBlocked = false
        }
    }

    // MARK: Phase 14.1 — permission recovery

    /// Opens System Settings at the Screen Recording pane (with fallbacks
    /// for older macOS); never changes any status by itself — only a real
    /// capture, via `checkAutoCaptureAccess`, can clear `permissionRequired`.
    @discardableResult
    public func openScreenRecordingSettings() -> Bool { screenRecordingPermission.openSettings() }

    /// The window linked to `ref`'s conversation, if exactly one resolves
    /// (same rule `autoCaptureNewFinals` uses for a finished answer).
    func autoCaptureBinding(for ref: ReportRef) -> WindowBinding? {
        guard case .local(let sessionKey, _) = ref, let session = allSessions.first(where: { $0.sessionKey == sessionKey }),
              let key = captureKey(for: session) else { return nil }
        let (binding, ambiguous) = AutoCapturePlanner.binding(for: sessionKey, key: key, in: autoCaptureBindings)
        return ambiguous ? nil : binding
    }

    /// "Check Again": never trusts that System Settings opened, or that the
    /// system API alone proves it. It reads `CGPreflightScreenCaptureAccess`
    /// first (no prompt, no window list) and, only if that says granted,
    /// attempts one real capture of the linked window — the actual operation
    /// auto-capture depends on. A mismatch (API says yes, capture still
    /// fails the same way) means this already-running process needs a
    /// restart before the grant takes effect.
    @discardableResult
    public func checkAutoCaptureAccess(for ref: ReportRef?) async -> AutoCaptureStatus? {
        guard let ref else { return nil }
        guard let binding = autoCaptureBinding(for: ref) else {
            let status: AutoCaptureStatus = autoCaptureBindings.isEmpty ? .windowNotBound : .associationRequired
            autoCaptureStatuses[ref.key] = status
            return status
        }
        do {
            _ = try await windowCapture.capture(binding.window)
            // A real capture worked: nothing left to say about this answer.
            autoCaptureStatuses[ref.key] = nil
            autoCaptureMessage = nil
            autoCapturePermissionBlocked = false
            return nil
        } catch {
            let status: AutoCaptureStatus
            switch WindowCapture.map(error) {
            case .permissionDenied:
                // Capture refused. If the system API says "not granted" the
                // permission is missing; if it says granted, this process
                // started before the grant took effect.
                status = screenRecordingPermission.isGranted() ? .restartRequired : .permissionRequired
            case let other:
                status = afterCaptureFailure(other, binding: binding)
            }
            autoCaptureStatuses[ref.key] = status
            return status
        }
    }

    public func removeAutoCaptureBinding(_ id: String) {
        guard let binding = autoCaptureBindings.first(where: { $0.id == id }) else { return }
        unlink(binding, forgetWindow: true)
    }

    private func unlink(_ binding: WindowBinding, forgetWindow: Bool) {
        autoCaptureBindings.removeAll { $0.id == binding.id }
        for (token, job) in autoCaptureJobs where token == binding.window.token { job.task.cancel(); autoCaptureJobs[token] = nil }
        if forgetWindow, !autoCaptureBindings.contains(where: { $0.window.handle == binding.window.handle }) {
            windowCapture.forget(binding.window)
        }
    }

    /// Turning the feature off forgets every link and stops pending captures;
    /// screenshots already taken stay with their answers until they expire
    /// or the user clears them.
    func unlinkAllAutoCaptureWindows() {
        for job in autoCaptureJobs.values { job.task.cancel() }
        autoCaptureJobs.removeAll()
        for binding in autoCaptureBindings { windowCapture.forget(binding.window) }
        autoCaptureBindings.removeAll()
        for (key, status) in autoCaptureStatuses where status == .pending { autoCaptureStatuses[key] = nil }
    }

    /// Settings → Clear Temporary Screenshots: every in-memory snapshot
    /// (manual and automatic) is dropped now. Answers and links stay.
    public func clearTemporaryScreenshots() {
        reportStore?.clearEphemeral()
        attachmentsVersion += 1
    }

    public var temporaryScreenshotSummary: (count: Int, bytes: Int) {
        let shots = reportStore?.allAttachments().filter(\.isInMemory) ?? []
        return (shots.count, reportStore?.ephemeralBytes ?? 0)
    }

    /// What to say about the auto screenshot of `ref` (nil: nothing).
    public func autoCaptureStatus(for ref: ReportRef?) -> AutoCaptureStatus? {
        guard autoCaptureFinalWindow, let ref else { return nil }
        return autoCaptureStatuses[ref.key]
    }

    // MARK: Trigger

    /// Every refresh: each final answer that finished after the feature was
    /// armed and has not been considered yet. Redelivery of the same Stop, a
    /// background continuation or FSEvents noise never makes a second one.
    func autoCaptureNewFinals() {
        guard autoCaptureFinalWindow, reportStore != nil else { return }
        // Cheap first: only answers not yet considered and newer than the
        // arm time (with thousands of results, usually none).
        let fresh = finishedAnswers.reversed().filter { answer in
            guard let finished = Wording.date(answer.at) else { return false }
            return finished >= autoCaptureArmedAt.addingTimeInterval(-1)
                && !autoCapturedRefs.contains(ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex).key)
        }
        guard !fresh.isEmpty else { return }
        let others = allSessions.map { s in
            AutoCapturePlanner.Candidate(sessionKey: s.sessionKey, key: captureKey(for: s),
                                         lastEventAt: s.lastEventAt.flatMap(Wording.date), running: s.running ?? false)
        }
        // Oldest first: a newer answer of the same window supersedes it.
        for answer in fresh {
            let ref = ReportRef.local(sessionKey: answer.sessionKey, turn: answer.turnIndex)
            guard let finished = Wording.date(answer.at) else { continue }
            let session = allSessions.first { $0.sessionKey == answer.sessionKey }
            let decision = AutoCapturePlanner.decide(sessionKey: answer.sessionKey, key: captureKey(for: answer), finishedAt: finished,
                                                     isFinal: answer.completion.isFinal, needsInput: session?.attention != nil,
                                                     bindings: autoCaptureBindings, others: others, now: captureNow())
            switch decision {
            case .skip(nil):
                // Not final yet (an intermediate Stop, background work): it
                // may become final later, so it is not marked considered.
                if answer.completion.isFinal { autoCapturedRefs.insert(ref.key) }
            case .skip(let status?):
                autoCapturedRefs.insert(ref.key)
                autoCaptureStatuses[ref.key] = status
            case .capture(let binding):
                autoCapturedRefs.insert(ref.key)
                startCapture(binding, ref: ref, provider: answer.provider)
            }
        }
    }

    private func startCapture(_ binding: WindowBinding, ref: ReportRef, provider: AgentProvider) {
        let token = binding.window.token
        if let running = autoCaptureJobs[token] {
            // The window now shows the newer answer: the older one gets none.
            running.task.cancel()
            autoCaptureStatuses[running.ref] = .superseded
        }
        autoCaptureStatuses[ref.key] = .pending
        let settle = captureSettle
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settledShot(of: binding.window, settle: settle)
            guard !Task.isCancelled else { return }
            if self.autoCaptureJobs[token]?.ref == ref.key { self.autoCaptureJobs[token] = nil }
            self.finishCapture(outcome, binding: binding, ref: ref, provider: provider)
        }
        autoCaptureJobs[token] = (ref.key, task)
    }

    /// Wait, capture, recheck: the last still once two in a row agree (or
    /// the attempts run out). Never a stream; cancellable between steps.
    private func settledShot(of window: PickedWindow, settle: CaptureSettle) async -> Result<WindowCapture.Shot, WindowCaptureError> {
        func pause(_ seconds: TimeInterval) async -> Bool {
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            return !Task.isCancelled
        }
        guard await pause(settle.first) else { return .failure(.failed) }
        var last: (shot: WindowCapture.Shot, print: [UInt8]?)?
        for attempt in 0..<max(1, settle.maxShots) {
            if attempt > 0 { guard await pause(settle.recheck) else { return .failure(.failed) } }
            let shot: WindowCapture.Shot
            do { shot = try await windowCapture.capture(window) } catch {
                return .failure(WindowCapture.map(error))
            }
            var print: [UInt8]? = nil
            if settle.maxShots > 1 {
                if let own = shot.fingerprint { print = own } else {
                    let png = shot.png
                    print = await Task.detached(priority: .utility) { CaptureStability.fingerprint(png: png) }.value
                }
            }
            if let previous = last, CaptureStability.same(previous.print, print) { return .success(shot) }
            last = (shot, print)
        }
        return last.map { .success($0.shot) } ?? .failure(.noImage)
    }

    private func finishCapture(_ outcome: Result<WindowCapture.Shot, WindowCaptureError>, binding: WindowBinding,
                               ref: ReportRef, provider: AgentProvider) {
        switch outcome {
        case .success(let shot):
            guard let store = reportStore else { return }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            do {
                // Memory only; selected for hand-offs only if the user said so.
                _ = try store.addEphemeralImage(shot.png, name: "Auto screenshot \(binding.key.host.title) \(f.string(from: captureNow())).png",
                                                to: ref, source: .windowCapture, sourceProvider: provider,
                                                selected: autoScreenshotsInHandoff)
                autoCaptureStatuses[ref.key] = .captured
                autoCaptureMessage = nil
            } catch {
                autoCaptureStatuses[ref.key] = .failed
            }
            attachmentsVersion += 1
        case .failure(.permissionDenied):
            autoCaptureStatuses[ref.key] = .permissionRequired
        case .failure(let error):
            autoCaptureStatuses[ref.key] = afterCaptureFailure(error, binding: binding)
        }
    }

    /// Phase 15.2 (risk R1): one failed capture used to drop the link for
    /// any reason except permission — a minimized window, one on another
    /// Space, or a transient ScreenCaptureKit error lost its link. The link
    /// is now dropped only when its invalidity is established: macOS no
    /// longer lists the window, or BearlyCopy no longer holds its source.
    /// Never replaced by another window.
    func afterCaptureFailure(_ error: WindowCaptureError, binding: WindowBinding) -> AutoCaptureStatus {
        let gone = error == .noSource || windowCapture.presence(of: binding.window) == .gone
        if gone {
            unlink(binding, forgetWindow: true)
            autoCaptureMessage = "A linked window was closed, so its link was removed. Link it again to resume auto screenshots."
            return .windowUnavailable
        }
        if case .present(onScreen: true) = windowCapture.presence(of: binding.window) { return .failed }
        return .windowNotCapturable
    }

    /// Tests: waits until every capture started so far has finished.
    public func waitForAutoCaptures() async {
        while let task = autoCaptureJobs.values.first?.task {
            await task.value
            autoCaptureJobs = autoCaptureJobs.filter { $0.value.task != task }
        }
    }
}
