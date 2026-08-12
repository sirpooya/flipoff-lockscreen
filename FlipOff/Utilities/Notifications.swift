import Foundation

/// All notification names in one place.
extension Notification.Name {
    static let flipOffLock = Notification.Name("flipOffLock")
    static let flipOffUnlock = Notification.Name("flipOffUnlock")
    static let flipOffUnlockPassword = Notification.Name("flipOffUnlockPassword")
    static let flipOffInputBlockerFailed = Notification.Name("flipOffInputBlockerFailed")
    /// Posted on the first key/click swallowed by the shield — wakes the lock screen.
    static let flipOffInputAttempt = Notification.Name("flipOffInputAttempt")
    /// Posted on Esc while locked — hides an already-revealed gag immediately.
    static let flipOffDismissReveal = Notification.Name("flipOffDismissReveal")
    static let flipOffSessionLost = Notification.Name("flipOffSessionLost")
    static let toggleFlipOff = Notification.Name("toggleFlipOff")
    static let flipOffHotkeyPreferenceChanged = Notification.Name("flipOffHotkeyPreferenceChanged")
    /// Posted when an AI agent pings (bridged from the distributed notification, or fired by the in-app test button).
    static let flipOffPing = Notification.Name("flipOffPing")
    /// Reopens the onboarding window, optionally on a given step (`object` is the
    /// step index as an `Int`). Observed by `AppDelegate`, which owns that window —
    /// the menu-bar item that posts this only exists while the menu is open, so a
    /// view could never observe it in time.
    static let flipOffShowOnboarding = Notification.Name("flipOffShowOnboarding")
}
