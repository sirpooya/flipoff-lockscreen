import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "in.pooya.flipoff", category: "OverlayWindow")

/// Borderless windows refuse key status by default; the primary overlay must be able
/// to become key so the app can be activated while locked — cursor concealment
/// (`NSCursor.setHiddenUntilMouseMoves`) only works while the app is active.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

class OverlayWindowManager {
    private var windows: [NSWindow] = []
    private var screenObserver: Any?
    private var sessionObserver: Any?
    private var contentFactory: ((Int, Bool) -> AnyView)?
    private var screenChangeWork: DispatchWorkItem?
    private var mouseMoveMonitors: [Any] = []
    private var cursorRehideTimer: Timer?
    private var keyObservers: [Any] = []
    /// Whether the shield has lost key status since it was raised. Only a *regained*
    /// key is worth telling `LockController` about — announcing the first one too
    /// would re-issue the Touch ID context during lock setup, and that churn
    /// cancelled the arming task before it ever reached `evaluatePolicy`, leaving an
    /// empty glyph and a sensor that was never listening.
    private var sawKeyLoss = false
    /// Frames the current windows were built for. `didChangeScreenParameters` fires
    /// for things that change no geometry at all (menu-bar autohide, a display
    /// waking, colour-profile churn), and each needless rebuild deallocates the
    /// embedded Touch ID view mid-read — the sensor comes back with -4 "View was
    /// deallocated". Rebuild only when the layout actually moved.
    private var builtForFrames: [CGRect] = []

    private let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    @discardableResult
    func showOverlay(
        contentFactory factory: @escaping (Int, Bool) -> AnyView
    ) -> Bool {
        contentFactory = factory
        dismissOverlay()
        createWindows()
        guard !windows.isEmpty else {
            logger.error("showOverlay failed — no windows created")
            return false
        }
        startObservingScreenChanges()
        startObservingSessionChanges()
        startObservingKeyChanges()
        startCursorConcealment()
        return true
    }

