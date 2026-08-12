import SwiftUI
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "App")

@main
struct BilakhApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var lockController = LockController()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: lockController)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(lockController.state == .locked ? 1.0 : 0.55)
        }

        Settings {
            SettingsView()
        }
    }

    init() {
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            if !AccessibilityChecker.isEnabled {
                logger.warning("Accessibility permission not granted — hotkey and input blocking will not work until re-granted")
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyManager = HotkeyManager()
    private var hotkeyObserver: Any?
    private var accessibilityPollTimer: Timer?
    private var lastURLSchemeCall: Date = .distantPast
    private var onboardingWindow: NSWindow?
    private var pingDistributedObserver: Any?
    private var showOnboardingObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instantiate AgentNotifier now so it registers as the notification-center
        // delegate before launch completes (required for foreground banner presentation).
        _ = AgentNotifier.shared

        // Starts Sparkle's scheduled check cycle. Safe at launch: the updater only
        // hits the network on its own schedule, and its delegate refuses any check
        // while a lock is up.
        _ = UpdateController.shared

        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            requestScreenRecordingIfNeeded()
        }

        // Apply saved appearance
        let mode = UserDefaults.standard.integer(forKey: "appearanceMode")
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }

        // Only register hotkey if onboarding is complete (Accessibility granted).
        // Otherwise, wait for onboarding to finish and post the notification.
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            let enabled = HotkeyConfig.enabled
            hotkeyManager.setEnabled(enabled)

            // If Accessibility isn't granted yet (e.g., TCC invalidated after update),
            // poll until it's restored and then register the hotkey.
            if enabled && !hotkeyManager.isRegistered {
                startAccessibilityPoll()
            }
        }

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .bilakhHotkeyPreferenceChanged, object: nil, queue: nil
        ) { [weak self] notification in
            DispatchQueue.main.async {
                if let enabled = notification.userInfo?["enabled"] as? Bool {
                    self?.hotkeyManager.setEnabled(enabled)
                } else {
                    // Key combo changed or onboarding completed — re-register.
                    // Delay to let Settings activate the event pipeline first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.hotkeyManager.reregister()
                        // If registration still failed (TCC not yet updated), poll for it
                        if let self, !self.hotkeyManager.isRegistered {
                            self.startAccessibilityPoll()
                        }
                    }
                }
            }
        }

        // Bridge agent pings (posted by the `bilakh` CLI via DistributedNotificationCenter)
        // into a local notification. Using the distributed center — not the bilakh:// URL
        // scheme — means a background ping never launches the app when it isn't running.
        pingDistributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Constants.pingDistributedName), object: nil, queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .bilakhPing, object: nil)
        }

        showOnboardingObserver = NotificationCenter.default.addObserver(
            forName: .bilakhShowOnboarding, object: nil, queue: .main
        ) { [weak self] notification in
            self?.showOnboarding(startingAt: notification.object as? Int ?? 0)
        }

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else if !AccessibilityChecker.isEnabled {
            // TCC was reset (e.g., after update) — re-show onboarding to guide re-granting
            logger.notice("Accessibility revoked — re-showing onboarding")
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            showOnboarding()
        }
    }

    /// Ask for Screen Recording at launch or right after onboarding — never mid-lock.
    /// `CGRequestScreenCaptureAccess` can block until the user answers, and blocking
    /// inside `lock()` would freeze the app with no shield raised. Denial is
    /// non-fatal: the lock screen falls back to its gradient, so nothing gates on
    /// the result.
    private func requestScreenRecordingIfNeeded() {
        guard !ScreenRecordingChecker.isEnabled else { return }
        DispatchQueue.global(qos: .utility).async {
            ScreenRecordingChecker.requestAccess()
        }
    }

    /// - Parameter step: which step to open on. The real first run always passes 0;
    ///   anything else comes from the Debug menu, which exists so a step can be
    ///   looked at without wiping `hasCompletedOnboarding` and restarting.
    private func showOnboarding(startingAt step: Int = 0) {
        // Reopening replaces any window already up, otherwise picking a second
        // step from the menu would silently do nothing.
        onboardingWindow?.close()
        onboardingWindow = nil

        let view = OnboardingView(
            hasCompletedOnboarding: Binding(
                get: { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding")
                    if newValue {
                        self.onboardingWindow?.close()
                        self.onboardingWindow = nil
                    }
                }
            ),
            startingAt: step
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to Bilakh"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func startAccessibilityPoll() {
        accessibilityPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AccessibilityChecker.isEnabled {
                timer.invalidate()
                self.accessibilityPollTimer = nil
                logger.info("Accessibility granted — registering hotkey")
                self.hotkeyManager.reregister()
            }
        }
        accessibilityPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let now = Date()
        guard now.timeIntervalSince(lastURLSchemeCall) > Constants.Timing.urlSchemeDebounce else { return }
        lastURLSchemeCall = now

        for url in urls {
            guard url.scheme == Constants.urlScheme else { continue }
            switch url.host {
            case "lock": NotificationCenter.default.post(name: .bilakhLock, object: nil)
            case "unlock": NotificationCenter.default.post(name: .bilakhUnlock, object: nil)
            case "unlock-password": NotificationCenter.default.post(name: .bilakhUnlockPassword, object: nil)
            case "toggle": NotificationCenter.default.post(name: .toggleBilakh, object: nil)
            #if DEBUG
            // `bilakh://onboarding?step=3` — reopens the welcome flow on one step
            // (3 being the lock demo) without wiping `hasCompletedOnboarding` and
            // relaunching. Debug builds only; nothing in the UI exposes it.
            case "onboarding":
                let step = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "step" }?.value
                NotificationCenter.default.post(
                    name: .bilakhShowOnboarding, object: Int(step ?? "") ?? 0
                )
            #endif
            default: logger.warning("Unknown URL scheme: \(url.host ?? "nil")")
            }
        }
    }

    deinit {
        if let obs = hotkeyObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = pingDistributedObserver { DistributedNotificationCenter.default().removeObserver(obs) }
        if let obs = showOnboardingObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
