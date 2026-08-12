import SwiftUI
import Carbon

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var step: Int
    @State private var isRecording = false
    @State private var recordedKeyDisplay = HotkeyConfig.display
    @State private var accessibilityGranted = AccessibilityChecker.isEnabled
    @State private var screenRecordingGranted = ScreenRecordingChecker.isEnabled
    @State private var cameraGranted = CameraChecker.isEnabled
    @State private var accessibilityTimer: Timer?
    @State private var hotkeyConflict: String?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(EmojiMascot.storageKey) private var mascotEmoji = EmojiMascot.defaultValue
    @State private var mascotBreath = false
    @State private var pulse: CGFloat = 0

    private let totalSteps = 4

    /// `startingAt` exists so previews (and any future debug entry point) can open
    /// the flow on a single step instead of clicking through it. The app never
    /// passes it — onboarding always begins at the welcome step.
    init(hasCompletedOnboarding: Binding<Bool>, startingAt step: Int = 0) {
        self._hasCompletedOnboarding = hasCompletedOnboarding
        self._step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: hotkeyStep
                case 2: permissionsStep
                // Step 3 (agentAlertsStep) is hidden for now — see MARK below.
                // Kept in the file, just skipped in the switch, so it's a one-line
                // revert to bring back.
                case 3: readyStep
                default: EmptyView()
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 20)),
                removal: .opacity.combined(with: .offset(x: -20))
            ))
            .padding(.horizontal, 40)

            Spacer()

            // Progress + action
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color("FlipOffAmber") : .gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                // The final step's "Get Started" reads as the flow's one
                // affirmative action, so it gets a tonal treatment — a soft
                // accent-tinted fill, not a fully saturated `.borderedProminent`
                // button (SwiftUI has no first-party tonal style on macOS, so
                // this is a plain button styled by hand). Every other step's
                // "Continue" stays outlined.
                Group {
                    if step == totalSteps - 1 {
                        Button {
                            advance()
                        } label: {
                            Text(buttonLabel)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color("FlipOffAmber"))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color("FlipOffAmber").opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                        .controlSize(.large)
                        .disabled(!canAdvance)
                    } else {
                        Button {
                            advance()
                        } label: {
                            Text(buttonLabel)
                                .font(.system(size: 14, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                        .tint(Color("FlipOffAmber"))
                        .disabled(!canAdvance)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 420, height: 500)
        .onAppear {
            accessibilityGranted = AccessibilityChecker.isEnabled
            screenRecordingGranted = ScreenRecordingChecker.isEnabled
            cameraGranted = CameraChecker.isEnabled
            if step == 2 && !allRequiredGranted {
                startPermissionPolling()
            }
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
        }
    }

    private var canAdvance: Bool {
        // Camera is intentionally excluded — it's optional and never blocks onboarding.
        if step == 2 && !allRequiredGranted { return false }
        return true
    }

    private var buttonLabel: String {
        switch step {
        case 2 where !allRequiredGranted: return "Waiting for access…"
        case totalSteps - 1: return "Get Started"
        default: return "Continue"
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.3)) {
            if step < totalSteps - 1 {
                step += 1
                if step == 2 { startPermissionPolling() }
            } else {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                NotificationCenter.default.post(name: .flipOffHotkeyPreferenceChanged, object: nil)
                hasCompletedOnboarding = true
                // Open Settings immediately — this activates the event pipeline
                // so the global hotkey works without needing to click the menu bar.
                openSettings()
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            mascotHero(size: 96)

            VStack(spacing: 8) {
                Text("Welcome to FlipOff")
                    .font(.title2.weight(.semibold))

                Text("Keeps snoops out\nwhile you step away.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
    }

    /// The mascot in a breathing pool of light — the app's hero, reused across steps.
    private func mascotHero(size: CGFloat) -> some View {
        ZStack {
            Ellipse()
                .fill(Color("FlipOffAmber").opacity(0.05))
                .frame(width: size * 0.9, height: size * 0.25)
                .blur(radius: 18)
                .offset(y: size * 0.5)

            mascotImage(size: size)
                .shadow(color: Color("FlipOffAmber").opacity(0.18), radius: 24, y: 8)
                .scaleEffect(mascotBreath ? 1.03 : 1.0)
                .offset(y: mascotBreath ? -3 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                mascotBreath = true
            }
        }
    }

    /// Renders the chosen emoji at `size`.
    private func mascotImage(size: CGFloat) -> some View {
        Text(EmojiMascot.resolved(from: mascotEmoji))
            .font(.system(size: size * 0.82))
            .frame(width: size, height: size)
    }

    // MARK: - Step 2: Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color("FlipOffAmber"))

            VStack(spacing: 8) {
                Text("Set your hotkey")
                    .font(.title2.weight(.semibold))

                Text("Press once to lock, press again to unlock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Recorder
            Button {
                isRecording = true
            } label: {
                Group {
                    if isRecording {
                        Text("Press your shortcut…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color("FlipOffAmber").opacity(0.7))
                    } else {
                        Text(recordedKeyDisplay)
                            .font(.system(size: 18, weight: .light, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Color("FlipOffAmber"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color("FlipOffAmber").opacity(isRecording ? 0.15 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color("FlipOffAmber").opacity(isRecording ? 0.4 : 0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if let conflict = hotkeyConflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(Color("FlipOffError"))
            } else if isRecording {
                Text("Press any modifier + key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { setupKeyRecorder() }
    }

    // MARK: - Step 3: Permissions

    /// Only Accessibility is required to advance — it's the one grant a lock can't
    /// work without. Screen Recording is optional because the default Live backdrop
    /// shows the real desktop and captures nothing; it's only needed if you switch
    /// to the frozen screenshot. Camera is optional too (snoop photo).
    private var allRequiredGranted: Bool { accessibilityGranted }

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            ZStack {
                if allRequiredGranted {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color("FlipOffAmber"))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color("FlipOffAmber"))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: allRequiredGranted)

            Text(allRequiredGranted ? "Access granted" : "Access needed")
                .font(.title2.weight(.semibold))
                .animation(.none, value: allRequiredGranted)

            VStack(spacing: 12) {
                permissionRow(
                    title: "Accessibility",
                    detail: "Blocks keyboard input while locked.",
                    granted: accessibilityGranted,
                    onRequest: {
                        AccessibilityChecker.promptIfNeeded()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            AccessibilityChecker.openSystemSettings()
                        }
                    }
                )

                permissionRow(
                    title: "Screen Recording",
                    detail: "Only for the Frozen backdrop.",
                    granted: screenRecordingGranted,
                    optional: true,
                    onRequest: {
                        ScreenRecordingChecker.requestAccess()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            ScreenRecordingChecker.openSystemSettings()
                        }
                    }
                )

                permissionRow(
                    title: "Camera",
                    detail: "Snaps a photo of snoops.",
                    granted: cameraGranted,
                    optional: true,
                    onRequest: {
                        CameraChecker.requestAccess { granted in
                            cameraGranted = granted
                        }
                    }
                )
            }
        }
    }

    /// One row in the permissions list: title, detail, and a trailing
    /// grant/status control. `optional` permissions never block `canAdvance`
    /// and get muted styling instead of the teal "required" treatment.
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        optional: Bool = false,
        onRequest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                        if optional {
                            Text("Optional")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.secondary.opacity(0.15)))
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color("FlipOffAmber"))
                } else {
                    Button("Grant", action: onRequest)
                        .controlSize(.regular)
                        .buttonStyle(.bordered)
                        .tint(optional ? .secondary : Color("FlipOffAmber"))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))
    }

    // MARK: - Step 4: Agent alerts

    private var agentAlertsStep: some View {
        VStack(spacing: 20) {
            // Mini lock-screen preview, pulsing teal — the "it needs you" moment.
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color("FlipOffAmber").opacity(0.55 * pulse), .clear],
                        center: .center, startRadius: 0, endRadius: 95))
                    .blendMode(.plusLighter)

                mascotImage(size: 46)
            }
            .frame(width: 156, height: 104)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    pulse = 1
                }
            }

            VStack(spacing: 8) {
                Text("FlipOff taps you")
                    .font(.title2.weight(.semibold))

                Text("Lock your screen and walk away. When Claude Code,\nCodex, or Gemini needs you, the screen glows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Text("Set it up anytime in Settings — works with any CLI agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 5: Ready

    private var readyStep: some View {
        VStack(spacing: 18) {
            // The whole lock/unlock loop, acted out on a miniature desktop —
            // click the menu-bar icon, pick Lock Screen, unlock by chord or by
            // sensor. It carries the unlock hints itself, so the static chip row
            // below only appears when motion is off.
            OnboardingLockDemo(
                emoji: EmojiMascot.resolved(from: mascotEmoji),
                hotkeyDisplay: recordedKeyDisplay
            )

            VStack(spacing: 8) {
                Text("FlipOff lives in your menu bar")
                    .font(.title3.weight(.semibold))

                Text("Click to lock or open Settings.\nUnlock with your hotkey or Touch ID.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            // Unlock reminder — both the hotkey and Touch ID work. The animation
            // demonstrates both when it's allowed to run; this is the reduced-motion
            // stand-in for that beat, so the information is never lost.
            if reduceMotion {
                HStack(spacing: 8) {
                    Text(recordedKeyDisplay)
                        .font(.system(size: 14, weight: .light, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Color("FlipOffAmber"))
                        .frame(height: 18)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color("FlipOffAmber").opacity(0.08))
                        )

                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "touchid")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color("FlipOffAmber"))
                        .frame(height: 18)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color("FlipOffAmber").opacity(0.08))
                        )
                }
            }
        }
    }

    // MARK: - Hotkey Recorder

    private func setupKeyRecorder() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }

            var parts: [String] = []
            if event.modifierFlags.contains(.command) { parts.append("Cmd") }
            if event.modifierFlags.contains(.shift) { parts.append("Shift") }
            if event.modifierFlags.contains(.option) { parts.append("Opt") }
            if event.modifierFlags.contains(.control) { parts.append("Ctrl") }

            guard !parts.isEmpty else { return event }

            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                parts.append(chars)
            }

            let display = parts.joined(separator: "+")

            // Check for conflicts with common system shortcuts
            if let conflict = HotkeyConfig.systemConflict(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) {
                hotkeyConflict = "\(display) conflicts with \(conflict). Try another."
                return nil
            }

            recordedKeyDisplay = display
            hotkeyConflict = nil
            isRecording = false

            // Persist the hotkey to UserDefaults
            var carbonMods: Int = 0
            if event.modifierFlags.contains(.command) { carbonMods |= cmdKey }
            if event.modifierFlags.contains(.shift) { carbonMods |= shiftKey }
            if event.modifierFlags.contains(.option) { carbonMods |= optionKey }
            if event.modifierFlags.contains(.control) { carbonMods |= controlKey }
            HotkeyConfig.saveKeyCode(Int(event.keyCode))
            HotkeyConfig.saveModifiers(carbonMods)
            HotkeyConfig.saveDisplay(recordedKeyDisplay)
            // Don't post flipOffHotkeyPreferenceChanged here — Accessibility isn't
            // granted yet during onboarding. The completion step posts it instead.

            return nil
        }
    }

    // MARK: - Accessibility Polling

    /// Polls all three permissions while the user is on the permissions step.
    /// Screen Recording and Camera grants are visible to a running process as
    /// soon as they're toggled; Accessibility's `AXIsProcessTrusted()` can lag
    /// or get stuck after a grant, but the poll alone still catches it once
    /// macOS's cached answer catches up — there's no relaunch escape hatch here.
    private func startPermissionPolling() {
        accessibilityTimer?.invalidate()
        accessibilityGranted = AccessibilityChecker.isEnabled
        screenRecordingGranted = ScreenRecordingChecker.isEnabled

        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            DispatchQueue.main.async {
                accessibilityGranted = AccessibilityChecker.isEnabled
                screenRecordingGranted = ScreenRecordingChecker.isEnabled
                if allRequiredGranted {
                    timer.invalidate()
                    accessibilityTimer = nil
                }
            }
        }
        accessibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
