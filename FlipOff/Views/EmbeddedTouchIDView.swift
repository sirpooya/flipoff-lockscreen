import SwiftUI
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import os.log

private let logger = Logger(subsystem: "in.pooya.flipoff", category: "EmbeddedTouchID")

/// The Touch ID glyph on the lock screen, and the only way this app can read the
/// sensor without a system modal landing on top of the shield.
///
/// `LAAuthenticationView` (macOS 12+) is paired with an `LAContext` at init; from
/// then on, `evaluatePolicy` on *that* context renders its prompt **inside this
/// view** instead of the standard authentication alert. That's the whole trick —
/// the sensor is armed exactly as it would be by a modal `evaluatePolicy`, so
/// resting a finger unlocks, but nothing floats above the lock screen.
///
/// Two constraints from the framework, both load-bearing here:
///
/// - **The view is non-textual.** Apple's header: "The reason for the
///   authentication must be apparent from the surrounding UI to avoid confusion and
///   security risks." The lock screen is that surrounding UI.
/// - **It must be in the window and visible.** A hidden or zero-sized view has
///   nowhere to draw the prompt, so the glyph can't be tucked away to keep the
///   shield perfectly bare — that's the trade for finger-to-unlock.
///
/// Only `.deviceOwnerAuthenticationWithBiometrics` (and the companion/watch
/// variants) are supported policies; a password fallback still needs the ordinary
/// modal path in `Authenticator`.
struct EmbeddedTouchIDView: NSViewRepresentable {
    /// Context to arm. Owned by the caller so it can be invalidated on unlock —
    /// the view holds it `readonly` and cannot cancel an in-flight read itself.
    let context: LAContext

    /// Sets the size the glyph draws at, and **only these four sizes exist**. The
    /// view reports no intrinsic size (`-1, -1`) and ignores whatever frame SwiftUI
    /// hands it. Measured fitting sizes:
    ///
    ///     .mini 16pt · .small 32pt · .regular 64pt · .large 128pt
    ///
    /// Sizes in between are unreachable, and both obvious routes there fail in
    /// ways that only show up at runtime:
    ///
    /// - **`.scaleEffect` breaks the sensor.** The layer transform is invisible to
    ///   AppKit's occlusion detection, so the framework decides the view "is not
    ///   visible to user because it is occluded", declines to arm, and draws
    ///   nothing. The read ends -4 and the only evidence is in the system log.
    /// - **A frame/bounds mismatch draws nothing.** AppKit's own geometry scale
    ///   keeps arming intact ("is showing Touch ID", "ROI became unoccluded") but
    ///   the layer-backed `PKGlyphView` inside renders blank — verified by
    ///   screenshotting native 32pt, bounds-scaled 24pt and native 16pt side by
    ///   side: only the native ones have a fingerprint in them.
    ///
    /// So pick a native size and size the surrounding chrome to it. Larger than
    /// `.small` reads as an alert badge rather than the quiet hint this is meant to
    /// be — the system mark is a saturated red, desaturated at the call site.
    var controlSize: NSControl.ControlSize = .mini

    func makeNSView(context ctx: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: controlSize)
    }

    func updateNSView(_ nsView: LAAuthenticationView, context ctx: Context) {
        // Nothing to push: the view's context is immutable after init. A new
        // context means a new view, which SwiftUI gets by way of the `.id()` the
        // caller attaches to the arming generation.
    }

    static func nativeSize(for controlSize: NSControl.ControlSize) -> CGFloat {
        switch controlSize {
        case .mini: 16
        case .small: 32
        case .regular: 64
        case .large: 128
        @unknown default: 32
        }
    }
}
