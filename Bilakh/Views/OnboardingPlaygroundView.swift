import SwiftUI

/// Dev-only playground for stepping through every page of `OnboardingView` without
/// the real System Settings / TCC dance. The stage mirrors `OnboardingView`'s five
/// steps almost verbatim (copy, layout, animations) but drives `accessibilityGranted`
/// from `OnboardingPlaygroundParams` instead of `AccessibilityChecker.isEnabled` —
/// `AXIsProcessTrusted()` has no seam to mock, so the stage is a stand-in view, not
/// a wrapped `OnboardingView`. Built to investigate the "stuck on Accessibility even
/// after granting permission" report: `OnboardingView`'s own doc comment explains
/// why — macOS's accessibility daemon can cache a "not trusted" answer for a
/// process's entire lifetime once queried before the grant, so polling
/// `AXIsProcessTrusted()` again in the same process never sees the flip. This
/// playground lets you jump straight to that stuck state and fire the relaunch
/// hint on demand instead of waiting out the real 6-second timer or a live grant.

@MainActor
@Observable
final class OnboardingPlaygroundParams {
    static let shared = OnboardingPlaygroundParams()

    /// Which of the 5 onboarding pages the stage is showing.
    var step: Int = 0
    /// Mock stand-ins for `AccessibilityChecker`/`ScreenRecordingChecker`/
    /// `CameraChecker` .isEnabled — toggled by hand here, never read from the
    /// real TCC database. Camera is optional and never gates advancing.
    var accessibilityGranted: Bool = false
    var screenRecordingGranted: Bool = false
    var cameraGranted: Bool = false
    /// Mirrors `OnboardingView.showRelaunchHint` — normally revealed only after 6s
    /// stuck ungranted; forced on/off instantly here to preview the "stuck" state
    /// users are reporting without waiting.
    var showRelaunchHint: Bool = false
    /// Simulates the real bug: permission was granted in System Settings, but this
    /// (mock) process's cached answer won't update no matter how long you poll —
    /// only a relaunch clears it. When true, toggling `accessibilityGranted` back
    /// to true from the "grant" button has no effect, matching the stuck repro.
    var simulateStaleProcessCache: Bool = false
    var recordedKeyDisplay: String = "⌃⌥⌘L"
    var reduceMotion: Bool = false

    // Mirrors OnboardingView.totalSteps — agent alerts (step 3) is currently
    // hidden there, so this stays at 4, not 5, to match what ships.
    let totalSteps = 4

    init(loadSaved: Bool = true) {
        if loadSaved, let s = OnboardingPlaygroundSnapshot.load() { apply(s) }
    }

    func apply(_ s: OnboardingPlaygroundSnapshot) {
        step = s.step
        accessibilityGranted = s.accessibilityGranted
        screenRecordingGranted = s.screenRecordingGranted
        cameraGranted = s.cameraGranted
        showRelaunchHint = s.showRelaunchHint
        simulateStaleProcessCache = s.simulateStaleProcessCache
    }

    func reset() {
        apply(OnboardingPlaygroundSnapshot(OnboardingPlaygroundParams(loadSaved: false)))
        save()
    }

    func save() { OnboardingPlaygroundSnapshot(self).save() }

    /// Autosave watches this; any change persists the tuning session.
    var signature: [Double] {
        [Double(step), accessibilityGranted ? 1 : 0, screenRecordingGranted ? 1 : 0,
         cameraGranted ? 1 : 0, showRelaunchHint ? 1 : 0, simulateStaleProcessCache ? 1 : 0]
    }

    var swiftSnippet: String {
        """
        // OnboardingPlayground repro state
        step = \(step)
        accessibilityGranted = \(accessibilityGranted)
        screenRecordingGranted = \(screenRecordingGranted)
        cameraGranted = \(cameraGranted)
        showRelaunchHint = \(showRelaunchHint)
        simulateStaleProcessCache = \(simulateStaleProcessCache)
        """
    }

