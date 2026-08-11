import ImageIO
import SwiftUI

/// The looping "here's how Bilakh works" animation on the final onboarding step:
/// a miniature desktop where a pointer opens the menu-bar menu, picks *Lock
/// Screen*, the screen locks bare, a wrong key press wakes the mascot, and then
/// both unlock routes — the hotkey chord and the sensor — play out once each.
///
/// That middle beat matters for honesty: the real shield shows *nothing* but a
/// faint Touch ID glyph until something is typed or clicked
/// (`LockController`/`bilakhInputAttempt` → `revealed`). Popping the mascot up at
/// the moment of lock would teach a lock screen the app doesn't have.
///
/// Drawn in code rather than recorded on purpose: it stays sharp at any size,
/// follows light/dark, personalises itself with the user's real hotkey and
/// mascot, adds nothing to the bundle, and can be retuned without a re-shoot.
///
/// **Why an async driver and not `PhaseAnimator`.** `PhaseAnimator` advances the
/// moment each phase's animation finishes, so it can't *hold* a phase still, and
/// it gives one curve per phase. Several beats here need both: dwell time (read
/// the menu, register the lock) and sub-animations on their own timing (the chord
/// pressing key by key, two overlapping Touch ID rings). One `Task` flipping
/// state inside `withAnimation` with sleeps between expresses that directly.
///
/// **Two layers, one of them never scaled.** `scaleEffect` transforms an already
/// rasterised layer, so type and SF Symbols pushed through the 1.42× camera move
/// come out soft. Only the desktop layer is scaled; the mascot and the unlock
/// hints live in a sibling layer at their final size and scale *down* when idle,
/// so they are crisp exactly when the viewer is meant to read them.
struct OnboardingLockDemo: View {
    let emoji: String
    let hotkeyDisplay: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: Phase = .idle
    @State private var driver: Task<Void, Never>?
    @State private var ripple: CGFloat = 0
    @State private var pressedKeys = 0
    @State private var ringA: CGFloat = 0
    @State private var ringB: CGFloat = 0
    @State private var touchPress = false
    @State private var wallpaper: NSImage?
    /// The mascot's visibility is its own state, not a function of `phase`: it has
    /// to pop *after* the wrong key press lands, partway through `.intrusion`.
    @State private var revealed = false
    /// Separate from `zoomed` so the chord chips can land *after* the camera push
    /// settles, rather than riding in on it.
    @State private var hintsShown = false

    private let size = CGSize(width: 336, height: 196)
    private let cameraZoom: CGFloat = 1.42

    // MARK: - Phases

    enum Phase {
        case idle, pointerIn, click, menu, pick, locking, intrusion, zoom, hotkey, touch, unlocking

        static let sequence: [Phase] = [
            .idle, .pointerIn, .click, .menu, .pick,
            .locking, .intrusion, .zoom, .hotkey, .touch, .unlocking,
        ]

        /// How long the phase holds once its transition has been kicked off.
        /// Phases with sub-beats (`.intrusion`, `.hotkey`, `.touch`) time
        /// themselves instead.
        var dwell: Double {
            switch self {
            case .idle: 0.65
            case .pointerIn: 0.75
            case .click: 0.45
            case .menu: 0.7
            case .pick: 0.5
            case .locking: 0.8
            // Long on purpose: the mascot has to sit there alone, having done
            // nothing for the intruder, before the demo starts talking about how
            // *you* get back in. Cutting straight from the failed click to the
            // hotkey hint reads as though the click brought the hint up.
            case .intrusion: 1.5
            case .zoom: 0.75
            case .hotkey: 0.55
            case .touch: 0.55
            case .unlocking: 0.8
            }
        }

        /// The curve used to move *into* this phase.
        var curve: Animation {
            switch self {
            case .pointerIn: .easeInOut(duration: 0.65)
            case .click, .pick: .spring(response: 0.26, dampingFraction: 0.6)
            case .menu: .spring(response: 0.3, dampingFraction: 0.72)
            case .locking: .easeOut(duration: 0.5)
            case .zoom: .spring(response: 0.7, dampingFraction: 0.85)
            case .unlocking: .easeInOut(duration: 0.5)
            default: .easeOut(duration: 0.3)
            }
        }
    }

