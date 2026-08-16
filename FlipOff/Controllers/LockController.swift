import Foundation
import Combine
import AppKit
import SwiftUI
import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "in.pooya.flipoff", category: "LockController")

@MainActor
class LockController: ObservableObject {
    /// True whenever *any* lock is up or in transition. Mirrors `state` for callers
    /// that can't reach the instance — the controller is a `@StateObject` owned by
    /// `FlipOffApp`, but `UpdateController` is a singleton with no handle on it and
    /// needs to know whether a Sparkle dialog would land on top of a live shield.
    /// Maintained solely by `transitionTo`, alongside `state`.
    static private(set) var isAnyLockActive = false

    @Published private(set) var state: LockState = .unlocked
    @Published var lockStartTime: Date?
    @Published var elapsedTime: TimeInterval = 0
    @Published private(set) var isAuthenticating = false
    @Published var lastError: String?
    @Published private(set) var unlockSucceeded = false
    @Published private(set) var failCount = 0
    /// Incremented on each agent ping that should pulse the lock screen. The lock
    /// screen watches this token to trigger a one-shot attention glow.
    @Published private(set) var pingPulse: Int = 0

    /// False until the first blocked input arrives. The shield goes up silent and
    /// bare — mascot, message and sound all wait for someone to actually touch the
    /// machine, so locking never announces itself to an empty room.
    @Published private(set) var revealed = false

    /// True from the first agent ping until unlock — after the glow pulses finish,
    /// the lock screen keeps a subtle "your agent needs you" hint from this flag.
    @Published private(set) var agentAttention = false

    /// Context for the lock screen's embedded Touch ID glyph, non-nil while locked
    /// on a Mac with an enrolled sensor. The view pairs with it at init; arming
    /// happens in `armEmbeddedTouchID()` once that pairing exists, which is what
    /// keeps the prompt inside the shield instead of in a system modal.
    @Published private(set) var touchIDContext: LAContext?

    /// Bumped each time a fresh context is issued, so the lock screen can `.id()`
    /// its glyph on it — an `LAAuthenticationView` binds its context permanently at
    /// init, so a re-arm has to produce a brand new view.
    @Published private(set) var touchIDGeneration = 0

    private let overlayManager = OverlayWindowManager()
    private let inputBlocker = InputBlocker()
    private let authenticator = Authenticator()
    private let sleepPreventer = SleepPreventer()

    private var timer: Timer?
    private var sleepObserver: Any?
    private var sessionLostObserver: Any?
    private var sessionActiveObserver: Any?
    private var inputBlockerFailedObserver: Any?
    private var inputAttemptObserver: Any?
    private var dismissRevealObserver: Any?
    private var overlayKeyObserver: Any?
    private var accessibilityCheckTimer: Timer?
    private var errorClearTask: Task<Void, Never>?
    private var toggleObserver: Any?
    private var lockObserver: Any?
    private var unlockObserver: Any?
    private var unlockPasswordObserver: Any?
    private var pingObserver: Any?
    private var authenticationInProgress = false
    private var sessionWasLost = false
    private var lastAuthFailTime: Date?
    private var lastPingTime: Date?
    private var revealHideTask: Task<Void, Never>?
    private var touchIDArmTask: Task<Void, Never>?
    private var hasCapturedThisLock = false