    /// "Grant" button on the stage — flips `accessibilityGranted` to true unless
    /// the stale-cache bug is being simulated, in which case it stays stuck (the
    /// point of the repro).
    func simulateGrant() {
        guard !simulateStaleProcessCache else { return }
        accessibilityGranted = true
        showRelaunchHint = false
    }

    /// "Relaunch Bilakh" on the stage — the only thing that clears a stale cache,
    /// same as the real `OnboardingView.relaunchApp()`.
    func simulateRelaunch() {
        accessibilityGranted = true
        simulateStaleProcessCache = false
        showRelaunchHint = false
    }
}

struct OnboardingPlaygroundSnapshot: Codable {
    var step: Int
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
    var cameraGranted: Bool
    var showRelaunchHint: Bool
    var simulateStaleProcessCache: Bool

    @MainActor
    init(_ p: OnboardingPlaygroundParams) {
        step = p.step
        accessibilityGranted = p.accessibilityGranted
        screenRecordingGranted = p.screenRecordingGranted
        cameraGranted = p.cameraGranted
        showRelaunchHint = p.showRelaunchHint
        simulateStaleProcessCache = p.simulateStaleProcessCache
    }

    private static let key = "inspo.onboardingPlayground"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    @MainActor
    static func load() -> OnboardingPlaygroundSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let obj = try? JSONDecoder().decode(PartialSnapshot.self, from: data) else { return nil }
        var snapshot = OnboardingPlaygroundSnapshot(OnboardingPlaygroundParams(loadSaved: false))
        snapshot.step = obj.step ?? 0
        snapshot.accessibilityGranted = obj.accessibilityGranted ?? false
        snapshot.screenRecordingGranted = obj.screenRecordingGranted ?? false
        snapshot.cameraGranted = obj.cameraGranted ?? false
        snapshot.showRelaunchHint = obj.showRelaunchHint ?? false
        snapshot.simulateStaleProcessCache = obj.simulateStaleProcessCache ?? false
        return snapshot
    }

    /// Decoded key-by-key with `decodeIfPresent` (via this all-optional mirror),
    /// never the synthesized decoder — that throws on the first missing key, so
    /// adding a new knob later would silently discard the whole saved snapshot.
    private struct PartialSnapshot: Codable {
        var step: Int?
        var accessibilityGranted: Bool?
        var screenRecordingGranted: Bool?
        var cameraGranted: Bool?
        var showRelaunchHint: Bool?
        var simulateStaleProcessCache: Bool?
    }
}

// MARK: - Stage

/// Mock of the real onboarding window at its actual size (420×500), rendering the
/// same 5 steps as `OnboardingView`. Kept as a parallel implementation rather than
/// wrapping `OnboardingView` because the real view reads `AccessibilityChecker
/// .isEnabled` (a direct `AXIsProcessTrusted()` call) with no injection seam.
struct OnboardingPlaygroundStage: View {
    @Bindable var params: OnboardingPlaygroundParams
    @State private var mascotBreath = false
    @State private var pulse: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Group {
                switch params.step {
                case 0: welcomeStep
                case 1: hotkeyStep
                case 2: permissionsStep
                // Step "3" in OnboardingView is readyStep — agentAlertsStep is
                // hidden there for now, kept here only so its preview still works
                // if you jump to it manually (not reachable via Continue/Back).
                case 3: readyStep
                default: EmptyView()
                }
            }
            .padding(.horizontal, 40)
            .animation(.easeInOut(duration: 0.3), value: params.step)

