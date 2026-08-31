import SwiftUI

/// Fades the top few points of a scrolling view out to nothing, so content
/// dissolves as it passes under the scope banner instead of being cut off
/// against it.
///
/// A **mask**, not a gradient overlay: an overlay has to guess the colour
/// behind it, and this content scrolls over the grouped background on three
/// different screens with cards, list separators and charts of their own
/// passing underneath. Masking removes the pixels instead of painting over
/// them, so whatever the page's real background is comes through by
/// definition.
struct FadingTopEdge: ViewModifier {
    var height: CGFloat = 22

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black], startPoint: .top, endPoint: .bottom
                )
                .frame(height: height)
                Color.black
            }
        }
    }
}

extension View {
    func fadingTopEdge(_ height: CGFloat = 22) -> some View {
        modifier(FadingTopEdge(height: height))
    }
}
