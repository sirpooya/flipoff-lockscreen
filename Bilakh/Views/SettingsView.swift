import SwiftUI
import AppKit
import ServiceManagement
import Carbon

private let buyMeACoffeeURL = URL(string: "https://buymeacoffee.com/sirpooya")!
private let repoURL = URL(string: "https://github.com/sirpooya/bilakh-lock")!
private let settingsAccentColor = Color("BilakhTeal")

private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case lockScreen
    case shortcuts
    case general
    case permissions
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .lockScreen: return "Lock Screen"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .lockScreen: return "lock.display"
        case .shortcuts: return "command"
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .lockScreen: return "Mascot, displays, and lock message"
        case .shortcuts: return "Hotkey and unlock options"
        case .general: return "Startup, appearance, and updates"
        case .permissions: return "System access"
        case .about: return "Version, credits, and security note"
        }
    }
}

struct SettingsView: View {
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = HotkeyConfig.defaultEnabled
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("appearanceMode") private var appearanceMode = 0 // 0=System, 1=Light, 2=Dark
    @AppStorage(LockSound.storageKey) private var selectedLockSound = LockSound.defaultValue
    @AppStorage(EmojiMascot.storageKey) private var mascotEmoji = EmojiMascot.defaultValue
    @State private var customEmojiInput = ""
    @FocusState private var customEmojiFieldFocused: Bool
    @AppStorage("hotkeyDisplay") private var hotkeyDisplay = HotkeyConfig.defaultDisplay
    @AppStorage(HotkeyConfig.requireAuthenticationToUnlockKey) private var requiresAuthenticationToUnlock = HotkeyConfig.defaultRequireAuthenticationToUnlock
    @AppStorage(Constants.agentPingSoundKey) private var agentPingSound = false
    @AppStorage(Constants.cameraOnFailedUnlockKey) private var cameraOnFailedUnlock = Constants.defaultCameraOnFailedUnlock


    @State private var selectedSection: SettingsSection = .lockScreen
    @State private var isRecording = false
    @State private var hotkeyConflict: String?
    @State private var keyMonitor: Any?
    @State private var accessibilityGranted = AccessibilityChecker.isEnabled
    @State private var screenRecordingGranted = ScreenRecordingChecker.isEnabled
    @State private var cameraGranted = CameraChecker.isEnabled
    @State private var accessibilityTimer: Timer?
    @State private var copiedItem: String?
    @State private var agentSetupResults: [String: AgentSetupResult] = [:]

    init() {
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selectedSection)

