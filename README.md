# FlipOff

Lock your Mac and walk away — the desktop stays live, right in front of whoever's
looking. FlipOff baits snoops into thinking your Mac isn't locked. The moment
someone touches the keyboard or trackpad to find out, they get 🖕🏻 full-screen,
your message, your sound — and their mugshot saved to your Downloads folder.

It's a decoy, not a vault: the goal is to fool a nosy coworker or sibling for the
ten seconds it takes them to reach for your trackpad, not to stop a real
attacker. Nothing dismisses it except your own hotkey or Touch ID/password.

Fork of [lockpaw](https://github.com/sorkila/lockpaw) (MIT).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme FlipOff -configuration Debug build
```

Grant **Accessibility** when prompted — that's what lets the shield swallow
keyboard and trackpad input. Camera access is optional (powers the mugshot) and
Screen Recording is only needed if you switch the backdrop to Frozen mode.
Menu-bar only, no dock icon.
