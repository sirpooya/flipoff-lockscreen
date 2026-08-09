import AppKit
import CoreGraphics

/// Screen Recording permission, mirrored on `AccessibilityChecker`.
///
/// Unlike camera/microphone there is no Info.plist usage-description key for
/// screen capture — the string in the system prompt comes from the OS, and the
/// grant is keyed to the app's code signature. Ad-hoc ("Sign to Run Locally")
/// builds get a fresh signature on some rebuilds, which is why the permission can
/// appear to reset during development.
struct ScreenRecordingChecker {
    /// True if screen capture is already permitted. Does not prompt.
    static var isEnabled: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt if permission hasn't been decided yet. Returns
    /// the current grant state — false while the user is still deciding, so the
    /// caller must not treat it as a hard denial.
    @discardableResult
    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
