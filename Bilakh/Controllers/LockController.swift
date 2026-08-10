import Foundation
import Combine
import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "LockController")

@MainActor
class LockController: ObservableObject {
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
    private var accessibilityCheckTimer: Timer?
    private var errorClearTask: Task<Void, Never>?
    private var toggleObserver: Any?
    private var pingObserver: Any?
    private var authenticationInProgress = false
    private var sessionWasLost = false
    private var lastAuthFailTime: Date?
    private var lastPingTime: Date?
    private var touchIDAutoUnlockTask: Task<Void, Never>?
    private var revealHideTask: Task<Void, Never>?

    init() {
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleBilakh, object: nil, queue: .main
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

        inputAttemptObserver = NotificationCenter.default.addObserver(
            forName: .bilakhInputAttempt, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revealOnFirstInput()
            }
        }

        dismissRevealObserver = NotificationCenter.default.addObserver(
            forName: .bilakhDismissReveal, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissReveal()
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
            forName: .bilakhSessionLost, object: nil, queue: .main
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
            forName: .bilakhInputBlockerFailed, object: nil, queue: .main
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
            forName: .bilakhPing, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handlePing()
            }
        }
    }

    deinit {
        if let obs = toggleObserver { NotificationCenter.default.removeObserver(obs) }
        timer?.invalidate()
        accessibilityCheckTimer?.invalidate()
        errorClearTask?.cancel()
        if let obs = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = sessionLostObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = sessionActiveObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = inputBlockerFailedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = pingObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = inputAttemptObserver { NotificationCenter.default.removeObserver(obs) }
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

        // Photograph the desktop *before* the shield goes up — the overlay sits at
        // CGShieldingWindowLevel, so a capture taken afterwards would show the lock
        // screen instead of the desktop. Bounded internally by captureTimeout so a
        // stalled capture can't strand us in .locking with a dead hotkey.
        Task { @MainActor in
            let backdrops = await ScreenCapturer.captureAllDisplays()
            self.presentOverlay(backdrops: backdrops)
        }
    }

    /// Second half of `lock()`, resumed once the screenshots are in hand.
    private func presentOverlay(backdrops: [CGDirectDisplayID: CGImage]) {
        // A force-unlock or a failed transition during the capture window leaves
        // .locking behind — don't raise a shield the user already escaped.
        guard state == .locking else {
            logger.info("Lock aborted during capture — state is \(String(describing: self.state))")
            sleepPreventer.allowSleep()
            return
        }

        guard overlayManager.showOverlay(backdrops: backdrops, contentFactory: { [weak self] index, isPrimary, backdrop in
            guard let self else { return AnyView(Color.black) }
            if isPrimary {
                return AnyView(LockScreenView(
                    controller: self,
                    screenRole: .primary,
                    phaseOffset: CGFloat(index) * 0.15,
                    backdrop: backdrop
                ))
            } else {
                return AnyView(AmbientBackdropHost(controller: self, index: index, backdrop: backdrop))
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
        startTouchIDAutoUnlockIfNeeded()
    }

    /// Quietly re-arms Touch ID in the background while locked, so resting a
    /// finger on the sensor unlocks immediately — no hotkey needed. Re-arms
    /// after every failed/cancelled read until unlocked or the setting is off.
    ///
    /// Deliberately does NOT set `authenticationInProgress`: that flag gates
    /// `quickUnlock()`/`requestUnlock()`, so holding it across a ~30s pending
    /// biometric read would bolt the hotkey shut and strand the user behind the
    /// shield. This is a passive listener — it must never block a manual unlock.
    /// It also uses its own LAContext (`biometricContextOwner: .autoUnlock`) so
    /// a manual auth can cancel it without the two clobbering each other.
    private func startTouchIDAutoUnlockIfNeeded() {
        touchIDAutoUnlockTask?.cancel()
        // Always armed — a finger on the sensor is unconditionally a valid way
        // in, independent of the "Require authentication" preference (which only
        // governs whether the *hotkey* still needs auth). No toggle of its own.
        //
        // Macs without a sensor (or with none enrolled) fail the policy check
        // instantly, which would turn the re-arm loop into a busy spin.
        guard authenticator.isBiometricsAvailable else { return }

        touchIDAutoUnlockTask = Task { @MainActor [weak self] in
            while let self, self.state == .locked, !Task.isCancelled {
                // Stand down while a manual auth owns the sensor, then re-arm.
                if self.authenticationInProgress {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                let authenticated = await self.authenticator.authenticateWithBiometricsOnly()

                guard self.state == .locked, !Task.isCancelled else { return }

                if authenticated {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    self.unlockSucceeded = true
                    try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
                    guard !Task.isCancelled else { return }
                    self.unlock()
                    return
                }

                // Brief pause before re-arming so a failed/cancelled read doesn't spin hot.
                try? await Task.sleep(nanoseconds: 800_000_000)
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
            SoundPlayer.play(LockSound.resolved(from: UserDefaults.standard.string(forKey: LockSound.storageKey) ?? LockSound.defaultValue))
        }

        scheduleRevealHide()
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

        // Only on an actual failed unlock attempt — never on lock, never on
        // success, never just for touching a key. One snapshot per failure.
        CameraCapturer.captureAndSaveOnFailedUnlock()

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
        return true
    }

    private func unlock() {
        touchIDAutoUnlockTask?.cancel()
        touchIDAutoUnlockTask = nil
        revealHideTask?.cancel()
        revealHideTask = nil
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
        touchIDAutoUnlockTask?.cancel()
        touchIDAutoUnlockTask = nil
        revealHideTask?.cancel()
        revealHideTask = nil
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
