# Bilakh

Lock your Mac and walk away — the desktop stays exactly as you left it. Bilakh
freezes a screenshot of every display in place, so at a glance nothing looks
locked at all. It is. The moment someone touches the keyboard or trackpad to
snoop, they get 🖕🏻 full-screen and a fart noise instead of your open tabs.

It's a decoy, not a vault: the goal is to fool a nosy coworker or sibling for the
ten seconds it takes them to reach for your trackpad, not to stop a real
attacker. Nothing dismisses it except your own hotkey or Touch ID/password.

Fork of [lockpaw](https://github.com/sorkila/lockpaw) (MIT).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Bilakh -configuration Debug build
```

Grant **Accessibility** and **Screen Recording** when prompted. Menu-bar only, no
dock icon.
