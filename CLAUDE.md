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
your own Macs; the released `.zip` shows a Gatekeeper warning on first open
(right-click → Open).

**Released builds must be ad-hoc signed as a bundle, and `CODE_SIGNING_ALLOWED=NO`
does not do that.** That flag leaves only a *linker* ad-hoc signature on the
executable: `codesign -dv` reports `Sealed Resources=none` and `Info.plist=not
bound`, which means the bundle itself is unsigned. TCC cannot attach a grant to a
bundle in that state, so **Accessibility silently never persists** — the user grants
it, relaunches, and the app still reads untrusted. This shipped in v1.2.0. `release
.yml` now runs an explicit `codesign --sign -` pass (nested Sparkle helpers first,
deepest-first, then the app with entitlements) and fails the release if either
marker comes back wrong. Caveat that remains: an ad-hoc cdhash changes every build,
so the Accessibility grant resets on each update — macOS shows it enabled but stale,
and the user has to toggle it off/on. Only a Developer ID cert fixes that for good.

## Auto-update (Sparkle)

Sparkle 2.9.5, re-added after the fork had stripped it. The original removal reason
still stands and is what shapes the setup: the upstream feed pointed at
`getbilakh.com`, a domain nobody owns. The feed now lives in this repo
(`appcast.xml` on `main`, served via `raw.githubusercontent.com`), so there is no
registerable third-party host in the update path.

- **EdDSA is the actual trust anchor, not Apple signing.** Releases ship unsigned
  and un-notarized, so a `.zip` off the network carries no Apple guarantee. What
  makes that safe is `SUPublicEDKey` in Info.plist: Sparkle refuses any archive
  whose `sparkle:edSignature` doesn't verify against it. Private half lives in the
  login keychain and in the `SPARKLE_PRIVATE_KEY` repo secret — **if that key is
  ever lost, no existing install can be updated again**, since they all validate
  against the baked-in public key.
- **`UpdateController` refuses to check while locked** (`LockController
  .isAnyLockActive`, a static mirror of `state` maintained in `transitionTo`).
  Sparkle's sheets would otherwise land on top of the shield and offer a relaunch —
  an escape out of a lock that's supposed to require the hotkey or Touch ID.
- **`LSUIElement` needs an activation-policy flip.** The app has no Dock tile and
  never activates on its own, so Sparkle's windows would open unfocused behind
  everything. The `SPUStandardUserDriverDelegate` hooks swap to `.regular` while a
  Sparkle window is up and back to `.accessory` afterwards.
- **`ditto`, never `zip -r`.** `zip -r` mangles the symlinks inside
  `Sparkle.framework`; `ditto -c -k --keepParent` preserves the bundle.
- Appcast generation is `scripts/update-appcast.py`, called from `release.yml` —
  a file, not inline YAML, because heredoc'd XML inside an indented `run:` block
  silently breaks the block scalar. It's idempotent (re-tagging replaces that
  build's `<item>`) and validates the XML before the workflow commits it.

## CI

`ci.yml` builds unsigned (`CODE_SIGNING_ALLOWED=NO`) — GitHub runners have no Apple
Development identity, so the Team-ID automatic signing in `project.yml` can't
resolve there. It deliberately does **not** run `BilakhTests`: the test bundle is
injected into the host app and needs a real signature (see the Team-ID `dlopen`
trap above), so tests are a local-only affair.

`release.yml` fires on `v*` tags: builds Release without an Apple identity → verifies
the icon compiled → ad-hoc signs the bundle → `ditto` zip → signs with the EdDSA key
→ uploads to the GitHub Release → regenerates `appcast.xml` and commits it to `main`.
It checks out `main` rather than the detached tag so that final commit has a branch
to land on.

**Both workflows must run on `macos-26`, not `macos-15`.**
`Bilakh/Resources/AppIcon.icon` is an Icon Composer bundle — a macOS 26 / Xcode 26
format. Xcode 16 doesn't recognize it and **the build still succeeds**: instead of
compiling it to `AppIcon.icns` it copies the folder into `Resources` verbatim and
sets no `CFBundleIconName`, so the app ships with no icon anywhere. v1.2.0 went out
that way. The log tell is `Copying AppIcon.icon` where a correct build reads
`Emplaced …/AppIcon.icns`. `release.yml` now has a "Verify app icon" step that fails
the release on a missing `.icns`, a missing plist key, or a leaked raw `.icon`.

## Mascot / emoji

`Models/Mascot.swift` has three cases: `.dog`, `.cat` (original lockpaw art), and
`.emoji` (default). `EmojiMascot` (same file) stores the chosen glyph separately —
switching mascots never forgets your emoji. Rendered via `LockScreenView.mascotGlyph`,
a `@ViewBuilder` that branches on `isEmojiMascot`: images use `.scaledToFit()`,
the emoji uses a `GeometryReader` + `.font(.system(size:))` sized to ~82% of the
frame (Text has no scale-to-fit).

## Things intentionally NOT done

- **No sandboxing.** `com.apple.security.app-sandbox = false` in the entitlements —
  inherited from lockpaw, needed for the unrestricted `CGEventTap` and
  `SCShareableContent`/`SCScreenshotManager` calls.
- **Crash safety needed no new code.** `CGEventTap` is kernel-owned per-process;
  the tap is torn down automatically the instant Bilakh's process dies. `LockState`
  is memory-only, never persisted — a relaunch after a crash starts `.unlocked`
  with no shield, by construction, not by any explicit guard.

## Gotchas

- **Never call `LAContext.evaluatePolicy` on lock.** It *always* presents a system
  sheet — LocalAuthentication has no API for silently waiting on the Touch ID
  sensor. A "passive Touch ID listener" armed at lock time (removed in 1.2.4)
  therefore put a modal on top of the shield the instant you locked: it announced
  the lock, contradicting the silent-shield design, and gave an intruder a dialog to
  interact with. Touch ID belongs only on explicit request — `requestUnlock()` from
  the hotkey, or the menu bar's "Unlock with Touch ID".
- **App-wide notifications must be observed by `LockController`, never by a view.**
  `.bilakhLock` / `.bilakhUnlock` / `.bilakhUnlockPassword` were once handled by
  `.onReceive` in `MenuBarView` — but a `MenuBarExtra`'s content view only exists
  while the popover is open, so with the menu closed Settings' "Lock Now" button and
  the entire `bilakh://` URL scheme posted into the void with no error anywhere.
  `LockController` lives for the app's lifetime; that's where these belong.
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
