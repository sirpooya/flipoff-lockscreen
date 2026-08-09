# Bilakh

Fake screensaver. Locks in-app (not the macOS lock screen) by shielding every
display with a frozen screenshot of your desktop and a giant 🖕🏻. Unlocks only via
your chosen hotkey or Touch ID/password — nothing else dismisses it.

Fork of [lockpaw](https://github.com/sorkila/lockpaw) (MIT).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Bilakh -configuration Debug build
```

Grant **Accessibility** and **Screen Recording** when prompted. Menu-bar only, no
dock icon.
