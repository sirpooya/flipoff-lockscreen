import SwiftUI

enum ScreenRole {
    case primary
    case ambient
}

struct LockScreenView: View {
    @ObservedObject var controller: LockController
    var screenRole: ScreenRole = .primary
    var phaseOffset: CGFloat = 0
    /// Frozen screenshot of this display, taken just before the lock. Nil when
    /// Screen Recording is denied or the capture failed — the gradient stands in.
    var backdrop: CGImage?

    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage(EmojiMascot.storageKey) private var mascotEmoji = EmojiMascot.defaultValue
    @AppStorage(HotkeyConfig.requireAuthenticationToUnlockKey) private var requiresAuthenticationToUnlock = HotkeyConfig.defaultRequireAuthenticationToUnlock
    @AppStorage(Constants.Backdrop.dimKey) private var backdropDim = Constants.Backdrop.defaultDim
    @AppStorage(Constants.Backdrop.blurKey) private var backdropBlur = Constants.Backdrop.defaultBlur

    @State private var phase: CGFloat = 0
    @State private var appeared = false
    /// Mascot pop-in, kept separate from `appeared` so it can run on a springier
    /// curve than the rest of the content group.
    @State private var mascotPopped = false
    /// Message scale-up, a beat behind the mascot so the two don't land together.
    @State private var messagePopped = false
    @State private var hoveringAuth = false
    @State private var shakeOffset: CGFloat = 0
    @State private var successScale: CGFloat = 1.0
    @State private var pingGlow: CGFloat = 0
    @State private var pingGlowGeneration = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var breathe: CGFloat { reduceMotion ? 0 : sin((phase + phaseOffset) * .pi * 2 * 0.2) }
    private var drift: CGFloat { reduceMotion ? 0 : sin((phase + phaseOffset) * .pi * 2 * 0.05) }
    private var resolvedEmoji: String { EmojiMascot.resolved(from: mascotEmoji) }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let mascotSize = min(geo.size.width * 0.2, geo.size.height * 0.3)
            let unit = mascotSize * 0.12

