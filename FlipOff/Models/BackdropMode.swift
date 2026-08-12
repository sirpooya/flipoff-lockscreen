import Foundation

/// What sits behind the lock UI.
///
/// `.frozen` is the original behaviour: photograph every display before the shield
/// goes up (see the capture-before-shield note in CLAUDE.md) and show the still.
///
/// `.live` skips the capture entirely and leaves the shield windows transparent, so
/// the real desktop keeps rendering underneath — notifications slide in, videos
/// play, spinners spin. Nothing below is reachable: the shield window at
/// `CGShieldingWindowLevel()` swallows the clicks by being there, and `InputBlocker`'s
/// event tap eats the keyboard regardless of what the window looks like.
///
/// The trade: `.frozen` hides what was on screen from a passerby, `.live` sells the
/// "this machine isn't locked" illusion. Screen Recording is only needed for `.frozen`.
/// Case order is the segmented-control order — Live sits on the left as the default.
enum BackdropMode: String, CaseIterable, Identifiable {
    case live
    case frozen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frozen: return "Frozen"
        case .live: return "Live"
        }
    }

    var subtitle: String {
        switch self {
        case .frozen: return "A screenshot, taken as the lock goes up. Needs Screen Recording."
        case .live: return "The real desktop, still moving — nothing behind is clickable."
        }
    }

    /// Only the frozen still goes through `ScreenCapturer`.
    var needsScreenCapture: Bool { self == .frozen }

    static let storageKey = "backdropMode"
    static let defaultValue: BackdropMode = .live

    static func resolved(from raw: String?) -> BackdropMode {
        guard let raw, let mode = BackdropMode(rawValue: raw) else { return defaultValue }
        return mode
    }

    /// The mode currently in effect, read straight from defaults — for the
    /// non-SwiftUI callers (`LockController`) that can't use `@AppStorage`.
    static var current: BackdropMode {
        resolved(from: UserDefaults.standard.string(forKey: storageKey))
    }
}
