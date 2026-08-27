import KeepoCore
import SwiftUI
import UIKit

/// A currency's flag in a circle, with its code beside it.
///
/// The circle is the constant, not the flag: a currency with no honest flag
/// (a supranational code, a metal) gets a grey globe at the same diameter, and
/// so does the "everything else" roll-up in Currency Exposure. A row where one
/// item is a flag and the next is a bare glyph reads as a rendering bug, so
/// both branches are drawn here rather than left to each caller.
struct CurrencyBadge: View {
    /// `nil` renders the "rest of your currencies" badge.
    let code: String?
    var diameter: CGFloat = 22
    var showsCode = true
    /// What to write instead of a code — "REST" for the roll-up.
    var label: String?

    var body: some View {
        HStack(spacing: 4) {
            disc
            if showsCode {
                Text(label ?? code ?? "—")
                    .font(.system(size: diameter * 0.55, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    // A currency code is three letters and must never be
                    // one of them plus an ellipsis. Without this, sharing a
                    // row with a headline figure truncated "EUR" to "E…",
                    // which reads as a different currency rather than as a
                    // squeezed label.
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var disc: some View {
        if let flagAsset {
            // The artwork is already a disc — that is the whole point of
            // `circle-flags`, and why this no longer needs the grey backing
            // plate, the 1.35 `scaleEffect` and the clip that the emoji
            // version did. A flag emoji is wider than it is tall and is drawn
            // by the system font, so fitting one inside a circle meant
            // overscaling it and cropping the overflow; every disc lost a
            // sliver of its own flag, and the amount lost varied by font.
            Image(flagAsset)
                .resizable()
                .scaledToFit()
                .frame(width: diameter, height: diameter)
                // Belt and braces against a flag whose artwork doesn't quite
                // reach its own bounds: the circle stays a circle either way.
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.16))
                Image(systemName: "globe")
                    .font(.system(size: diameter * 0.52, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .frame(width: diameter, height: diameter)
        }
    }

    /// The bundled flag for this currency, or `nil` to draw the globe.
    ///
    /// The existence check is not defensive noise. `CurrencyRegion` derives a
    /// name from the currency code's own letters, so it will happily name
    /// `flag-zz` for a code whose first two letters are not a real region —
    /// and `Image(_:)` given a name it cannot find draws **nothing at all**,
    /// silently, leaving a hole where the badge should be. Asking the bundle
    /// first turns that into the globe every other unknown currency gets.
    private var flagAsset: String? {
        guard let code, let name = CurrencyRegion.flagAssetName(for: code),
              UIImage(named: name) != nil
        else { return nil }
        return name
    }
}
