import AppKit
import CoreGraphics
import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "in.pooya.flipoff", category: "ScreenCapture")

extension NSScreen {
    /// The CoreGraphics display ID behind this screen — the only stable key that
    /// matches an `NSScreen` to an `SCDisplay`. Screen order and frames both shift
    /// on hot-plug, so neither can be used for the pairing.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Freezes one screenshot per physical display, taken in the instant before the
/// lock overlay appears.
///
/// Ordering is load-bearing: the overlay windows sit at `CGShieldingWindowLevel()`,
/// so capturing after they were on screen would photograph our own lock screen.
/// `LockController` awaits this *before* `showOverlay`, and the hot-plug path
/// deliberately reuses these cached images instead of re-capturing.
enum ScreenCapturer {

    /// Captures every active display, keyed by display ID.
    ///
    /// Never throws and never blocks the lock indefinitely: permission denial, an
    /// SCK error, or a hung capture all resolve to a missing entry, and the lock
    /// screen falls back to its gradient. Failing to capture must never mean
    /// failing to lock.
    static func captureAllDisplays(
        timeout: TimeInterval = Constants.Timing.captureTimeout
    ) async -> [CGDirectDisplayID: CGImage] {
        guard ScreenRecordingChecker.isEnabled else {
            logger.notice("Screen Recording not granted — falling back to desktop wallpaper")
            return await wallpaperBackdrops()
        }
        guard let captured = await withTimeout(timeout, operation: { await capture() }) else {
            logger.error("Capture exceeded \(timeout, format: .fixed(precision: 1))s — falling back to desktop wallpaper")
            return await wallpaperBackdrops()
        }
        // A partial capture still leaves some screens blank — backfill those from
        // the wallpaper rather than dropping them to the bare gradient.
        if captured.isEmpty {
            return await wallpaperBackdrops()
        }
        return captured
    }

    /// Backdrops read straight from each screen's desktop picture. Unlike
    /// ScreenCaptureKit this needs no Screen Recording grant — `desktopImageURL`
    /// is a plain file URL — so it keeps the lock screen from falling all the way
    /// back to a flat gradient when the permission is missing or still pending.
    ///
    /// It shows the wallpaper rather than the live desktop, so windows and their
    /// contents are never revealed — which also makes it the safer failure mode.
    @MainActor
    private static func wallpaperBackdrops() -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]
        let workspace = NSWorkspace.shared

        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let url = workspace.desktopImageURL(for: screen),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            result[id] = image
        }

        logger.info("Wallpaper backdrop for \(result.count) of \(NSScreen.screens.count) display(s)")
        return result
    }

    /// Captures only the given displays — used to backfill a screen that was
    /// hot-plugged in mid-lock without re-shooting displays that already have a
    /// still. Same timeout/never-throws contract as `captureAllDisplays`.
    static func captureDisplays(
        _ ids: [CGDirectDisplayID],
        timeout: TimeInterval = Constants.Timing.captureTimeout
    ) async -> [CGDirectDisplayID: CGImage] {
        guard !ids.isEmpty, ScreenRecordingChecker.isEnabled else { return [:] }
        let idSet = Set(ids)
        guard let captured = await withTimeout(timeout, operation: { await capture(only: idSet) }) else {
            logger.error("Backfill capture exceeded \(timeout, format: .fixed(precision: 1))s")
            return [:]
        }
        return captured
    }

    // MARK: - Private

    private static func capture(only ids: Set<CGDirectDisplayID>? = nil) async -> [CGDirectDisplayID: CGImage] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            // Backing scale lives on NSScreen, not SCDisplay — without it a Retina
            // display would be captured at point size and upscaled to fit.
            let scales = await scaleByDisplayID()
            let displays = ids.map { wanted in content.displays.filter { wanted.contains($0.displayID) } } ?? content.displays

            var result: [CGDirectDisplayID: CGImage] = [:]
            for display in displays {
                do {
                    result[display.displayID] = try await captureImage(
                        of: display,
                        scale: scales[display.displayID] ?? 2
                    )
                } catch {
                    // One unreadable display shouldn't cost the others their backdrop.
                    logger.error("Capture failed for display \(display.displayID): \(error.localizedDescription)")
                }
            }
            logger.info("Captured \(result.count) of \(displays.count) display(s)")
            return result
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            return [:]
        }
    }

    private static func captureImage(of display: SCDisplay, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.captureResolution = .best
        config.scalesToFit = false
        // The pointer is redrawn by the overlay's own cursor handling; baking it
        // into the still would leave a second, frozen cursor on screen.
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    private static func scaleByDisplayID() -> [CGDirectDisplayID: CGFloat] {
        var map: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { map[id] = screen.backingScaleFactor }
        }
        return map
    }

    /// Races `operation` against a sleep, returning nil if the sleep wins. Guards
    /// the `.locking` state from a capture that never comes back — otherwise the
    /// hotkey would be dead until relaunch.
    private static func withTimeout<T>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