    private var locked: Bool { [.locking, .intrusion, .zoom, .hotkey, .touch].contains(phase) }
    private var zoomed: Bool { [.zoom, .hotkey, .touch].contains(phase) }
    private var menuOpen: Bool { phase == .menu || phase == .pick }
    private var pointerVisible: Bool { [.pointerIn, .click, .menu, .pick, .intrusion].contains(phase) }
    private var pointerPressed: Bool { [.click, .pick, .intrusion].contains(phase) }
    /// Where the intruder pokes the shield — below the mascot's reveal spot, so the
    /// two don't land on top of each other.
    private var intrusionPoint: CGPoint { CGPoint(x: size.width * 0.5, y: size.height * 0.62) }
    private var iconLit: Bool { menuOpen || phase == .click }

    // MARK: - Geometry
    //
    // The status icon's centre is derived from the trailing widths in `menuBar`
    // (10 pad + 30 clock + 10 gap + half of the 22-wide slot), so the pointer,
    // the click ripple and the menu all land on the icon by construction rather
    // than by eyeballed offsets. Change a width there, change it here.
    private var iconCenter: CGPoint { CGPoint(x: size.width - 61, y: 9) }
    private var menuCenter: CGPoint { CGPoint(x: iconCenter.x - 44, y: 47) }

    private var keyCaps: [String] {
        let parts = hotkeyDisplay
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [hotkeyDisplay] : parts
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Camera layer: everything that belongs to the desktop, pushed in
            // together on `.zoom`.
            ZStack {
                desktop
                menuBar
                bilakhIcon
                clickRipple
                lockVeil
                menuPanel
                pointer
            }
            .scaleEffect(zoomed ? cameraZoom : 1, anchor: UnitPoint(x: 0.5, y: 0.82))

            // Crisp layer: never transformed, so it survives the push sharp.
            mascot
            unlockHints
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .onAppear(perform: start)
        .task {
            let image = await Task.detached(priority: .userInitiated) { Self.loadWallpaper() }.value
            withAnimation(.easeOut(duration: 0.35)) { wallpaper = image }
        }
        .onDisappear {
            driver?.cancel()
            driver = nil
        }
        .accessibilityElement()
        .accessibilityLabel(
            "Click the Bilakh icon in the menu bar and choose Lock Screen. "
                + "Unlock with \(hotkeyDisplay) or Touch ID."
        )
    }

    // MARK: - Scene

    /// The user's own wallpaper, so the mock screen looks like *their* desktop
    /// without a single pixel shipping in the bundle. Nothing is drawn on top of
    /// it — no fake windows, no decoration. Falls back to a flat gradient when
    /// there's no still image to read (a video/aerial desktop, or a screen the API
    /// declines to answer for).
    private var desktop: some View {
        Group {
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.17, green: 0.19, blue: 0.27),
                        Color(red: 0.08, green: 0.09, blue: 0.14),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .blur(radius: locked ? 3 : 0)
    }

