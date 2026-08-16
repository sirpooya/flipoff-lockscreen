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
    /// Posted when the primary shield window (re)gains key status. The embedded
    /// Touch ID view refuses to arm the sensor while its window isn't key ("is not
    /// visible to user because … is not key"), so `LockController` re-issues its
    /// context here to rebuild the view against a window that now qualifies.
    static let flipOffOverlayDidBecomeKey = Notification.Name("flipOffOverlayDidBecomeKey")
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