            ZStack {
                background(geo: geo)

                // Content group — positioned at ~42% from top (slightly below center)
                VStack(spacing: 0) {
                    Spacer().frame(minHeight: 0)
                        .frame(height: geo.size.height * 0.32)

                    // Mascot + message + time as a tight cohesive group
                    VStack(spacing: unit * 1.2) {

                        // Mascot
                        ZStack {
                            if controller.unlockSucceeded {
                                // Success animation: mascot scales up and fades
                                mascotGlyph
                                    .frame(width: mascotSize, height: mascotSize)
                                    .scaleEffect(successScale)
                                    .opacity(2.0 - Double(successScale))
                                    .shadow(color: Color("BilakhTeal").opacity(0.3), radius: 50, y: 0)
                            } else {
                                ZStack {
                                    Ellipse()
                                        .fill(Color("BilakhTeal").opacity(0.02 + breathe * 0.02))
                                        .frame(width: mascotSize * 0.45, height: mascotSize * 0.1)
                                        .blur(radius: 12)
                                        .offset(y: mascotSize * 0.45)

                                    mascotGlyph
                                        .frame(width: mascotSize, height: mascotSize)
                                        .shadow(color: Color("BilakhTeal").opacity(0.15 + breathe * 0.08), radius: 35 + breathe * 8, y: 10)
                                        .shadow(color: .black.opacity(0.15), radius: 45, y: 30)
                                        .offset(y: breathe * 4)
                                }
                                .opacity(controller.isAuthenticating ? 0.5 : 1)
                            }
                        }
                        .scaleEffect(mascotPopped ? 1 : 0.5)
                        .opacity(mascotPopped ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)

                        // Message
                        Group {
                            if controller.unlockSucceeded {
                                EmptyView()
                            } else if controller.isAuthenticating {
                                Text("Authenticating\u{2026}")
                                    .font(.lockBody(compact: compact))
                                    .foregroundStyle(.white.opacity(0.55))
                            } else if let error = controller.lastError {
                                // Same body role as the message — color carries the
                                // error, weight just steadies it.
                                Text(error)
                                    .font(.lockBody(compact: compact))
                                    .fontWeight(.medium)
                                    .foregroundStyle(Color("BilakhError"))
                                    .shadow(color: Color("BilakhError").opacity(0.15), radius: 8)
                            } else if showMessage {
                                // Big and white with a bold outline, not the quiet
                                // small white body type the other states use — this
                                // is the punchline of the prank, so it lands like a
                                // shout no matter what's behind it in the backdrop.
                                OutlinedText(
                                    message,
                                    font: .system(size: compact ? 44 : 76, weight: .heavy, design: .rounded),
                                    fill: .white,
                                    stroke: .black,
                                    strokeWidth: 4
                                )
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                                .scaleEffect(messagePopped ? 1 : 0.4)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                        .tracking(0.35)
                        .padding(.horizontal, max(48, geo.size.width * 0.1))
                        .opacity(appeared ? 1 : 0)
                        .animation(Constants.Anim.gentle, value: controller.isAuthenticating)
                        .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)
                        .animation(Constants.Anim.standard, value: controller.lastError)
                        .allowsHitTesting(false)

                        // Standing agent hint — quiet, persistent companion to the
                        // glow pulses; stays until unlock.
                        if controller.agentAttention && !controller.unlockSucceeded {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color("BilakhTeal"))
                                    .frame(width: 5, height: 5)
                                    .opacity(0.55 + breathe * 0.3)
                                Text("Your agent needs you")
                                    .font(.lockCaption)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .tracking(0.5)
                            }
                            .transition(.opacity)
                            .allowsHitTesting(false)
                        }
                    }
                    .animation(Constants.Anim.gentle, value: controller.agentAttention)

                    Spacer()

                    // Bottom area
                    ZStack {
                        if controller.unlockSucceeded {
                            EmptyView()
                        } else if controller.isAuthenticating {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(1.2)
                                    .tint(Color("BilakhTeal"))
                                VStack(spacing: 4) {
                                    Text("Use Touch ID or enter your Mac password")
                                        .font(.lockCaption)
                                        .foregroundStyle(.white.opacity(0.55))
                                    Text("Check for a system dialog")
                                        .font(.lockCaption)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                .tracking(0.5)
                            }
                            .transition(.opacity)
                        } else {
                            // Fallback auth, shown once the lock has revealed itself.
                            VStack(spacing: 16) {
                                Button {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                    controller.requestUnlock()
                                } label: {
                                    Text(requiresAuthenticationToUnlock ? "Authenticate to Unlock" : "Authenticate with Touch ID")
                                        .font(.lockLabel)
                                        .foregroundStyle(.white.opacity(hoveringAuth ? 0.6 : 0.4))
                                        .tracking(0.3)
                                        .frame(minHeight: 44)
                                        .padding(.horizontal, 20)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(.ultraThinMaterial.opacity(hoveringAuth ? 0.5 : 0.3))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(.white.opacity(hoveringAuth ? 0.08 : 0.04), lineWidth: 0.5)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { hoveringAuth = $0 }
                                .accessibilityLabel("Authenticate with Touch ID or Mac password")
                            }
                            .transition(.opacity)
                        }
                    }
                    .frame(height: 120)
                    .padding(.bottom, compact ? 16 : 40)
                    .animation(Constants.Anim.gentle, value: controller.isAuthenticating)
                    .animation(Constants.Anim.gentle, value: controller.unlockSucceeded)
                    .offset(x: shakeOffset)
                }
                // Nothing on the shield draws until the first input attempt — the
                // screen has to pass for an unlocked desktop, so a stray hint or
                // auth button would spoil it before anyone touches the machine.
                .opacity(controller.revealed ? 1 : 0)
                .allowsHitTesting(controller.revealed)
                .animation(.easeOut(duration: 0.25), value: controller.revealed)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            // Only the backdrop is shown on lock. `appeared`/`mascotPopped` wait
            // for the first input attempt (see the `revealed` handler below), so
            // the shield stays bare until someone touches the machine.
            guard !reduceMotion else { return }
            withAnimation(Constants.Anim.breathe) { phase = Constants.Anim.breathePhaseTarget }
        }
        .onChange(of: controller.revealed) { _, isRevealed in
            guard isRevealed else {
                // Drop the pop states immediately (no animation — the container
                // fade above already covers the visible transition) so the next
                // reveal on this same lock pops in fresh instead of appearing
                // pre-popped.
                appeared = false
                mascotPopped = false
                messagePopped = false
                return
            }
            withAnimation(reduceMotion ? .none : .timingCurve(0.16, 1, 0.3, 1, duration: 0.6)) { appeared = true }
            // Mascot pops in on a spring — scales up from 0.5 while fading in, a
            // beat snappier than the surrounding text so it reads as the subject.
            withAnimation(reduceMotion ? .none : .spring(response: 0.5, dampingFraction: 0.6)) { mascotPopped = true }
            withAnimation(reduceMotion ? .none : .spring(response: 0.55, dampingFraction: 0.62).delay(0.08)) { messagePopped = true }
        }
        .onChange(of: controller.lastError) { _, error in
            guard error != nil else { return }
            withAnimation(.easeInOut(duration: 0.12).repeatCount(4, autoreverses: true)) { shakeOffset = 6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.12)) { shakeOffset = 0 }
            }
        }
        .onChange(of: controller.unlockSucceeded) { _, succeeded in
            if succeeded {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(.easeOut(duration: 0.35)) { successScale = 1.15 }
            }
        }
        .onChange(of: controller.pingPulse) { _, _ in
            triggerPingGlow()
        }
    }

    /// Attention glow: a few slow breaths (rise to peak, settle to a floor, repeat)
    /// rather than one quick flash — calmer, and reads from across a room.
    /// Only the primary screen glows (secondary displays show the ambient view).
    /// The generation counter cancels a stale pulse chain if a new ping lands mid-sequence.
    private func triggerPingGlow() {
        guard screenRole == .primary else { return }
        pingGlowGeneration += 1
        let generation = pingGlowGeneration

        if reduceMotion {
            withAnimation(Constants.Anim.standard) { pingGlow = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.pingPulsePeriod) {
                guard generation == pingGlowGeneration else { return }
                withAnimation(Constants.Anim.gentle) { pingGlow = Constants.Timing.pingGlowRest }
            }
            return
        }

        let half = Constants.Timing.pingPulsePeriod / 2
        for breath in 0..<Constants.Timing.pingPulseCount {
            let start = Double(breath) * Constants.Timing.pingPulsePeriod
            let isLast = breath == Constants.Timing.pingPulseCount - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                guard generation == pingGlowGeneration else { return }
                withAnimation(.easeInOut(duration: half)) { pingGlow = 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + start + half) {
                guard generation == pingGlowGeneration else { return }
                // Settle to a faint resting glow, not black — the agent still
                // needs attention; the hint under the timer carries the message.
                withAnimation(.easeInOut(duration: isLast ? half * 1.4 : half)) {
                    pingGlow = isLast ? Constants.Timing.pingGlowRest : Constants.Timing.pingPulseFloor
                }
            }
        }
    }

    // MARK: - Mascot

    /// Renders the emoji glyph filling the `mascotSize × mascotSize` frame the
    /// caller applies. `Text` has no `.scaledToFit()`, so the size is computed via
    /// `.system(size:)` at a large fraction of the frame — a `GeometryReader`
    /// picks that up without the caller needing to pass the size down separately.
    private var mascotGlyph: some View {
        GeometryReader { proxy in
            Text(resolvedEmoji)
                .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.82))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    // MARK: - Background

    private func background(geo: GeometryProxy) -> some View {
        ZStack {
            if let backdrop {
                // The frozen desktop replaces the gradient wholesale — the drifting
                // color pools would read as smudges over real content.
                //
                // Undimmed and unblurred until revealed: the whole point is that the
                // screen looks untouched, so a scrim would give the lock away before
                // anyone touches the machine. The dim fades in with the mascot, where
                // it earns its keep making the white text readable.
                BackdropView(
                    image: backdrop,
                    dim: controller.revealed ? backdropDim : 0,
                    blur: controller.revealed ? backdropBlur : 0
                )
            } else {
                LinearGradient(
                    colors: [Color(red: 0.01, green: 0.005, blue: 0.025), .black, Color(red: 0.01, green: 0.005, blue: 0.02)],
                    startPoint: .top, endPoint: .bottom
                ).ignoresSafeArea()

                RadialGradient(
                    colors: [Color("BilakhTeal").opacity(0.015 + breathe * 0.005), .clear],
                    center: .bottom, startRadius: 0, endRadius: 500
                ).ignoresSafeArea().allowsHitTesting(false)

                if !reduceMotion { colorPools(geo: geo) }
            }

            // Attention glow — fires on an agent ping. Bright and full-screen so it
            // reads from across a room while the screen stays covered.
            if pingGlow > 0 {
                // Mid-stop keeps a wide band at full saturation — a single
                // stop-to-clear ramp washed the brand green toward pale cyan.
                RadialGradient(
                    stops: [
                        .init(color: Color("BilakhTeal").opacity(0.30 * pingGlow), location: 0),
                        .init(color: Color("BilakhTeal").opacity(0.14 * pingGlow), location: 0.45),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center, startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.8
                )
                .ignoresSafeArea()
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
    }

    private func colorPools(geo: GeometryProxy) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color("BilakhTeal").opacity(0.04 + breathe * 0.04), .clear], center: .center, startRadius: 0, endRadius: 300 + breathe * 40))
                .frame(width: 600, height: 600)
                .position(x: geo.size.width * 0.35 + drift * 10, y: geo.size.height * 0.3 + breathe * 8)
                .blur(radius: 80)

            Circle()
                .fill(RadialGradient(colors: [Color("BilakhAmber").opacity(0.02 + drift * 0.025), .clear], center: .center, startRadius: 0, endRadius: 250 + drift * 30))
                .frame(width: 500, height: 500)
                .position(x: geo.size.width * 0.65 - drift * 8, y: geo.size.height * 0.65 - breathe * 6)
                .blur(radius: 60)
        }
        .opacity(appeared ? 1 : 0)
        .allowsHitTesting(false)
    }
}