            Spacer()

            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(0..<params.totalSteps, id: \.self) { i in
                        Circle()
                            .fill(i == params.step ? Color.orange : .gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                // Mirrors OnboardingView: the last step's "Get Started" is
                // tonal/filled (borderedProminent); every other step's
                // "Continue" stays outlined.
                Group {
                    if params.step == params.totalSteps - 1 {
                        Text(buttonLabel)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.orange))
                    } else {
                        Text(buttonLabel)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 420, height: 500)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 20, y: 8)
    }

    private var buttonLabel: String {
        switch params.step {
        case 2 where !allRequiredGranted: return "Waiting for access…"
        case params.totalSteps - 1: return "Get Started"
        default: return "Continue"
        }
    }

    // MARK: Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            mascotHero(size: 96)
            VStack(spacing: 8) {
                Text("Welcome to Bilakh").font(.title2.weight(.semibold))
                Text("Keeps intruders out\nwhile you step away.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2)
            }
        }
    }

    private func mascotHero(size: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(Color.orange.opacity(0.05))
                .frame(width: size * 0.9, height: size * 0.25).blur(radius: 18).offset(y: size * 0.5)
            Text("🖕🏻").font(.system(size: size * 0.82)).frame(width: size, height: size)
                .shadow(color: .orange.opacity(0.18), radius: 24, y: 8)
                .scaleEffect(mascotBreath ? 1.03 : 1.0)
                .offset(y: mascotBreath ? -3 : 0)
        }
        .onAppear {
            guard !params.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { mascotBreath = true }
        }
    }

    // MARK: Step 1: Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard").font(.system(size: 36, weight: .light)).foregroundStyle(.orange)
            VStack(spacing: 8) {
                Text("Set your hotkey").font(.title2.weight(.semibold))
                Text("Press once to lock, press again to unlock.").font(.callout).foregroundStyle(.secondary)
            }
            Text(params.recordedKeyDisplay)
                .font(.system(size: 18, weight: .light, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.orange)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.15), lineWidth: 1))
        }
    }

    // MARK: Step 2: Accessibility — the step under investigation

    private var allRequiredGranted: Bool { params.accessibilityGranted && params.screenRecordingGranted }

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            ZStack {
                if allRequiredGranted {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.orange)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: allRequiredGranted)

            Text(allRequiredGranted ? "Access granted" : "Access needed")
                .font(.title2.weight(.semibold))

            VStack(spacing: 12) {
                mockPermissionRow(
                    title: "Accessibility",
                    detail: "Blocks keyboard input while locked.",
                    granted: params.accessibilityGranted,
                    showRelaunchHint: params.showRelaunchHint,
                    onRequest: { params.simulateGrant() },
                    onRelaunch: { params.simulateRelaunch() }
                )
                mockPermissionRow(
                    title: "Screen Recording",
                    detail: "Captures your desktop before the shield goes up.",
                    granted: params.screenRecordingGranted,
                    showRelaunchHint: false,
                    onRequest: { params.screenRecordingGranted = true },
                    onRelaunch: nil
                )
                mockPermissionRow(
                    title: "Camera",
                    detail: "Snaps a photo of intruders.",
                    granted: params.cameraGranted,
                    showRelaunchHint: false,
                    optional: true,
                    onRequest: { params.cameraGranted = true },
                    onRelaunch: nil
                )
            }
        }
    }

    private func mockPermissionRow(
        title: String, detail: String, granted: Bool, showRelaunchHint: Bool,
        optional: Bool = false, onRequest: @escaping () -> Void, onRelaunch: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if optional {
                            Text("Optional")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.secondary.opacity(0.15)))
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                } else {
                    Button("Grant", action: onRequest)
                        .controlSize(.regular).buttonStyle(.bordered).tint(optional ? .secondary : .orange)
                }
            }
            if showRelaunchHint, let onRelaunch {
                HStack(spacing: 10) {
                    Text("Still stuck? Try a relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Relaunch", action: onRelaunch)
                        .controlSize(.regular).buttonStyle(.bordered)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))
    }

    // MARK: Step 3: Agent alerts

    private var agentAlertsStep: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(RadialGradient(colors: [Color.orange.opacity(0.55 * pulse), .clear], center: .center, startRadius: 0, endRadius: 95))
                    .blendMode(.plusLighter)
                Text("🖕🏻").font(.system(size: 46 * 0.82))
            }
            .frame(width: 156, height: 104)
            .onAppear {
                guard !params.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = 1 }
            }
            VStack(spacing: 8) {
                Text("Bilakh taps you").font(.title2.weight(.semibold))
                Text("Lock your screen and walk away. When Claude Code,\nCodex, or Gemini needs you, the screen glows.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2)
            }
            Text("Set it up anytime in Settings — works with any CLI agent.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: "battery.75percent").font(.system(size: 13)).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.orange.opacity(0.15)).frame(width: 24, height: 20)
                        Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit().frame(height: 12).foregroundStyle(.orange)
                    }
                    Text("11:21").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer().frame(width: 8)
                }
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.06)))
            }
            .frame(width: 220)
            VStack(spacing: 8) {
                Text("Bilakh lives in your menu bar").font(.title3.weight(.semibold))
                Text("Click to lock or open Settings.\nUnlock with your hotkey or Touch ID.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2)
            }
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(params.recordedKeyDisplay)
                        .font(.system(size: 14, weight: .light, design: .monospaced)).tracking(1).foregroundStyle(.orange)
                        .frame(height: 18)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.orange.opacity(0.08)))

                    Text("or").font(.caption).foregroundStyle(.secondary)

                    Image(systemName: "touchid")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(.orange)
                        .frame(height: 18)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.orange.opacity(0.08)))
                }
            }
        }
    }
}

