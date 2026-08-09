import Foundation

/// All notification names in one place.
extension Notification.Name {
    static let bilakhLock = Notification.Name("bilakhLock")
    static let bilakhUnlock = Notification.Name("bilakhUnlock")
    static let bilakhUnlockPassword = Notification.Name("bilakhUnlockPassword")
    static let bilakhInputBlockerFailed = Notification.Name("bilakhInputBlockerFailed")
    static let bilakhSessionLost = Notification.Name("bilakhSessionLost")
    static let toggleBilakh = Notification.Name("toggleBilakh")
    static let bilakhHotkeyPreferenceChanged = Notification.Name("bilakhHotkeyPreferenceChanged")
    /// Posted when an AI agent pings (bridged from the distributed notification, or fired by the in-app test button).
    static let bilakhPing = Notification.Name("bilakhPing")
}