    func dismissOverlay(animated: Bool = false) {
        stopObservingScreenChanges()
        stopObservingSessionChanges()
        stopObservingKeyChanges()
        stopCursorConcealment()

        if animated {
            let windowsToClose = windows
            windows.removeAll()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in windowsToClose {
                    window.animator().alphaValue = 0
                }
            }, completionHandler: {
                // Delay cleanup so animation objects are fully released
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    for window in windowsToClose {
                        window.orderOut(nil)
                        window.contentView = nil
                    }
                }
            })
        } else {
            for window in windows {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            windows.removeAll()
        }
        builtForFrames = []
        sawKeyLoss = false
    }

    func allowSystemDialogs() {
        for window in windows { window.level = .statusBar }
    }

    func blockSystemDialogs() {
        for window in windows { window.level = shieldLevel }
    }

    private func createWindows() {
        guard let factory = contentFactory else {
            logger.error("No content factory to display in overlay")
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            logger.critical("No screens available — cannot create overlay")
            return
        }

        for (index, screen) in screens.enumerated() {
            let isPrimary = (index == 0)
            let content = factory(index, isPrimary)
            let frame = screen.frame
            logger.info("Creating overlay — screen: \(screen.localizedName), role: \(isPrimary ? "primary" : "ambient"), frame: \(frame.debugDescription), scale: \(screen.backingScaleFactor)")
            let window = OverlayWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(frame, display: true)
            window.level = shieldLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = !isPrimary
            window.hasShadow = false

            // NSHostingView defaults to autoresizingMask=0 (no flex), which can cause
            // the SwiftUI content to not fill the window on external/scaled displays.
            let hostingView = NSHostingView(rootView: content)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = window.contentLayoutRect
            window.contentView = hostingView

            if hostingView.frame.size != frame.size {
                logger.warning("Content view size mismatch — expected \(frame.size.debugDescription), got \(hostingView.frame.size.debugDescription)")
            }

            window.alphaValue = 0
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }

            windows.append(window)
        }

        builtForFrames = screens.map(\.frame)
        // Every path that builds windows has to claim key afterwards, not just the
        // initial `showOverlay` — a mid-lock rebuild produces a brand-new window
        // that nothing else would ever focus, and touch-to-unlock silently dies
        // with it.
        focusPrimaryWindow()
    }

    // MARK: - Key focus
    //
    // Touch-to-unlock hangs off this. `LAAuthenticationView` refuses to arm the
    // sensor unless its window is key — it logs "is not visible to user because …
    // is not key" and then quietly ignores every finger — so the shield holding
    // key status is a functional requirement, not a nicety.

    /// Activates the app and makes the primary shield key. Runs twice on purpose:
    /// `NSApp.activate` is asynchronous, and a `makeKey` issued in the same runloop
    /// turn can land before the activation and be dropped.
    private func focusPrimaryWindow() {
        guard let primary = windows.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        primary.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak primary] in
            guard let primary, primary.isVisible, !primary.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            primary.makeKey()
        }
    }

    private func startObservingKeyChanges() {
        stopObservingKeyChanges()

        // Focus stolen mid-lock (a background app raising a panel, a display wake)
        // disarms the sensor until the shield is key again. Take it back.
        let resign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window === self.windows.first,
                  // Stand down while the shield has deliberately stepped aside for
                  // a system dialog (the password fallback) — that modal needs key,
                  // and `allowSystemDialogs()` is what drops the level.
                  window.level == self.shieldLevel else { return }
            self.sawKeyLoss = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self,
                      let primary = self.windows.first,
                      primary.level == self.shieldLevel,
                      !primary.isKeyWindow else { return }
                logger.info("Shield lost key — reclaiming so Touch ID stays armed")
                self.focusPrimaryWindow()
            }
        }
        keyObservers.append(resign)

        let become = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window === self.windows.first,
                  self.sawKeyLoss else { return }
            self.sawKeyLoss = false
            // An arm that happened while the window wasn't key was ignored by the
            // framework; the context has to be re-issued so a fresh paired view
            // evaluates against a window that now qualifies.
            logger.info("Shield regained key — re-arming Touch ID")
            NotificationCenter.default.post(name: .flipOffOverlayDidBecomeKey, object: nil)
        }
        keyObservers.append(become)
    }

    private func stopObservingKeyChanges() {
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers.removeAll()
    }

    // MARK: - Cursor concealment

    /// Hide the pointer while locked, but never trap the user: the cursor reappears
    /// the moment the mouse moves (it's needed to reach the fallback-auth controls)
    /// and slips away again after a few seconds of stillness. NSCursor.hide() is
    /// deliberately avoided — an unbalanced hide would leave the pointer invisible
    /// while someone tries to click the unlock chevron.
    private func startCursorConcealment() {
        stopCursorConcealment()
        // setHiddenUntilMouseMoves only takes effect while the app is active — and
        // when locking via the global hotkey some other app is frontmost. Activate
        // and make the primary overlay key first, then hide on the next runloop turn
        // so the activation has landed.
        focusPrimaryWindow()
        NSCursor.setHiddenUntilMouseMoves(true)
        DispatchQueue.main.async {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        let onMove: () -> Void = { [weak self] in self?.scheduleCursorRehide() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in onMove() }) {
            mouseMoveMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            onMove()
            return event
        }) {
            mouseMoveMonitors.append(local)
        }
    }

    private func scheduleCursorRehide() {
        cursorRehideTimer?.invalidate()
        cursorRehideTimer = Timer.scheduledTimer(withTimeInterval: Constants.Timing.cursorIdleHide, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func stopCursorConcealment() {
        cursorRehideTimer?.invalidate()
        cursorRehideTimer = nil
        for monitor in mouseMoveMonitors { NSEvent.removeMonitor(monitor) }
        mouseMoveMonitors.removeAll()
        // Make sure the pointer isn't left hidden after unlock.
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func startObservingScreenChanges() {
        stopObservingScreenChanges()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Cancel any pending recreation — true debounce so only the last
            // notification in a burst triggers work.
            self.screenChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard NSScreen.screens.map(\.frame) != self.builtForFrames else {
                    logger.info("Screen parameters changed but layout is identical — keeping windows")
                    return
                }
                logger.info("Screen parameters changed — recreating overlay windows")
                // Do NOT call window.close() — closing during a fade-in animation
                // causes EXC_BAD_ACCESS in _NSWindowTransformAnimation dealloc.
                for window in self.windows {
                    window.animator().alphaValue = 0
                    window.orderOut(nil)
                    window.contentView = nil
                }
                self.windows.removeAll()

                // Nothing to re-capture: every shield is transparent, so a display
                // attached mid-lock just gets its own window over its own live
                // desktop.
                self.createWindows()
            }
            self.screenChangeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func stopObservingScreenChanges() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }

    private func startObservingSessionChanges() {
        stopObservingSessionChanges()
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .flipOffSessionLost, object: nil)
        }
    }

    private func stopObservingSessionChanges() {
        if let observer = sessionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sessionObserver = nil
        }
    }

    deinit {
        stopObservingScreenChanges()
        stopObservingSessionChanges()
        stopObservingKeyChanges()
        stopCursorConcealment()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }
}
