import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "in.pooya.flipoff", category: "Authenticator")

@MainActor
class Authenticator {
    private var activeContext: LAContext?
    /// The passive Touch ID listener's context is tracked separately from
    /// `activeContext`: they run concurrently, and a shared slot meant each one's
    /// `cancelPending()` invalidated the other's in-flight read.
    private var autoUnlockContext: LAContext?

    /// True only where a biometric sensor actually exists and is enrolled. Macs
    /// without Touch ID fail `canEvaluatePolicy` instantly, so the passive
    /// listener must check this once rather than re-arming into a busy loop.
    var isBiometricsAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Authenticate with Touch ID, with password fallback via system dialog.
    func authenticate(reason: String = "Unlock FlipOff") async -> Bool {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password\u{2026}"
        activeContext = context

        defer { activeContext = nil }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.error("Auth not available: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        // Evaluate off MainActor to avoid deadlock — system dialog needs main thread
        return await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
            } catch {
                await MainActor.run {
                    logger.info("Auth cancelled or failed: \(error.localizedDescription)")
                }
                return false
            }
        }.value
    }

    /// A fresh context for the lock screen's embedded Touch ID glyph to pair with.
    /// Handed out *before* any evaluation so `LAAuthenticationView` can be
    /// constructed around it — the pairing happens at the view's init, and
    /// `evaluatePolicy` afterwards renders into that view instead of a system alert.
    ///
    /// Returns nil where biometrics can't be used at all (no sensor, none
    /// enrolled), so the caller can skip mounting a glyph that would never light up.
    func makeAutoUnlockContext() -> LAContext? {
        cancelPendingAutoUnlock()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            logger.info("Biometrics not available: \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        autoUnlockContext = context
        return context
    }

    /// Arms the sensor on a context previously handed out by
    /// `makeAutoUnlockContext()`. Because that context is already paired with an
    /// on-screen `LAAuthenticationView`, this presents **no modal** — the prompt
    /// draws in the glyph on the lock screen. Resolves true the moment a matching
    /// finger lands.
    ///
    /// Deliberately biometrics-only: the password fallback needs a real dialog and
    /// goes through `authenticateWithPassword()` on an explicit user action.
    func armEmbeddedBiometrics(
        _ context: LAContext,
        reason: String = "Unlock FlipOff"
    ) async -> Bool {
        await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
            } catch {
                let code = (error as NSError).code
                await MainActor.run {
                    logger.info("Embedded biometric read ended: code=\(code, privacy: .public) \(error.localizedDescription, privacy: .public)")
                }
                return false
            }
        }.value
    }

    /// Authenticate with macOS password (system dialog, user can click "Use Password").
    func authenticateWithPassword(reason: String = "Enter your password to unlock FlipOff") async -> Bool {
        cancelPending()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = ""
        activeContext = context

        defer { activeContext = nil }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.error("Password auth not available: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        return await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
            } catch {
                await MainActor.run {
                    logger.info("Password auth cancelled or failed: \(error.localizedDescription)")
                }
                return false
            }
        }.value
    }

    /// Cancels a manual (hotkey-initiated) auth. Leaves the passive Touch ID
    /// listener alone — it re-arms itself and must survive a cancelled manual auth.
    func cancelPending() {
        activeContext?.invalidate()
        activeContext = nil
    }

    /// Cancels only the passive Touch ID listener.
    func cancelPendingAutoUnlock() {
        autoUnlockContext?.invalidate()
        autoUnlockContext = nil
    }

    /// Cancels everything — used on unlock/force-unlock teardown.
    func cancelAll() {
        cancelPending()
        cancelPendingAutoUnlock()
    }
}
