import AVFoundation
import AppKit

/// Camera permission, mirrored on `ScreenRecordingChecker`/`AccessibilityChecker`.
struct CameraChecker {
    /// True if camera access is already permitted. Does not prompt.
    static var isEnabled: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Triggers the system prompt if permission hasn't been decided yet. Safe to
    /// call repeatedly — a no-op once the user has answered either way.
    static func requestAccess(completion: @escaping (Bool) -> Void = { _ in }) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