            // Cross-fade between sections (motion echo of the shared ease-out language).
            ZStack {
                selectedSettingsPage
                    .id(selectedSection)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: selectedSection)
        }
        .tint(settingsAccentColor)
        .accentColor(settingsAccentColor)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 720, idealHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                configureSettingsWindow()
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            applyAppearance(appearanceMode)
            startAccessibilityPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var selectedSettingsPage: some View {
        switch selectedSection {
        case .lockScreen:
            settingsPage(.lockScreen) { lockScreenSettings }
        case .shortcuts:
            settingsPage(.shortcuts) { shortcutSettings }
        case .general:
            settingsPage(.general) { generalSettings }
        case .permissions:
            settingsPage(.permissions) { permissionSettings }
        case .about:
            settingsPage(.about) { aboutSettings }
        }
    }

    private func settingsPage<Content: View>(_ section: SettingsSection, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(for: section)
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: 820, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func detailHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.title)
                .font(.system(size: 22, weight: .semibold))
            Text(section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var lockScreenSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            mascotPreview

            SettingsPanel {
                emojiPickerRow

                SettingsDivider()

                SettingsRow("Message", subtitle: "Shown beneath the mascot. Uncheck to hide it.") {
                    HStack(spacing: 10) {
                        SettingsCheckbox(isOn: $showMessage)

                        TextField("Lock message", text: $message, axis: .vertical)
                            .lineLimit(1...3)
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 360)
                            .disabled(!showMessage)
                            .opacity(showMessage ? 1 : 0.4)
                            .onChange(of: message) { _, newValue in
                                if newValue.count > 120 {
                                    message = String(newValue.prefix(120))
                                }
                            }
                    }
                }

                SettingsDivider()

                SettingsRow("Lock sound", subtitle: "Plays the moment the screen locks. Choose None to turn it off.") {
                    HStack(spacing: 10) {
                        SettingsDropdown(
                            selection: $selectedLockSound,
                            options: LockSound.allCases.map { ($0.displayName, $0.rawValue) },
                            width: 120
                        )

                        Button {
                            SoundPlayer.play(LockSound.resolved(from: selectedLockSound))
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(LockSound.resolved(from: selectedLockSound) == .none)
                    }
                }

                SettingsDivider()

                SettingsRow(
                    "Camera on failed unlock",
                    subtitle: cameraGranted
                        ? "Snap a photo of the attempt and save it to Downloads."
                        : "Snap a photo of the attempt and save it to Downloads. Grant Camera access in Permissions first."
                ) {
                    Toggle("", isOn: $cameraOnFailedUnlock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(settingsAccentColor)
                        .disabled(!cameraGranted)
                }
            }

            SettingsPanel {
                SettingsRow("Lock now", subtitle: "Start the lock screen immediately.") {
                    Button {
                        NotificationCenter.default.post(name: .bilakhLock, object: nil)
                    } label: {
                        Text("Lock Now")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    private var emojiPickerRow: some View {
        SettingsRow("Emoji", subtitle: "Shown full-screen while locked.") {
            HStack(spacing: 10) {
                ForEach(EmojiMascot.suggestions, id: \.self) { emoji in
                    Button {
                        mascotEmoji = emoji
                        customEmojiInput = ""
                    } label: {
                        Text(emoji)
                            .font(.system(size: 20))
                            .frame(width: 32, height: 32)
                            .background(
                                Circle().fill(.white.opacity(mascotEmoji == emoji ? 0.14 : 0.04))
                            )
                            .overlay(
                                Circle().strokeBorder(
                                    Color("BilakhTeal").opacity(mascotEmoji == emoji ? 0.6 : 0),
                                    lineWidth: 1.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Zero-size text capture — the system Character Viewer inserts
                // into whatever field has focus, so we give it an invisible one
                // instead of showing a raw text box next to the emoji swatches.
                TextField("", text: $customEmojiInput)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .focused($customEmojiFieldFocused)
                    .onChange(of: customEmojiInput) { _, newValue in
                        // Keep only the last typed character/grapheme so pasted text
                        // or a keyboard combo can't leave multiple glyphs stacked
                        // behind each other — the lock screen renders one symbol.
                        guard let last = newValue.last else { return }
                        let single = String(last)
                        customEmojiInput = single
                        mascotEmoji = single
                    }

                Button {
                    // Focus the hidden field first, then give SwiftUI a beat to
                    // actually hand it first-responder status before summoning
                    // the panel — this is the real macOS emoji & symbols picker.
                    customEmojiInput = ""
                    customEmojiFieldFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(.white.opacity(EmojiMascot.suggestions.contains(mascotEmoji) ? 0.04 : 0.14))
                        )
                        .overlay(
                            Circle().strokeBorder(
                                Color("BilakhTeal").opacity(EmojiMascot.suggestions.contains(mascotEmoji) ? 0 : 0.6),
                                lineWidth: 1.5
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("Pick any emoji from the full macOS picker")
            }
        }
    }

    private var mascotPreview: some View {
        // Just the lock-screen mockup, centered on a plain gray card — no label,
        // no caption. The mockup speaks for itself: emoji + message exactly as
        // they'll appear on the real shield.
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.035, blue: 0.045),
                    Color(red: 0.01, green: 0.012, blue: 0.018)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color("BilakhTeal").opacity(0.18), .clear],
                center: .bottomLeading,
                startRadius: 4,
                endRadius: 200
            )

            VStack(spacing: 10) {
                Text(EmojiMascot.resolved(from: mascotEmoji))
                    .font(.system(size: 52))

                if showMessage {
                    Text(message)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 24)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(width: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shortcutSettings: some View {
        SettingsPanel {
            SettingsRow("Lock / Unlock", subtitle: "Use one shortcut to lock or unlock.") {
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Text(isRecording ? "Press shortcut…" : hotkeyDisplay)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(isRecording ? Color("BilakhTeal") : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isRecording ? Color("BilakhTeal").opacity(0.12) : Color(.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isRecording ? Color("BilakhTeal").opacity(0.45) : Color(.separatorColor), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }

            if let conflict = hotkeyConflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(Color("BilakhError"))
            }

            SettingsDivider()

            SettingsRow("Require authentication", subtitle: "Touch ID or your Mac password is needed to unlock. Touch the sensor any time while locked.") {
                SettingsCheckbox(isOn: $requiresAuthenticationToUnlock)
            }

            SettingsDivider()

            SettingsRow("Global hotkey", subtitle: "Keep the shortcut active while Bilakh is running.") {
                SettingsCheckbox(isOn: $hotkeyEnabled)
                    .onChange(of: hotkeyEnabled) { _, enabled in
                        NotificationCenter.default.post(
                            name: .bilakhHotkeyPreferenceChanged,
                            object: nil,
                            userInfo: ["enabled": enabled]
                        )
                    }
            }
        }
    }

    // MARK: - Agent setup (one-click; runs the bundled CLI, which backs up configs)

    private enum AgentSetupResult {
        case running
        case success
        case failure(String)
    }

    private var cliURL: URL? {
        Bundle.main.sharedSupportURL?.appendingPathComponent("bilakh")
    }

    /// Run the bundled `bilakh` CLI with the given arguments off the main thread,
    /// then record the outcome for the row identified by `mark`. A ⚠️ on stdout with
    /// exit 0 (e.g. Codex already has a foreign `notify`) is surfaced as a failure
    /// so the button doesn't claim success for a write that didn't happen.
    private func runAgentSetup(_ arguments: [String], mark: String, treatWarningAsFailure: Bool = true) {
        if case .running = agentSetupResults[mark] { return }
        guard let cli = cliURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            agentSetupResults[mark] = .failure("The bundled bilakh tool is missing — reinstall Bilakh.")
            return
        }
        agentSetupResults[mark] = .running
        let startedAt = Date()
        Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let result: AgentSetupResult
            do {
                try process.run()
                process.waitUntilExit()
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus != 0 {
                    result = .failure(err.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if treatWarningAsFailure, out.contains("⚠️") {
                    result = .failure(out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    result = .success
                }
            } catch {
                result = .failure(error.localizedDescription)
            }
            // The CLI finishes in milliseconds; hold the spinner briefly so the
            // success state registers as an event rather than an instant flicker.
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < Constants.Timing.agentSetupMinSpin {
                try? await Task.sleep(nanoseconds: UInt64((Constants.Timing.agentSetupMinSpin - elapsed) * 1_000_000_000))
            }
            await MainActor.run {
                agentSetupResults[mark] = result
                // install-hook installs the CLI as a side effect — mirror that.
                if mark != "cli", case .success = result {
                    agentSetupResults["cli"] = .success
                }
            }
        }
    }

    private func isSetupRunning(_ mark: String) -> Bool {
        if case .running = agentSetupResults[mark] { return true }
        return false
    }

    @ViewBuilder
    private func setupButtonLabel(mark: String, idle: String, done: String) -> some View {
        switch agentSetupResults[mark] {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(idle)
            }
            .padding(.horizontal, 4)
        case .success:
            Text(done).padding(.horizontal, 4)
        case .failure:
            Text("\(idle) ⚠︎").padding(.horizontal, 4)
        case nil:
            Text(idle).padding(.horizontal, 4)
        }
    }

    private var agentSetupFailureMessage: String? {
        for tool in ["claude", "codex", "cli"] {
            if case .failure(let message) = agentSetupResults[tool], !message.isEmpty {
                return message
            }
        }
        return nil
    }

    private func agentLabel(_ tool: String) -> String {
        switch tool {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        default: return tool
        }
    }

    private func copyToPasteboard(_ string: String, mark: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copiedItem = mark
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copiedItem == mark { copiedItem = nil }
        }
    }

    private func copyHook(for tool: String) {
        copyToPasteboard(hookSnippet(for: tool), mark: tool)
    }

    /// Source the snippet from the bundled CLI (`install-hook <tool> --print`) so it
    /// never drifts from the tool; fall back to a literal if the CLI can't be run.
    private func hookSnippet(for tool: String) -> String {
        if let cli = cliURL, FileManager.default.isExecutableFile(atPath: cli.path) {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["install-hook", tool, "--print"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            if (try? process.run()) != nil {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
            }
        }
        switch tool {
        case "codex": return "notify = [\"bilakh\", \"ping\"]"
        case "gemini": return "Add a hook running `bilakh ping` in ~/.gemini/settings.json — see https://geminicli.com/docs/hooks/"
        default: return "\"hooks\": {\n  \"Notification\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"bilakh ping\" }] }],\n  \"Stop\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"bilakh ping\" }] }]\n}"
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPanel {
                SettingsRow("Launch at login", subtitle: "Open Bilakh automatically when you sign in.") {
                    SettingsCheckbox(isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = !enabled
                            }
                        }
                }

                SettingsDivider()

                SettingsRow("Appearance") {
                    SettingsSegmentedControl(
                        selection: $appearanceMode,
                        options: [("System", 0), ("Light", 1), ("Dark", 2)],
                        width: 240
                    )
                    .onChange(of: appearanceMode) { _, mode in
                        applyAppearance(mode)
                    }
                }
            }

            SettingsPanel {
                SettingsRow("Play a sound on agent ping", subtitle: "Off by default for shared spaces. The locked screen always glows.") {
                    SettingsCheckbox(isOn: $agentPingSound)
                }

                SettingsDivider()

                SettingsRow("Test agent ping", subtitle: "Send a sample notification to confirm alerts work.") {
                    Button {
                        AgentNotifier.shared.notify(withSound: agentPingSound)
                    } label: {
                        Text("Send")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                }

                SettingsDivider()

                SettingsRow("Connect your agent", subtitle: "One click sets up everything — the command-line tool and the agent's ping hook (a .bak backup is kept). Gemini copies a snippet to paste.") {
                    HStack(spacing: 8) {
                        ForEach(["claude", "codex", "gemini"], id: \.self) { tool in
                            Button {
                                if tool == "gemini" {
                                    copyHook(for: tool)
                                } else {
                                    runAgentSetup(["install-hook", tool], mark: tool)
                                }
                            } label: {
                                if tool == "gemini" {
                                    Text(copiedItem == tool ? "Copied ✓" : agentLabel(tool))
                                        .padding(.horizontal, 4)
                                } else {
                                    setupButtonLabel(mark: tool, idle: agentLabel(tool), done: "\(agentLabel(tool)) ✓")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSetupRunning(tool))
                        }
                    }
                }

                SettingsDivider()

                SettingsRow("Command-line tool", subtitle: "Optional — connecting an agent installs this automatically. Puts bilakh in ~/.local/bin for your own scripts.") {
                    Button {
                        runAgentSetup(["install-cli"], mark: "cli", treatWarningAsFailure: false)
                    } label: {
                        setupButtonLabel(mark: "cli", idle: "Install", done: "Installed ✓")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSetupRunning("cli"))
                }

                if let failure = agentSetupFailureMessage {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
            }

        }
    }

    private var permissionSettings: some View {
        SettingsPanel {
            SettingsRow(
                "Accessibility",
                subtitle: accessibilityGranted ? "Granted" : "Required to block keyboard input while locked."
            ) {
                HStack(spacing: 10) {
                    Label(
                        accessibilityGranted ? "Granted" : "Required",
                        systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(accessibilityGranted ? Color("BilakhTeal") : Color("BilakhAmber"))

                    if !accessibilityGranted {
                        Button {
                            AccessibilityChecker.openSystemSettings()
                        } label: {
                            Text("Grant Access")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsDivider()

            // Optional, unlike Accessibility: without it the lock screen falls
            // back to the desktop wallpaper rather than the live desktop.
            SettingsRow(
                "Screen Recording",
                subtitle: screenRecordingGranted
                    ? "Granted"
                    : "Optional — used to freeze your desktop behind the lock screen. Without it, your wallpaper is shown instead."
            ) {
                HStack(spacing: 10) {
                    Label(
                        screenRecordingGranted ? "Granted" : "Optional",
                        systemImage: screenRecordingGranted ? "checkmark.circle.fill" : "photo"
                    )
                    .foregroundStyle(screenRecordingGranted ? Color("BilakhTeal") : .secondary)

                    if !screenRecordingGranted {
                        Button {
                            // Ask first — the system prompt only appears while the
                            // grant is still undecided; once denied, only Settings works.
                            ScreenRecordingChecker.requestAccess()
                            ScreenRecordingChecker.openSystemSettings()
                        } label: {
                            Text("Grant Access")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsDivider()

            // Optional: without it, a failed unlock attempt just skips the
            // camera snapshot — everything else about the lock screen still works.
            SettingsRow(
                "Camera",
                subtitle: cameraGranted
                    ? "Granted"
                    : "Optional — snaps a photo on a failed unlock attempt, saved to Downloads."
            ) {
                HStack(spacing: 10) {
                    Label(
                        cameraGranted ? "Granted" : "Optional",
                        systemImage: cameraGranted ? "checkmark.circle.fill" : "camera"
                    )
                    .foregroundStyle(cameraGranted ? Color("BilakhTeal") : .secondary)

                    if !cameraGranted {
                        Button {
                            // Only registers Bilakh in the Camera privacy pane once
                            // this request actually resolves — opening System
                            // Settings before that finishes is why the app never
                            // showed up there. If it's already been decided (a past
                            // denial), the request resolves instantly with no
                            // prompt, and only then do we fall back to Settings.
                            CameraChecker.requestAccess { granted in
                                refreshAccessibilityStatus()
                                if !granted { CameraChecker.openSystemSettings() }
                            }
                        } label: {
                            Text("Grant Access")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPanel {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bilakh")
                            .font(.system(size: 17, weight: .semibold))
                        Text(appVersionText)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            SettingsPanel {
                SettingsRow(
                    "Made by Pooya",
                    subtitle: "Forked from lockpaw by Erik Nielsen.",
                    subtitleSize: 11
                ) {
                    Link("Github", destination: repoURL)
                        .buttonStyle(.link)
                }

                SettingsDivider()

                Text("Bilakh is a visual privacy tool. It helps prevent accidental input while your screen is guarded. For security, use your Mac's lock screen (Ctrl+Cmd+Q).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                SettingsRow("Support Bilakh") {
                    Button {
                        NSWorkspace.shared.open(buyMeACoffeeURL)
                    } label: {
                        Text("Buy Me a Coffee")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)): return "Version \(version) (\(build))"
        case let (.some(version), .none): return "Version \(version)"
        case let (.none, .some(build)): return "Build \(build)"
        default: return "Version unknown"
        }
    }

    private func refreshAccessibilityStatus() {
        accessibilityGranted = AccessibilityChecker.isEnabled
        screenRecordingGranted = ScreenRecordingChecker.isEnabled
        cameraGranted = CameraChecker.isEnabled
    }

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        refreshAccessibilityStatus()

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshAccessibilityStatus()
            }
        }
        accessibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func configureSettingsWindow() {
        guard let window = NSApp.keyWindow else { return }
        window.title = "Bilakh Settings"
        window.minSize = NSSize(width: 760, height: 720)

        let targetSize = NSSize(width: 820, height: 740)
        let contentSize = window.contentView?.frame.size ?? .zero
        if contentSize.width < targetSize.width || contentSize.height < targetSize.height {
            window.setContentSize(targetSize)
            window.center()
        }
    }

    private func applyAppearance(_ mode: Int) {
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // Follow system
        }
    }

    // MARK: - Hotkey Recorder

    private func startRecording() {
        hotkeyConflict = nil
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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

            if let conflict = HotkeyConfig.systemConflict(keyCode: Int(event.keyCode), modifiers: event.modifierFlags) {
                hotkeyConflict = "\(display) conflicts with \(conflict)"
                return nil
            }

            // Save and apply
            var carbonMods: Int = 0
            if event.modifierFlags.contains(.command) { carbonMods |= cmdKey }
            if event.modifierFlags.contains(.shift) { carbonMods |= shiftKey }
            if event.modifierFlags.contains(.option) { carbonMods |= optionKey }
            if event.modifierFlags.contains(.control) { carbonMods |= controlKey }

            HotkeyConfig.saveKeyCode(Int(event.keyCode))
            HotkeyConfig.saveModifiers(carbonMods)
            HotkeyConfig.saveDisplay(display)
            hotkeyDisplay = display
            hotkeyConflict = nil
            stopRecording()

            NotificationCenter.default.post(name: .bilakhHotkeyPreferenceChanged, object: nil)

            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .font(.system(size: 14))
        .controlSize(.regular)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        // The window titlebar already says "Bilakh Settings" — no in-content title.
        HStack(alignment: .center, spacing: 12) {
            ForEach(SettingsSection.allCases) { section in
                SettingsTabButton(
                    section: section,
                    isSelected: selection == section
                ) {
                    selection = section
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsTabButton: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)

                Text(section.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? settingsAccentColor : .secondary)
            .padding(.horizontal, 8)
            .frame(width: 90, height: 56)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(settingsAccentColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(settingsAccentColor.opacity(0.22), lineWidth: 1)
                        )
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
    }
}

private struct SettingsRow<Control: View>: View {
    private let title: String
    private let subtitle: String?
    private let subtitleSize: CGFloat
    private let control: Control

    init(_ title: String, subtitle: String? = nil, subtitleSize: CGFloat = 13, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleSize = subtitleSize
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 18)

            control
                .frame(minWidth: 280, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: subtitle == nil ? 32 : 44)
    }
}

private struct SettingsSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var width: CGFloat = 190

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection

                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? settingsAccentColor : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(settingsAccentColor.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(settingsAccentColor.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(2)
        .frame(width: width)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// A real dropdown (`Picker(.menu)`), for choices too numerous or too visual
/// (image mascots) for the segmented control's fixed-width row.
private struct SettingsDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var width: CGFloat = 190

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].title).tag(options[index].value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: width)
    }
}

private struct SettingsCheckbox: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? settingsAccentColor : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isOn ? 0 : 0.14), lineWidth: 1)
                    )

                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .frame(width: 20, height: 20)
            .padding(4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 0)
    }
}
