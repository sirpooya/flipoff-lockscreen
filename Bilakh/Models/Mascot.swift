import Foundation

enum Mascot: String, CaseIterable, Identifiable {
    case dog
    case cat
    case emoji
    case finger
    case poop

    static let storageKey = "mascot"
    // The surprise is the whole point of this fork — default straight to it
    // rather than making the user opt in from the mascot picker.
    static let defaultValue = emoji.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dog: return "Dog"
        case .cat: return "Cat"
        case .emoji: return "Emoji"
        case .finger: return "Finger"
        case .poop: return "Poop"
        }
    }

    /// Only meaningful for the image-backed mascots; `.emoji` is rendered as text
    /// (see `EmojiMascot.storageKey`), not an asset catalog image.
    var assetName: String {
        switch self {
        case .dog: return "Mascot"
        case .cat: return "MascotCat"
        case .emoji: return ""
        case .finger: return "MascotFinger"
        case .poop: return "MascotPoop"
        }
    }

    static func resolved(from rawValue: String) -> Mascot {
        Mascot(rawValue: rawValue) ?? .dog
    }
}

/// The emoji shown by the `.emoji` mascot — stored separately from `Mascot` so
/// switching mascots never forgets the user's chosen glyph.
enum EmojiMascot {
    static let storageKey = "mascotEmoji"
    static let defaultValue = "🖕🏻"

    /// A short, curated set for the Settings picker. Any single emoji works via
    /// the custom-input field; these are just quick picks.
    static let suggestions = ["🖕🏻", "🖕🏼", "🖕🏽", "🖕🏾", "🖕🏿", "😈", "💀", "🙄", "😏", "🫵", "👻", "🎃"]

    static func resolved(from rawValue: String) -> String {
        rawValue.isEmpty ? defaultValue : rawValue
    }
}
