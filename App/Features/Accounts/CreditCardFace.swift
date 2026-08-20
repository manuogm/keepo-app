import KeepoCore
import SwiftUI

/// A card face built from the account's own colour. Every card mapped to an
/// account is visibly a card *of that account* — same hue family — while
/// still being distinguishable from its siblings at a glance, which is the
/// whole reason the strip shows more than one.
///
/// The variation is derived from a stable hash of the card's identifier, not
/// from its index: a card must not change colour because another card was
/// added before it or removed from in front of it.
struct CreditCardFace {
    let base: Color
    private let seed: Int

    init(accountColor: Color, cardIdentifier: String) {
        self.base = accountColor
        // `StableSeed` is the shared FNV-1a this used to inline — see its own
        // header for why `hashValue` can't be used here. Byte-identical to
        // what shipped, so no existing card changes shade.
        self.seed = StableSeed.index(cardIdentifier, upperBound: 997)
    }

    /// Four bands of shade, walked by the seed. Kept deliberately narrow —
    /// wide enough that two cards never read as the same, narrow enough that
    /// none of them stops looking like the account's colour.
    private var variation: HSBComponents {
        switch seed % 4 {
        case 0: return HSBComponents(hue: 0.000, saturation: 0.02, brightness: 0.00)
        case 1: return HSBComponents(hue: 0.035, saturation: -0.10, brightness: 0.08)
        case 2: return HSBComponents(hue: -0.030, saturation: 0.08, brightness: -0.10)
        default: return HSBComponents(hue: 0.015, saturation: -0.04, brightness: -0.05)
        }
    }

    private var topColor: Color {
        base.shifted(
            hue: variation.hue, saturation: variation.saturation, brightness: variation.brightness + 0.06
        )
    }

    private var bottomColor: Color {
        base.shifted(
            hue: variation.hue - 0.02, saturation: variation.saturation + 0.06,
            brightness: variation.brightness - 0.16
        )
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [topColor, bottomColor], startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// The "subtle texture" — a soft diagonal sheen plus a corner highlight,
    /// which is what makes a flat rounded rectangle read as a physical card
    /// rather than a coloured box. Both are white at very low opacity so they
    /// work over any hue without being tinted themselves.
    @ViewBuilder
    var sheen: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0.0),
                    .init(color: .white.opacity(0.16), location: 0.42),
                    .init(color: .white.opacity(0), location: 0.62)
                ],
                startPoint: seed.isMultiple(of: 2) ? .topLeading : .bottomLeading,
                endPoint: seed.isMultiple(of: 2) ? .bottomTrailing : .topTrailing
            )
            RadialGradient(
                colors: [.white.opacity(0.20), .clear],
                center: seed.isMultiple(of: 3) ? .topTrailing : .topLeading,
                startRadius: 2,
                endRadius: 150
            )
        }
        .allowsHitTesting(false)
    }

    /// Text and glyphs sit on a saturated field, so they are always the light
    /// end of the scale rather than `Color.primary` — which would vanish
    /// against a bright card in light mode and against a dark one in dark
    /// mode. Deliberately not pure white: slightly translucent reads as ink
    /// on the card rather than a sticker over it.
    var foreground: Color { .white }
    var secondaryForeground: Color { .white.opacity(0.75) }
}
