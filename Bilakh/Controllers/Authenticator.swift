import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "in.pooya.bilakh", category: "Authenticator")

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
    func authenticate(reason: String = "Unlock Bilakh") async -> Bool {
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

    /// Touch ID only, no password fallback — used to quietly re-arm in the
    /// background while locked so resting a finger on the sensor unlocks
    /// instantly without the user having to invoke the hotkey first.
    func authenticateWithBiometricsOnly(reason: String = "Unlock Bilakh") async -> Bool {
        cancelPendingAutoUnlock()

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        autoUnlockContext = context

        defer { autoUnlockContext = nil }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            logger.info("Biometrics not available: \(error?.localizedDescription ?? "unknown")")
            return false
        }

        return await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
            } catch {
                let code = (error as NSError).code
                await MainActor.run {
                    logger.info("Biometric auto-unlock failed: code=\(code, privacy: .public) \(error.localizedDescription, privacy: .public)")
                }
                return false
            }
        }.value
    }

    /// Authenticate with macOS password (system dialog, user can click "Use Password").
    func authenticateWithPassword(reason: String = "Enter your password to unlock Bilakh") async -> Bool {
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