    /// Reads the desktop picture off disk at thumbnail size — a 6K wallpaper
    /// decoded whole for a 336pt view would cost tens of megabytes of resident
    /// image for no visible gain. Off the main actor because this touches the
    /// filesystem.
    private static func loadWallpaper() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private var menuBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                Image(systemName: "wifi")
                    .font(.system(size: 8))
                    .frame(width: 11)
                Spacer().frame(width: 8)
                Image(systemName: "battery.75percent")
                    .font(.system(size: 9))
                    .frame(width: 13)
                Spacer().frame(width: 10)
                // Slot the icon occupies — the icon itself is drawn on top at
                // `iconCenter` so it can be lit and pressed independently.
                Color.clear.frame(width: 22)
                Spacer().frame(width: 10)
                Text("11:21")
                    .font(.system(size: 8, weight: .medium))
                    .frame(width: 30)
                Spacer().frame(width: 10)
            }
            .foregroundStyle(.white.opacity(0.55))
            .frame(height: 18)
            .background(.white.opacity(0.10))

            Spacer()
        }
    }

    private var bilakhIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color("BilakhAmber").opacity(iconLit ? 0.30 : 0.14))
                .frame(width: 22, height: 16)

            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 10)
                .foregroundStyle(Color("BilakhAmber"))
        }
        .scaleEffect(phase == .click ? 0.9 : 1)
        .position(iconCenter)
    }

    /// Expanding ring under the pointer on a click. `ripple == 0` is the resting
    /// state and must be fully transparent: the driver resets it without an
    /// animation, and a non-zero opacity there would leave a ring parked on
    /// screen between beats.
    private var clickRipple: some View {
        Circle()
            // White while locked: the amber ripples are the two clicks that *do*
            // something, and this one is a poke the shield ignores.
            .strokeBorder(phase == .intrusion ? .white : Color("BilakhAmber"), lineWidth: 1.2)
            .frame(width: 20, height: 20)
            .scaleEffect(0.5 + ripple * 1.6)
            .opacity(ripple == 0 ? 0 : 0.6 * (1 - ripple))
            .position(ripplePoint)
    }

    private var ripplePoint: CGPoint {
        switch phase {
        case .pick: menuRowCenter
        case .intrusion: intrusionPoint
        default: iconCenter
        }
    }

    private var lockVeil: some View {
        ZStack {
            // Deliberately short of opaque: the real shield keeps the desktop
            // visible behind it, and letting the mock windows read faintly through
            // is what makes this look like a screen that got covered rather than a
            // screen that got turned off.
            Rectangle()
                .fill(.black)
                .opacity(locked ? 0.76 : 0)

            RadialGradient(
                colors: [Color("BilakhTeal").opacity(0.18), .clear],
                center: UnitPoint(x: 0.5, y: 0.44),
                startRadius: 4,
                endRadius: 155
            )
            .blendMode(.plusLighter)
            .opacity(locked ? 1 : 0)
        }
    }

    /// A stand-in for the real `MenuBarExtra` menu: only the row being taught
    /// carries text, the rest are bars. At this scale readable type everywhere
    /// would just be noise.
    private var menuPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7))
                Text("Lock Screen")
                    .font(.system(size: 8.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(phase == .pick ? .black.opacity(0.8) : .white.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(phase == .pick ? Color("BilakhAmber") : .clear)
            )

            ForEach(0..<2, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white.opacity(0.18))
                    .frame(width: i == 0 ? 44 : 32, height: 4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
        }
        .padding(4)
        .frame(width: 112, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 9, y: 4)
        .scaleEffect(menuOpen ? 1 : 0.9, anchor: .topTrailing)
        .opacity(menuOpen ? 1 : 0)
        .position(menuCenter)
    }

    /// Centre of the *Lock Screen* row inside `menuPanel`, in scene coordinates —
    /// where the pointer travels and the second ripple fires.
    private var menuRowCenter: CGPoint {
        CGPoint(x: menuCenter.x - 20, y: 32)
    }

    private var pointer: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
            // `cursorarrow`'s tip sits at its top-left, but `.position` places a
            // view by its centre — this nudge makes `pointerPoint` mean "the tip".
            .offset(x: 4, y: 5)
            .scaleEffect(pointerPressed ? 0.85 : 1)
            .opacity(pointerVisible ? 1 : 0)
            .position(pointerPoint)
    }

    private var pointerPoint: CGPoint {
        switch phase {
        case .menu, .pick:
            CGPoint(x: menuRowCenter.x, y: menuRowCenter.y + 1)
        case .intrusion:
            intrusionPoint
        case .idle, .unlocking:
            CGPoint(x: size.width * 0.44, y: size.height * 0.72)
        default:
            CGPoint(x: iconCenter.x + 2, y: iconCenter.y + 5)
        }
    }

    /// Pops on the failed attempt, then rides the camera push up and forward —
    /// scaling *up to* 1 rather than past it, so the frame the viewer reads longest
    /// is the unscaled, sharp one.
    private var mascot: some View {
        Text(emoji)
            .font(.system(size: 46))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(revealed ? (zoomed ? 1 : 0.72) : 0.5)
            .opacity(revealed ? 1 : 0)
            .position(x: size.width / 2, y: size.height * (zoomed ? 0.34 : 0.45))
    }

    /// The hotkey chord and the Touch ID glyph, bottom-centre — the same pair the
    /// real lock screen offers. The glyph is present from the moment the shield
    /// goes up (faint and centred, as it actually is); the chips insert on
    /// `.zoom`, and the layout change is what slides the glyph over to make room.
    private var unlockHints: some View {
        VStack {
            Spacer()

            HStack(spacing: 7) {
                if hintsShown {
                    HStack(spacing: 4) {
                        ForEach(Array(keyCaps.enumerated()), id: \.offset) { index, cap in
                            Text(cap)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color("BilakhAmber"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color("BilakhAmber")
                                            .opacity(index < pressedKeys ? 0.32 : 0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Color("BilakhAmber")
                                            .opacity(index < pressedKeys ? 0.55 : 0.16), lineWidth: 1)
                                )
                                .scaleEffect(index < pressedKeys ? 0.93 : 1)
                        }
                    }

                    Text("or")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }

                touchGlyph
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
            .padding(.bottom, 16)
        }
        .opacity(locked ? 1 : 0)
    }

    private var touchGlyph: some View {
        ZStack {
            ring(ringA)
            ring(ringB)

            Image(systemName: "touchid")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color("BilakhAmber"))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color("BilakhAmber").opacity(zoomed ? 0.10 : 0))
                )
                .scaleEffect(touchPress ? 0.94 : 1)
        }
        .scaleEffect(zoomed ? 1 : 0.6)
        .opacity(zoomed ? 1 : 0.5)
    }

    /// One outward pulse. Same resting-state rule as `clickRipple`: `progress == 0`
    /// is invisible, so the driver's un-animated reset doesn't strand a ring.
    private func ring(_ progress: CGFloat) -> some View {
        Circle()
            .strokeBorder(Color("BilakhAmber"), lineWidth: 1.2)
            .frame(width: 26, height: 26)
            .scaleEffect(0.7 + progress * 1.5)
            .opacity(progress == 0 ? 0 : 0.5 * (1 - progress))
    }

    // MARK: - Driver

    private func start() {
        guard !reduceMotion else {
            // Motion off: hold the frame that carries the headline's claim —
            // the icon sitting lit in the menu bar. `OnboardingView` puts the
            // unlock hints back as static text in this case.
            phase = .idle
            return
        }
        driver?.cancel()
        driver = Task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            for step in Phase.sequence {
                guard !Task.isCancelled else { return }
                withAnimation(step.curve) { phase = step }
                await beats(for: step)
            }
            await sleep(0.4)
        }
    }

    /// Per-phase sub-animations, each responsible for its own dwell.
    private func beats(for step: Phase) async {
        switch step {
        case .click, .pick:
            await arm($ripple)
            withAnimation(.easeOut(duration: 0.55)) { ripple = 1 }
            await sleep(step.dwell)
            ripple = 0

        case .intrusion:
            // Someone clicks the shield. Nothing unlocks — and *that* is what wakes
            // the mascot.
            await sleep(0.28)
            await arm($ripple)
            withAnimation(.easeOut(duration: 0.5)) { ripple = 1 }
            await sleep(0.16)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { revealed = true }
            await sleep(step.dwell)
            ripple = 0

        case .zoom:
            // Push the camera in first, land the hints once it has settled.
            await sleep(0.5)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { hintsShown = true }
            await sleep(step.dwell)

        case .hotkey:
            // Press the chord key by key, hold it, release it all at once.
            for count in 1...keyCaps.count {
                await sleep(0.13)
                withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { pressedKeys = count }
            }
            await sleep(0.45)
            withAnimation(.easeOut(duration: 0.2)) { pressedKeys = 0 }
            await sleep(step.dwell)

        case .touch:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { touchPress = true }
            // Two rings on separate state so they can overlap; resetting one
            // mid-flight to re-fire it would pop.
            await arm($ringA)
            withAnimation(.easeOut(duration: 0.85)) { ringA = 1 }
            await sleep(0.34)
            await arm($ringB)
            withAnimation(.easeOut(duration: 0.85)) { ringB = 1 }
            await sleep(0.5)
            withAnimation(.easeOut(duration: 0.25)) { touchPress = false }
            await sleep(step.dwell)
            ringA = 0
            ringB = 0

        case .unlocking:
            // Drop the reveal with the veil, so the next pass round the loop starts
            // from a genuinely bare shield instead of a pre-woken one.
            withAnimation(.easeInOut(duration: 0.4)) {
                revealed = false
                hintsShown = false
            }
            await sleep(step.dwell)

        default:
            await sleep(step.dwell)
        }
    }

    /// Nudges a pulse's progress off its invisible resting state and waits for that
    /// frame to actually render.
    ///
    /// Both pulse shapes fade *out* as progress runs 0 → 1, and are transparent at
    /// exactly 0 so an un-animated reset can't leave a ring parked on screen. That
    /// makes the naive `withAnimation { progress = 1 }` animate opacity from 0 to 0 —
    /// nothing visible ever happens. The sleep is the load-bearing part: SwiftUI
    /// coalesces state written in one turn of the run loop, so without yielding
    /// long enough to draw, the epsilon frame is never rendered and the animation
    /// still starts from a transparent ring.
    private func arm(_ progress: Binding<CGFloat>) async {
        progress.wrappedValue = 0.001
        await sleep(0.03)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// To see this in the real window, a Debug build answers
// `open "bilakh://onboarding?step=3"`. This canvas is for tuning timings without
// a rebuild.
#Preview("Lock demo") {
    OnboardingLockDemo(emoji: "🖕🏻", hotkeyDisplay: "Cmd+Shift+L")
        .padding(40)
}
