import Foundation

/// The sound played on lock/unlock. Bundled as plain MP3 resources under
/// Resources/Sounds — AVAudioPlayer loads them directly, no asset catalog entry
/// needed for audio.
enum LockSound: String, CaseIterable, Identifiable {
    case none
    case normalFart
    case wetFart

    static let storageKey = "lockSound"
    static let defaultValue = none.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .normalFart: return "Normal"
        case .wetFart: return "Wet"
        }
    }

    /// Resource filename (without extension) in Resources/Sounds. Nil for `.none`.
    var resourceName: String? {
        switch self {
        case .none: return nil
        case .normalFart: return "normal-fart"
        case .wetFart: return "wet-fart"
        }
    }

    static func resolved(from rawValue: String) -> LockSound {
        LockSound(rawValue: rawValue) ?? .none
    }
}
