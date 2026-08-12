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
    /// `.small` rather than `.large`: the system glyph is a saturated red Touch ID
    /// mark, which reads as an alert badge on a dark shield. Shrinking it and
    /// desaturating at the call site keeps it a hint rather than a warning.
    var controlSize: NSControl.ControlSize = .small

    func makeNSView(context ctx: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: controlSize)
    }

    func updateNSView(_ nsView: LAAuthenticationView, context ctx: Context) {
        // Nothing to push: the view's context is immutable after init. A new
        // context means a new view, which SwiftUI gets by way of the `.id()` the
        // caller attaches to the arming generation.
    }
}