// MARK: - Controls + host view

struct OnboardingPlaygroundView: View {
    @State private var params = OnboardingPlaygroundParams.shared
    @State private var expanded: Set<String> = ["Steps", "Accessibility repro"]

    var body: some View {
        HSplitView {
            ZStack {
                Color.black.opacity(0.15)
                OnboardingPlaygroundStage(params: params)
            }
            .frame(minWidth: 480, minHeight: 600)

            Form {
                accordion("Steps") {
                    Picker("Page", selection: $params.step) {
                        Text("0 · Welcome").tag(0)
                        Text("1 · Hotkey").tag(1)
                        Text("2 · Permissions").tag(2)
                        Text("3 · Ready").tag(3)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                accordion("Permissions repro") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Accessibility granted", isOn: $params.accessibilityGranted)
                        Toggle("Screen Recording granted", isOn: $params.screenRecordingGranted)
                        Toggle("Camera granted (optional)", isOn: $params.cameraGranted)
                        Toggle("Show relaunch hint now", isOn: $params.showRelaunchHint)

                        Divider()

                        Toggle("Simulate stale process cache (the bug)", isOn: $params.simulateStaleProcessCache)
                        Text("When on, tapping \"Grant\" for Accessibility on the stage grants nothing — mirrors AXIsProcessTrusted() staying stuck for a process's whole lifetime once it's been read as false. Only \"Relaunch Bilakh\" recovers it, same as the real onboarding flow. Screen Recording and Camera aren't affected by this bug.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Jump to stuck-with-permission-granted repro") {
                            params.step = 2
                            params.simulateStaleProcessCache = true
                            params.accessibilityGranted = false
                            params.screenRecordingGranted = true
                            params.showRelaunchHint = true
                        }
                    }
                }

                accordion("Misc") {
                    Toggle("Reduce motion", isOn: $params.reduceMotion)
                    TextField("Hotkey display", text: $params.recordedKeyDisplay)
                }

                Section {
                    HStack {
                        Button("Reset") { params.reset() }
                        Spacer()
                        Button("Copy as Swift") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(params.swiftSnippet, forType: .string)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 320)
        }
        .frame(minWidth: 820, minHeight: 660)
        .onChange(of: params.signature) { params.save() }
    }

    private func accordion(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        let body = content()
        return Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(title) },
                    set: { isOn in
                        if isOn { expanded.insert(title) } else { expanded.remove(title) }
                    })
            ) {
                body.padding(.top, 4)
            } label: {
                Text(title).font(.headline)
            }
        }
    }
}
