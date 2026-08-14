import Foundation
import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "in.pooya.flipoff", category: "LockVisual")

/// What fills the shield once someone touches the machine.
///
/// `.emoji` is the historical behaviour and stays the default: the giant glyph,
/// the lock message, and the lock sound. `.video` replaces all three with a
/// looping clip that carries its own audio — which is why picking it hides the
/// emoji, message, and sound rows in Settings rather than leaving them to fight
/// the video for the same moment.
///
/// Either way the shield stays bare until the first input; only what the reveal
/// shows changes.
enum LockVisual: String, CaseIterable, Identifiable {
    case emoji
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emoji: return "Emoji"
        case .video: return "Video"
        }
    }

    /// Subtitle for the Settings picker row — says what the choice takes away as
    /// much as what it gives, since switching to video hides three other rows.
    var settingsSubtitle: String {
        switch self {
        case .emoji: return "A giant glyph, your message, and your lock sound."
        case .video: return "A looping clip with its own audio, in place of all three."
        }
    }

    static let storageKey = "lockVisual"
    static let defaultValue: LockVisual = .emoji

    static func resolved(from raw: String?) -> LockVisual {
        guard let raw, let visual = LockVisual(rawValue: raw) else { return defaultValue }
        return visual
    }

    /// The visual currently in effect, read straight from defaults — for the
    /// non-SwiftUI callers (`LockController`) that can't use `@AppStorage`.
    static var current: LockVisual {
        resolved(from: UserDefaults.standard.string(forKey: storageKey))
    }
}

/// The clip shown in `LockVisual.video` mode: the bundled template, or one the
/// user imported.
///
/// Imports are **copied** into Application Support rather than referenced in
/// place. A lock screen that silently degrades to a black rectangle because the
/// source file was moved, renamed, or emptied out of Downloads is worse than no
/// video at all, and the clips are small. `resolvedURL` still falls back to the
/// template if the copy ever goes missing, so the video mode can't end up
/// pointing at nothing.
enum LockVideo {
    /// Filename (no extension) of the bundled template in Resources/Videos.
    static let templateResourceName = "creepy-face-jump-scare"
    static let templateDisplayName = "Creepy Face (built-in)"

    /// UserDefaults key holding the absolute path of an imported clip. Empty or
    /// absent means "use the template".
    static let storageKey = "lockVideoPath"
    static let defaultValue = ""

    /// Not a real path — the dropdown's last entry, which opens the file picker
    /// instead of selecting anything. A sentinel keeps importing inside the same
    /// control as choosing, rather than splitting it across a separate button.
    static let chooseSentinel = "__choose__"

    /// Extensions offered in the import panel. AVFoundation handles more, but
    /// these are the ones that reliably play without a codec surprise mid-lock.
    static let allowedContentTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie]

    static var templateURL: URL? {
        Bundle.main.url(forResource: templateResourceName, withExtension: "mp4", subdirectory: "Videos")
            ?? Bundle.main.url(forResource: templateResourceName, withExtension: "mp4")
    }

    /// Where imported clips live. Not the sandbox container (the app isn't
    /// sandboxed) — just a stable app-owned folder.
    static var importDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("FlipOff/Videos", isDirectory: true)
    }

    /// The clip to play, given the stored path. Falls back to the template when
    /// the stored path is empty or the file is gone.
    static func resolvedURL(from storedPath: String) -> URL? {
        guard !storedPath.isEmpty else { return templateURL }
        let url = URL(fileURLWithPath: storedPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("Imported lock video missing at \(storedPath, privacy: .public) — falling back to the template")
            return templateURL
        }
        return url
    }

    /// What Settings shows as the current choice. Uses the stored path's own
    /// filename even when the file has since vanished, so the row reflects what
    /// was picked rather than silently claiming the template is selected.
    static func displayName(for storedPath: String) -> String {
        guard !storedPath.isEmpty else { return templateDisplayName }
        return URL(fileURLWithPath: storedPath).lastPathComponent
    }

    static func isMissing(_ storedPath: String) -> Bool {
        !storedPath.isEmpty && !FileManager.default.fileExists(atPath: storedPath)
    }

    /// Every clip the user has imported, name-sorted. These accumulate on purpose:
    /// the dropdown is a library to switch between, not a single slot, so an
    /// import never silently discards the clip that was there before.
    static func importedVideos() -> [URL] {
        guard let directory = importDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return contents
            .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Menu contents for the Settings dropdown: the built-in first, then imports.
    ///
    /// `selectedPath` is passed in so a stored pick that has since been deleted
    /// from outside the app still gets a row — a `Picker` whose selection matches
    /// no tag renders blank, which would look like nothing is chosen at all.
    static func libraryOptions(selecting selectedPath: String) -> [(title: String, path: String)] {
        var options: [(title: String, path: String)] = [(templateDisplayName, "")]
        options.append(contentsOf: importedVideos().map { ($0.lastPathComponent, $0.path) })

        if !selectedPath.isEmpty, !options.contains(where: { $0.path == selectedPath }) {
            options.append(("\(URL(fileURLWithPath: selectedPath).lastPathComponent) (missing)", selectedPath))
        }
        return options
    }

    /// Copy a user-picked clip into `importDirectory` and return its new path.
    /// Throws rather than falling back silently — the caller surfaces the failure
    /// in Settings, where the user can still see which clip is actually in use.
    static func importVideo(from source: URL) throws -> String {
        guard let directory = importDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keep the original filename — it's what the dropdown shows, and a UUID
        // suffix on every import would make the menu unreadable. Only disambiguate
        // when the name is already taken, and never overwrite: replacing a file
        // some lock screen may be mid-playback on is a needless hazard.
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            suffix += 1
        }

        try FileManager.default.copyItem(at: source, to: destination)
        return destination.path
    }

    /// Remove one imported clip. The built-in template (empty path) is never
    /// deletable — it's the floor the video mode always has to fall back to.
    @discardableResult
    static func deleteImport(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    /// Open panel for picking a clip. Returns nil if the user cancels.
    @MainActor
    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Lock Video"
        panel.prompt = "Use Video"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedContentTypes
        return panel.runModal() == .OK ? panel.url : nil
    }
}
