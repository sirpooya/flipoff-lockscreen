import Foundation
import Sparkle
import SwiftUI
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "Update")

/// Sparkle wrapper. Owns the one `SPUStandardUpdaterController` for the process and
/// publishes `canCheckForUpdates` so the menu item can disable itself while a check
/// is already running.
///
/// Two Bilakh-specific behaviours live in the delegate below:
///
/// - **Never interrupt a lock.** Sparkle would otherwise be free to raise its
///   "update available" sheet while the shield is up. The shield sits at
///   `CGShieldingWindowLevel()`, so the sheet would either be swallowed underneath it
///   or, worse, land on top of the lock screen and offer a relaunch — an escape hatch
///   out of a lock that is supposed to require the hotkey or Touch ID.
/// - **Foreground for the dialog.** The app is `LSUIElement`, so it has no Dock tile
///   and never becomes active on its own. Sparkle's windows would open unfocused
///   behind whatever the user is doing. We flip to `.regular` while a Sparkle window
///   is on screen and drop back to `.accessory` afterwards.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?

    private override init() {
        super.init()

        // startingUpdater: true — begins the scheduled background check cycle using
        // SUScheduledCheckInterval from Info.plist.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Explicit "Check for Updates…" from the menu bar or Settings.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {
    /// Gate every check — scheduled and manual — on the lock being down.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let locked = MainActor.assumeIsolated { LockController.isAnyLockActive }
        guard !locked else {
            logger.info("Suppressing update check — screen is locked")
            throw NSError(
                domain: "in.pooya.bilakh.update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bilakh doesn't check for updates while the screen is locked."]
            )
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateController: SPUStandardUserDriverDelegate {
    /// Sparkle asks before showing any of its own windows. `LSUIElement` apps have to
    /// opt into being activatable or the window opens behind everything, unfocused.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {}

    /// Back to a pure menu-bar app once Sparkle is done with the screen.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
