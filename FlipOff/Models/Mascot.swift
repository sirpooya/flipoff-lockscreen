import Foundation

/// The emoji shown full-screen while locked. An emoji glyph is system-rendered
/// text, not a bitmap, so it scales to any display size with zero pixelation —
/// the reason there's no separate image-mascot option here anymore.
enum EmojiMascot {
    static let storageKey = "mascotEmoji"
    static let defaultValue = "🖕"

    /// A short set of quick picks for the Settings row. The full macOS Character
    /// Viewer (wired up in SettingsView) covers everything else.
    static let suggestions = ["🖕", "😈", "💀", "💩", "😏", "👻", "🎃"]

    static func resolved(from rawValue: String) -> String {
        rawValue.isEmpty ? defaultValue : rawValue
    }
}
