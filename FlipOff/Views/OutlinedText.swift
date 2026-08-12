import SwiftUI

/// Text with a solid outline — SwiftUI's `Text` has no native stroke, so this
/// fakes one the standard way: several copies of the string in the stroke color,
/// offset in a ring around the real (fill-colored) text on top. Cheap enough for
/// a one-line lock message; not meant for body text or anything that reflows.
struct OutlinedText: View {
    let text: String
    let font: Font
    let fill: Color
    let stroke: Color
    let strokeWidth: CGFloat

    init(_ text: String, font: Font, fill: Color, stroke: Color, strokeWidth: CGFloat = 4) {
        self.text = text
        self.font = font
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }

    var body: some View {
        ZStack {
            ForEach(Self.offsets(for: strokeWidth), id: \.self) { offset in
                Text(text)
                    .font(font)
                    .foregroundStyle(stroke)
                    .offset(x: offset.width, y: offset.height)
            }
            Text(text)
                .font(font)
                .foregroundStyle(fill)
        }
    }

    /// Eight-direction ring at `strokeWidth`, plus the four half-strength
    /// diagonals filled in at 0.7× so the outline reads as a smooth ring rather
    /// than a visible octagon at large sizes.
    private static func offsets(for width: CGFloat) -> [CGSize] {
        let diag = width * 0.7
        return [
            CGSize(width: -width, height: 0), CGSize(width: width, height: 0),
            CGSize(width: 0, height: -width), CGSize(width: 0, height: width),
            CGSize(width: -diag, height: -diag), CGSize(width: diag, height: -diag),
            CGSize(width: -diag, height: diag), CGSize(width: diag, height: diag)
        ]
    }
}
