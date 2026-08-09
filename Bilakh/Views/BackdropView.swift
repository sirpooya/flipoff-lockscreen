import SwiftUI

/// The frozen screenshot of the display this overlay covers, dimmed enough that
/// the lock UI stays legible over arbitrary desktop content.
///
/// `.fill` rather than `.fit`: the capture is the display's exact aspect ratio, so
/// fill is a no-op in the normal case but avoids letterboxing if a resolution
/// change lands between capture and display.
struct BackdropView: View {
    let image: CGImage
    var dim: Double
    var blur: Double

    var body: some View {
        GeometryReader { geo in
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                // opaque: true keeps the blur from sampling transparent edges and
                // fading the border of the still.
                .blur(radius: blur, opaque: true)
                .clipped()
                .overlay(Color.black.opacity(dim))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
