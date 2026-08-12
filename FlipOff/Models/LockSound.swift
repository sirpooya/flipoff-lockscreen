import Foundation

/// The sound played on lock/unlock. Bundled as plain MP3 resources under
/// Resources/Sounds — AVAudioPlayer loads them directly, no asset catalog entry
/// needed for audio.
enum LockSound: String, CaseIterable, Identifiable {
    case none
    case normalFart
    case wetFart
    case ahah
    case bazinga
    case muaHaHa
    case alert
    case snoopAlert

    static let storageKey = "lockSound"
    static let defaultValue = none.rawValue

    /// Raw values are what sit in `UserDefaults`, so renaming a case orphans the
    /// choice of anyone who had picked it — `resolved(from:)` would fall through to
    /// `.none` and their sound would silently switch off on update. Old raw value →
    /// current case.
    private static let renamed: [String: LockSound] = ["intruderAlert": .snoopAlert]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .normalFart: return "Normal Fart"
        case .wetFart: return "Wet Fart"
        case .ahah: return "Ahah"
        case .bazinga: return "Bazinga"
        case .muaHaHa: return "Mua Ha Ha"
        case .alert: return "Alert"
        case .snoopAlert: return "Snoop Alert"
        }
    }

    /// Resource filename (without extension) in Resources/Sounds. Nil for `.none`.
    var resourceName: String? {
        switch self {
        case .none: return nil
        case .normalFart: return "normal-fart"
        case .wetFart: return "wet-fart"
        case .ahah: return "ahah"
        case .bazinga: return "bazinga"
        case .muaHaHa: return "mua-ha-ha"
        case .alert: return "alert"
        case .snoopAlert: return "snoop-alert"
        }
    }

    static func resolved(from rawValue: String) -> LockSound {
        LockSound(rawValue: rawValue) ?? renamed[rawValue] ?? .none
    }
}
