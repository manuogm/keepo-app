import SwiftUI

/// Dissolves the top and bottom of a scrolling view, so content disappears
/// under the scope banner and the floating tab bar instead of being cut off
/// against them.
///
/// A **mask**, not gradient overlays: an overlay has to guess the colour
/// behind it, and this content scrolls over the grouped background on three
/// different screens with cards, list separators and charts of their own
/// passing underneath. Masking removes the pixels instead of painting over
/// them, so whatever the page's real background is comes through by
/// definition.
///
/// The two ends are deliberately different lengths. The top is a short
/// hand-off to a banner sitting directly on the content. The bottom runs
/// the full distance from the tab bar's top edge to the screen, because
/// there is no edge down there to hand off to — content now runs past the
/// bar to the physical bottom of the display (`dropsBottomSafeArea`), and
/// the fade is the only thing that ends it.
struct FadingEdges: ViewModifier {
    var top: CGFloat = 22
    var bottom: CGFloat = KeepoTabBarMetrics.topEdge

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black], startPoint: .top, endPoint: .bottom
                )
                .frame(height: top)
                Color.black
                LinearGradient(
                    colors: [Color.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom
                )
                .frame(height: bottom)
            }
        }
    }
}

extension View {
    func fadingEdges(top: CGFloat = 22, bottom: CGFloat = KeepoTabBarMetrics.topEdge) -> some View {
        modifier(FadingEdges(top: top, bottom: bottom))
    }
}
