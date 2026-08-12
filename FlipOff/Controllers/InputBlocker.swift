import Cocoa
import Carbon
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "InputBlocker")

class InputBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isBlocking = false
    private static let inputQueue = DispatchQueue(label: "in.pooya.bilakh.input", qos: .userInteractive)

    /// Cached hotkey values — read once, used in the event tap callback
    /// to avoid hitting UserDefaults on every keystroke.
    var cachedKeyCode: Int64 = Int64(HotkeyConfig.defaultKeyCode)
    var cachedModifiers: Int = HotkeyConfig.defaultModifiers

    private var hotkeyObserver: NSObjectProtocol?

    private static let eventMask: CGEventMask = {
        // Clicks and drags are swallowed alongside keys — without them the shield
        // is only visual and a click lands on whatever sits underneath. Bare
        // `.mouseMoved` is deliberately absent: the cursor should still glide over
        // the lock screen, it just must not be able to actuate anything.
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .scrollWheel,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .tabletPointer, .tabletProximity
        ]
        return types.reduce(CGEventMask(0)) { mask, type in mask | (1 << type.rawValue) }
    }()

    init() {
        reloadHotkeyConfig()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .bilakhHotkeyPreferenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadHotkeyConfig()
        }
    }

    /// Refresh cached hotkey key-code and modifiers from HotkeyConfig.
    func reloadHotkeyConfig() {
        cachedKeyCode = Int64(HotkeyConfig.keyCode)
        cachedModifiers = HotkeyConfig.modifiers
    }

    func startBlocking() {
        guard !isBlocking else { return }

        // Ensure cached values are fresh before installing the tap.
        reloadHotkeyConfig()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async {
                        if let refcon = refcon {
                            let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()
                            if let tap = blocker.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                        }
                    }
                    return nil
                }

                if type == .keyDown {
                    let flags = event.flags
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                    guard let refcon = refcon else { return nil }
                    let blocker = Unmanaged<InputBlocker>.fromOpaque(refcon).takeUnretainedValue()

                    // Use cached hotkey values instead of reading UserDefaults
                    let savedKeyCode = blocker.cachedKeyCode
                    let savedMods = blocker.cachedModifiers

                    var modifiersMatch = true
                    if savedMods & cmdKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskCommand) }
                    if savedMods & shiftKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskShift) }
                    if savedMods & optionKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskAlternate) }
                    if savedMods & controlKey != 0 { modifiersMatch = modifiersMatch && flags.contains(.maskControl) }

                    // Let the unlock hotkey through
                    if modifiersMatch && keyCode == savedKeyCode {
                        InputBlocker.inputQueue.async {
                            NotificationCenter.default.post(name: .toggleBilakh, object: nil)
                        }
                        return nil
                    }

                    // Esc dismisses an already-revealed gag immediately, without
                    // waiting out the 5s auto-hide — same escape you'd expect from
                    // any modal, it just doesn't unlock anything.
                    if keyCode == 53 {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .bilakhDismissReveal, object: nil)
                        }
                        return nil
                    }

                    #if DEBUG
                    if flags.contains(.maskCommand) && flags.contains(.maskShift) && keyCode == 12 {
                        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                        return nil
                    }
                    #endif
                }

                // Any other swallowed key or click is someone trying to use the
                // machine — wake the lock screen so it reveals itself.
                switch type {
                case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .bilakhInputAttempt, object: nil)
                    }
                default:
                    break
                }

                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap = eventTap else {
            logger.error("Could not create event tap")
            NotificationCenter.default.post(name: .bilakhInputBlockerFailed, object: nil)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isBlocking = true
    }

    func stopBlocking() {
        guard isBlocking else { return }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isBlocking = false
    }

    deinit {
        stopBlocking()
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
