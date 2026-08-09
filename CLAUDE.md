# Bilakh

A menu-bar "screensaver" that isn't a real `.saver` — the macOS screensaver engine
dismisses on any key/mouse input, which can't honor a single custom unlock hotkey.
Bilakh is a background app (`LSUIElement`) that raises borderless, shielded windows
over every display, shows a frozen screenshot of the desktop behind a giant emoji
(default 🖕🏻), and refuses to go away except via its hotkey or Touch ID/password.

Forked from [lockpaw](https://github.com/sorkila/lockpaw) (MIT). Bundle id prefix
`in.pooya`, Team ID `37MA269X54`.

## Architecture

```
BilakhApp (SwiftUI @main)
  └─ AppDelegate: hotkey lifecycle, onboarding, URL scheme, distributed-notification bridge
LockController (ObservableObject, single source of truth for lock state)
  ├─ ScreenCapturer      — SCK screenshot per display, before the shield goes up
  ├─ OverlayWindowManager — one NSWindow per NSScreen at CGShieldingWindowLevel()
  ├─ InputBlocker        — CGEventTap swallowing keyboard/scroll/tablet input
  ├─ Authenticator       — Touch ID / password via LocalAuthentication
  └─ SleepPreventer      — IOPM assertion, blocks idle display sleep while locked
HotkeyManager — global hotkey registration (separate from InputBlocker's tap)
```

`LockState` (Models/LockState.swift) is a small state machine: `unlocked → locking →
locked → unlocking → unlocked`, plus a `canTransition` guard. Everything in
`LockController` goes through `transitionTo`, never sets `state` directly.

## Load-bearing ordering

**Capture before shield.** `ScreenCapturer.captureAllDisplays()` must run and
complete *before* `OverlayWindowManager.showOverlay` — the overlay sits at
`CGShieldingWindowLevel()`, so a capture taken after the windows are up would
photograph the lock screen itself, not the desktop. `LockController.lock()` awaits
the capture in a `Task`, then calls `presentOverlay(backdrops:)`. If a force-unlock
races the capture and wins, `presentOverlay` checks `state == .locking` and bails
without raising a shield the user already escaped.

**Match displays by ID, never by index or frame.** `NSScreen.screens` reorders on
hot-plug; `CGDirectDisplayID` (via `NSScreen.displayID`, `Utilities: NSScreen`
extension in ScreenCapturer.swift) is the only stable key shared between
`NSScreen` and `SCDisplay`. Backdrops are stored `[CGDirectDisplayID: CGImage]` in
`OverlayWindowManager`, matched at window-creation time.

**Hot-plug reuses cached backdrops, never re-captures wholesale.** The screen-change
handler in `OverlayWindowManager` recreates all windows (existing lockpaw behavior)
but only re-shoots displays missing from the held `backdrops` dict
(`displayIDsMissingBackdrop()` → `ScreenCapturer.captureDisplays(_:)`). Re-capturing
everything would, again, photograph the already-visible shield on unaffected
displays.

**Screen Recording is requested at launch, never mid-lock.**
`CGRequestScreenCaptureAccess()` can block on the user's answer; blocking inside
`lock()` would freeze the app with no shield raised yet. See
`AppDelegate.requestScreenRecordingIfNeeded()`. Denial is non-fatal everywhere —
missing backdrop just means gradient/ambient-blob fallback, never a failed lock.

## Signing

`project.yml` sets `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 37MA269X54` on
**all three targets** (`Bilakh`, `BilakhCLI`, `BilakhTests`) — a real Apple
Development identity, not ad-hoc. This matters twice:

- Ad-hoc signatures can change across rebuilds, and macOS ties TCC grants (Screen
  Recording, Accessibility) to the signature — an ad-hoc rebuild can silently
  reset permissions.
- If any one target loses its `DEVELOPMENT_TEAM` (e.g. copy-pasting a new target
  block), `xcodebuild test` fails with a cryptic `dlopen ... different Team IDs`
  error — the test bundle gets injected into a host process signed under a
  different team. Check `codesign -dv .../BilakhTests.xctest | grep TeamIdentifier`
  first if this reappears.

No Developer ID / notarization — that needs a paid Program enrollment issuing a
Developer ID Application cert, which isn't in the keychain. Fine for local use on
your own Macs; would show Gatekeeper warnings if ever distributed as a `.dmg`.

## Mascot / emoji

`Models/Mascot.swift` has three cases: `.dog`, `.cat` (original lockpaw art), and
`.emoji` (default). `EmojiMascot` (same file) stores the chosen glyph separately —
switching mascots never forgets your emoji. Rendered via `LockScreenView.mascotGlyph`,
a `@ViewBuilder` that branches on `isEmojiMascot`: images use `.scaledToFit()`,
the emoji uses a `GeometryReader` + `.font(.system(size:))` sized to ~82% of the
frame (Text has no scale-to-fit).

## Things intentionally NOT done

- **Sparkle/auto-update was removed entirely**, not just disabled. The renamed
  fork's feed URL (`getbilakh.com`) is a domain nobody owns — leaving it wired up
  would poll an unclaimed third-party host on every launch. Package, delegate,
  Settings UI: all gone. `otool -L` on the built binary should show no Sparkle link.
- **No sandboxing.** `com.apple.security.app-sandbox = false` in the entitlements —
  inherited from lockpaw, needed for the unrestricted `CGEventTap` and
  `SCShareableContent`/`SCScreenshotManager` calls.
- **Crash safety needed no new code.** `CGEventTap` is kernel-owned per-process;
  the tap is torn down automatically the instant Bilakh's process dies. `LockState`
  is memory-only, never persisted — a relaunch after a crash starts `.unlocked`
  with no shield, by construction, not by any explicit guard.

## Gotchas

- **`xcodegen generate` must be re-run after any `project.yml` edit** — the
  `.xcodeproj` is generated, not committed (`.gitignore`'d). `xcodebuild` against
  a stale `.xcodeproj` silently ignores your change.
- **Ad-hoc → Team-ID resign can strand DerivedData.** If tests fail with a
  Team-ID dlopen mismatch after a signing change, `rm -rf
  ~/Library/Developer/Xcode/DerivedData/Bilakh-*` before assuming it's a real bug.
- Bundle ids: app `in.pooya.bilakh` (`.debug` suffix in Debug config), CLI tool
  product name `bilakh` (lowercase — deliberately, to avoid a case-collision with
  the app's `Bilakh` module on case-insensitive filesystems; see the comments in
  `project.yml`).
