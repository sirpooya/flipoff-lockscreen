import SwiftUI

/// A secondary display under the lock. Nothing is drawn: the shield window there is
/// transparent and that display's real desktop keeps rendering through it, exactly
/// as on the primary.
///
/// All this contributes is the reveal scrim, mirrored from the primary screen — a
/// dimmed second monitor would give the lock away just as loudly as a dimmed main
/// one, so the two fade together or not at all.
struct AmbientScreenView: View {
    var revealed: Bool = false

    @AppStorage(Constants.Backdrop.dimKey) private var backdropDim = Constants.Backdrop.defaultDim

    var body: some View {
        Color.black
            .opacity(revealed ? backdropDim : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