    init() {
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleFlipOff, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .unlocked {
                    self.lock()
                } else if self.state == .locked {
                    if HotkeyConfig.requiresAuthenticationToUnlock {
                        self.requestUnlock()
                    } else {
                        self.quickUnlock()
                    }
                }
            }
        }

        // These three used to be handled only by an `.onReceive` inside MenuBarView,
        // which exists only while the menu-bar popover is actually open. With the
        // popover closed — i.e. essentially always — Settings' "Lock Now" button and
        // the whole `flipoff://lock|unlock|unlock-password` URL scheme posted into the
        // void. They belong on the controller, which lives for the app's lifetime.
        lockObserver = NotificationCenter.default.addObserver(
            forName: .flipOffLock, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .unlocked else { return }
                self.lock()
            }
        }

        unlockObserver = NotificationCenter.default.addObserver(
            forName: .flipOffUnlock, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked else { return }
                self.requestUnlock()
            }
        }

        unlockPasswordObserver = NotificationCenter.default.addObserver(
            forName: .flipOffUnlockPassword, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked else { return }
                self.requestPasswordUnlock()
            }
        }

        inputAttemptObserver = NotificationCenter.default.addObserver(
            forName: .flipOffInputAttempt, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revealOnFirstInput()
            }
        }

        dismissRevealObserver = NotificationCenter.default.addObserver(
            forName: .flipOffDismissReveal, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissReveal()
            }
        }

        // The shield taking key back is the moment touch-to-unlock can actually
        // work: `LAAuthenticationView` ignores an arm issued while its window isn't
        // key, and that ignored state is permanent for that view. Re-issuing the
        // context rebuilds the view, and its `onAppear` arms the sensor again.
        overlayKeyObserver = NotificationCenter.default.addObserver(
            forName: .flipOffOverlayDidBecomeKey, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .locked,
                      !self.authenticationInProgress else { return }
                self.issueTouchIDContext()
            }
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked else { return }
                self.inputBlocker.stopBlocking()
                self.inputBlocker.startBlocking()
                self.overlayManager.blockSystemDialogs()
                // The IOPM assertion behind preventSleep() does not survive an
                // actual sleep (lid close, Apple menu, idle system sleep as
                // opposed to just display sleep) — only the display-wake
                // notification tells us it's gone, so it's unconditionally
                // recreated here rather than guarded on isActive.
                self.sleepPreventer.allowSleep()
                self.sleepPreventer.preventSleep()
            }
        }

        sessionLostObserver = NotificationCenter.default.addObserver(
            forName: .flipOffSessionLost, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .locked || self.state == .unlocking {
                    self.sessionWasLost = true
                    if self.authenticationInProgress {
                        self.authenticator.cancelPending()
                        self.authenticationInProgress = false
                        self.isAuthenticating = false
                        self.overlayManager.blockSystemDialogs()
                        self.inputBlocker.startBlocking()
                        self.transitionTo(.locked)
                        self.lastError = "Session interrupted — try again"
                        self.scheduleErrorClear()
                    }
                }
            }
        }

        sessionActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked, self.sessionWasLost else { return }
                self.sessionWasLost = false
                self.inputBlocker.stopBlocking()
                self.inputBlocker.startBlocking()
                self.overlayManager.blockSystemDialogs()
            }
        }

        inputBlockerFailedObserver = NotificationCenter.default.addObserver(
            forName: .flipOffInputBlockerFailed, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastError = "Input blocking failed"
                try? await Task.sleep(nanoseconds: Constants.Timing.errorDisplayBeforeForceUnlockNs)
                self.forceUnlock()
            }
        }

        pingObserver = NotificationCenter.default.addObserver(
            forName: .flipOffPing, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handlePing()
            }
        }
    }

    deinit {
        if let obs = toggleObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = lockObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = unlockObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = unlockPasswordObserver { NotificationCenter.default.removeObserver(obs) }
        timer?.invalidate()
        accessibilityCheckTimer?.invalidate()
        errorClearTask?.cancel()
        if let obs = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = sessionLostObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = sessionActiveObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = inputBlockerFailedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = pingObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = inputAttemptObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = overlayKeyObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = dismissRevealObserver { NotificationCenter.default.removeObserver(obs) }
        revealHideTask?.cancel()
    }

    // MARK: - Public

    func lock() {
        guard transitionTo(.locking) else { return }
        guard AccessibilityChecker.isEnabled else {
            AccessibilityChecker.promptIfNeeded()
            transitionTo(.unlocked)
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // Mascot and sound deliberately do NOT fire here — locking is silent and
        // the shield starts bare. Both land on the first blocked input instead
        // (see `revealOnFirstInput`), so the lock only announces itself to
        // someone actually trying to use the machine.
        sleepPreventer.preventSleep()

        presentOverlay()
    }

    /// Second half of `lock()`. There is nothing to photograph — the shield windows
    /// stay transparent and the real desktop keeps rendering underneath — so this
    /// runs straight through with no capture round trip and no Screen Recording
    /// permission involved.
    private func presentOverlay() {
        // A force-unlock or a failed transition between `lock()` and here leaves
        // .locking behind — don't raise a shield the user already escaped.
        guard state == .locking else {
            logger.info("Lock aborted before the shield went up — state is \(String(describing: self.state))")
            sleepPreventer.allowSleep()
            return
        }

        guard overlayManager.showOverlay(contentFactory: { [weak self] index, isPrimary in
            guard let self else { return AnyView(Color.black) }
            if isPrimary {
                return AnyView(LockScreenView(
                    controller: self,
                    screenRole: .primary,
                    phaseOffset: CGFloat(index) * 0.15
                ))
            } else {
                return AnyView(AmbientBackdropHost(controller: self))
            }
        }) else {
            logger.error("Lock failed — no screens available for overlay")
            sleepPreventer.allowSleep()
            transitionTo(.unlocked)
            lastError = "No screens available"
            scheduleErrorClear()
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: Constants.Timing.inputBlockerDelayNs)
            inputBlocker.startBlocking()
        }

        stopTimer()
        lockStartTime = Date()
        failCount = 0
        lastError = nil
        unlockSucceeded = false
        revealed = false
        hasCapturedThisLock = false
        lastAuthFailTime = nil
        errorClearTask?.cancel()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .locked || self.state == .unlocking,
                      let start = self.lockStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }

        startAccessibilityMonitoring()
        sessionWasLost = false
        transitionTo(.locked)
        issueTouchIDContext()
    }

    // MARK: - Embedded Touch ID
    //
    // Touch-to-unlock, without the system modal that made this unusable before.
    // A plain `evaluatePolicy` ALWAYS raises an alert — there is no silent way to
    // read the sensor — and that alert landed on top of the shield, announcing the
    // lock and handing a snoop a dialog. The fix is `LAAuthenticationView`
    // (macOS 12+): pair a context with an on-screen view first, and evaluation on
    // that context draws into the view instead of an alert. See
    // `EmbeddedTouchIDView` for the framework's constraints.
    //
    // Ordering is the whole game: the context must be published (so the lock
    // screen can build the paired view) BEFORE anything evaluates on it.

    /// Publishes a fresh context for the lock screen's glyph. Arming waits for
    /// `armEmbeddedTouchID()`, which the view calls once it's actually on screen.
    private func issueTouchIDContext() {
        guard let context = authenticator.makeAutoUnlockContext() else {
            // No sensor or nothing enrolled — leave the glyph unmounted rather than
            // showing a Touch ID affordance that can never succeed.
            touchIDContext = nil
            return
        }
        touchIDContext = context
        touchIDGeneration &+= 1
    }

    /// Arms the sensor against the currently published context. Called by the lock
    /// screen after its `LAAuthenticationView` is in the window — evaluating before
    /// the pairing is on screen is exactly what would put the prompt back into a
    /// modal.
    ///
    /// Re-arms itself after each failed/cancelled read for as long as the lock is
    /// up, so a wrong finger doesn't permanently disarm touch-to-unlock. Never sets
    /// `authenticationInProgress`: that flag gates the hotkey, and holding it across
    /// a pending read would bolt the user out from behind their own shield.
    func armEmbeddedTouchID() {
        touchIDArmTask?.cancel()
        touchIDArmTask = Task { @MainActor [weak self] in
            while let self, self.state == .locked, !Task.isCancelled {
                guard let context = self.touchIDContext else { return }

                // Stand down while a manual auth owns the sensor, then re-arm.
                if self.authenticationInProgress {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                logger.info("Arming embedded Touch ID — generation \(self.touchIDGeneration, privacy: .public)")
                let authenticated = await self.authenticator.armEmbeddedBiometrics(context)

                guard self.state == .locked, !Task.isCancelled else { return }

                if authenticated {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    self.unlockSucceeded = true
                    try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
                    guard !Task.isCancelled else { return }
                    self.unlock()
                    return
                }

                // A consumed context can't be re-evaluated — issue a new one, which
                // bumps the generation so the view rebuilds around it.
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard self.state == .locked, !Task.isCancelled else { return }
                self.issueTouchIDContext()
                // The rebuilt view calls back into this method; stop this loop so
                // the two don't run concurrently against the same sensor.
                return
            }
        }
    }

    /// A blocked keystroke/click while locked: wake the lock screen up. Plays the
    /// lock sound and pops the mascot in, then hides itself again after a few
    /// seconds so the screen goes back to passing for an unlocked desktop — the
    /// gag can be sprung repeatedly on the same lock.
    ///
    /// While already revealed, further input just restarts the countdown rather
    /// than re-triggering the sound.
    func revealOnFirstInput() {
        guard state == .locked else { return }

        if !revealed {
            revealed = true
            // Video mode brings its own audio track, and Settings hides the sound
            // picker there for the same reason — firing the lock sound on top of
            // it would put two unrelated noises on the same beat.
            if LockVisual.current != .video {
                SoundPlayer.play(LockSound.resolved(from: UserDefaults.standard.string(forKey: LockSound.storageKey) ?? LockSound.defaultValue))
            }
            // This — someone touching the machine while it's locked — IS the
            // "wrong attempt" for this app, not a resolved Touch ID/password
            // failure. Gating on `handleAuthFailure()` alone meant the shot never
            // fired unless the whole system auth dialog round-tripped to a
            // failure, which most interactions with the shield never reach.
            captureSnoopPhotoIfEnabled()
        }

        scheduleRevealHide()
    }

    /// Snapshots whoever's at the keyboard, once per lock. Gated on its own
    /// Settings toggle (default on) and silently skipped without Camera access.
    private func captureSnoopPhotoIfEnabled() {
        guard !hasCapturedThisLock else { return }
        let cameraEnabled = UserDefaults.standard.object(forKey: Constants.cameraOnFailedUnlockKey) as? Bool
            ?? Constants.defaultCameraOnFailedUnlock
        guard cameraEnabled else { return }
        hasCapturedThisLock = true
        CameraCapturer.captureAndSaveOnFailedUnlock()
    }

    /// Hide the mascot/message and drop back to the bare screenshot. Safe to call
    /// when nothing is showing.
    func dismissReveal() {
        revealHideTask?.cancel()
        revealHideTask = nil
        guard revealed else { return }
        revealed = false
    }

    private func scheduleRevealHide() {
        revealHideTask?.cancel()
        revealHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Constants.Timing.revealVisibleNs)
            guard !Task.isCancelled else { return }
            self?.dismissReveal()
        }
    }

    /// Quick unlock via hotkey — no auth.
    func quickUnlock() {
        guard state == .locked, !authenticationInProgress else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        unlock()
    }

    /// Fallback unlock via Touch ID / Mac password.
    func requestUnlock() {
        guard state == .locked, !authenticationInProgress else { return }

        // Rate limit after 3 failures
        if failCount >= Constants.Timing.maxAuthAttempts, let lastFail = lastAuthFailTime,
           Date().timeIntervalSince(lastFail) < Constants.Timing.authRateLimitCooldown {
            let remaining = Int(Constants.Timing.authRateLimitCooldown - Date().timeIntervalSince(lastFail))
            lastError = "Too many attempts. Wait \(remaining)s."
            scheduleErrorClear()
            return
        }

        guard transitionTo(.unlocking) else { return }
        authenticationInProgress = true
        isAuthenticating = true
        lastError = nil

        overlayManager.allowSystemDialogs()
        inputBlocker.stopBlocking()

        Task { @MainActor in
            let authenticated = await authenticator.authenticate()

            guard state == .unlocking else {
                authenticationInProgress = false
                isAuthenticating = false
                overlayManager.blockSystemDialogs()
                inputBlocker.startBlocking()
                return
            }

            authenticationInProgress = false
            isAuthenticating = false

            if authenticated {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                unlockSucceeded = true
                try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
                guard !Task.isCancelled else { return }
                unlock()
            } else {
                handleAuthFailure()
            }
        }
    }

    func requestPasswordUnlock() {
        guard state == .locked, !authenticationInProgress else { return }

        if failCount >= Constants.Timing.maxAuthAttempts, let lastFail = lastAuthFailTime,
           Date().timeIntervalSince(lastFail) < Constants.Timing.authRateLimitCooldown {
            let remaining = Int(Constants.Timing.authRateLimitCooldown - Date().timeIntervalSince(lastFail))
            lastError = "Too many attempts. Wait \(remaining)s."
            scheduleErrorClear()
            return
        }

        guard transitionTo(.unlocking) else { return }
        authenticationInProgress = true
        isAuthenticating = true
        lastError = nil

        overlayManager.allowSystemDialogs()
        inputBlocker.stopBlocking()

        Task { @MainActor in
            let authenticated = await authenticator.authenticateWithPassword()

            guard state == .unlocking else {
                authenticationInProgress = false
                isAuthenticating = false
                overlayManager.blockSystemDialogs()
                inputBlocker.startBlocking()
                return
            }

            authenticationInProgress = false
            isAuthenticating = false

            if authenticated {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                unlockSucceeded = true
                try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
                guard !Task.isCancelled else { return }
                unlock()
            } else {
                handleAuthFailure()
            }
        }
    }

    // MARK: - Private

    /// React to an agent ping. Debounces chatty agents, then pulses the lock screen
    /// and/or posts a notification per `PingDecision` (no-op when unlocked).
    private func handlePing() {
        let now = Date()
        if let last = lastPingTime, now.timeIntervalSince(last) < Constants.Timing.pingDebounce { return }
        lastPingTime = now

        let soundEnabled = UserDefaults.standard.bool(forKey: Constants.agentPingSoundKey)
        let decision = PingDecision.make(state: state, soundEnabled: soundEnabled)
        if decision.shouldPulse {
            pingPulse &+= 1
            agentAttention = true
        }
        if decision.shouldNotify { AgentNotifier.shared.notify(withSound: decision.withSound) }
    }

    private func handleAuthFailure() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        failCount += 1
        lastAuthFailTime = Date()
        lastError = failCount >= Constants.Timing.maxAuthAttempts ? "Too many attempts. Wait \(Int(Constants.Timing.authRateLimitCooldown)) seconds." : "Try again"

        // Also covered by `revealOnFirstInput()`, which fires far more reliably
        // (an explicit auth failure requires the whole Touch ID/password dialog
        // to round-trip); this just catches the case where that reveal somehow
        // didn't happen first. `captureSnoopPhotoIfEnabled()` no-ops past the
        // first shot per lock either way.
        captureSnoopPhotoIfEnabled()

        overlayManager.blockSystemDialogs()
        inputBlocker.startBlocking()
        transitionTo(.locked)
        scheduleErrorClear()
    }

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(nanoseconds: Constants.Timing.errorAutoClearNs)
            if !Task.isCancelled, lastError != nil { lastError = nil }
        }
    }

    @discardableResult
    private func transitionTo(_ newState: LockState) -> Bool {
        guard state.canTransition(to: newState) else {
            logger.warning("Invalid transition: \(String(describing: self.state)) → \(String(describing: newState))")
            return false
        }
        state = newState
        LockController.isAnyLockActive = (newState != .unlocked)
        return true
    }

    private func unlock() {
        revealHideTask?.cancel()
        revealHideTask = nil
        touchIDArmTask?.cancel()
        touchIDArmTask = nil
        touchIDContext = nil
        authenticator.cancelAll()
        stopAccessibilityMonitoring()
        stopTimer()
        errorClearTask?.cancel()
        lockStartTime = nil
        elapsedTime = 0
        clearAgentAttention()
        state = .unlocked
        overlayManager.dismissOverlay(animated: true)
        inputBlocker.stopBlocking()
        sleepPreventer.allowSleep()
    }

    private func forceUnlock() {
        revealHideTask?.cancel()
        revealHideTask = nil
        touchIDArmTask?.cancel()
        touchIDArmTask = nil
        touchIDContext = nil
        authenticationInProgress = false
        isAuthenticating = false
        authenticator.cancelAll()
        stopAccessibilityMonitoring()
        stopTimer()
        errorClearTask?.cancel()
        lockStartTime = nil
        elapsedTime = 0
        clearAgentAttention()
        state = .unlocked
        overlayManager.dismissOverlay()
        inputBlocker.stopBlocking()
        sleepPreventer.allowSleep()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Once unlocked, the agent banners in Notification Center are stale — the user
    /// is back at the machine. Drop the flag and the delivered notifications together.
    private func clearAgentAttention() {
        agentAttention = false
        AgentNotifier.shared.clearDelivered()
    }

    private func startAccessibilityMonitoring() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked, !AccessibilityChecker.isEnabled else { return }
                logger.critical("Accessibility revoked while locked — force unlocking")
                self.lastError = "Accessibility permission revoked"
                try? await Task.sleep(nanoseconds: Constants.Timing.errorDisplayBeforeForceUnlockNs)
                self.forceUnlock()
            }
        }
    }

    private func stopAccessibilityMonitoring() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }
}
