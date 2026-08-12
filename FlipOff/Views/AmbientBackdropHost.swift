import SwiftUI

/// Observes the controller on behalf of `AmbientScreenView`.
///
/// The overlay content factory runs once per screen and captures plain values, so
/// a secondary display would never see `revealed` flip. This thin wrapper holds
/// the `@ObservedObject` reference that re-renders the ambient view when the lock
/// reveals itself, keeping every screen's dim in step with the primary.
struct AmbientBackdropHost: View {
    @ObservedObject var controller: LockController
    let index: Int
    let backdrop: CGImage?

    var body: some View {
        AmbientScreenView(
            phaseOffset: CGFloat(index) * 0.15,
            backdrop: backdrop,
            revealed: controller.revealed
        )
    }
}
