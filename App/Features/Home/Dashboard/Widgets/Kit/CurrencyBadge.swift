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
    /// A fixed width for the code, so the badge is the same size whichever
    /// currency it names.
    ///
    /// Only the FX widget's two pills pass it, and only because they are
    /// `Menu`/`Button` labels: UIKit snapshots those while the menu is open
    /// and morphs the snapshot back on dismissal, so a badge that changes
    /// width between one code and the next briefly draws distorted. Three
    /// letters differ by only a few points, which is still enough to see.
    /// See `TransactionsListView.pillLabel` for the traced explanation.
    ///
    /// `nil` everywhere else — a row in Currency Exposure has no snapshot to
    /// disagree with and should hug its own code.
    var codeWidth: CGFloat?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            disc
            if showsCode {
                Text(label ?? code ?? "—")
                    .font(.system(size: diameter * 0.55, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .lineLimit(1)
                    // A currency code is three letters and must never be
                    // one of them plus an ellipsis. Without this, sharing a
                    // row with a headline figure truncated "EUR" to "E…",
                    // which reads as a different currency rather than as a
                    // squeezed label.
                    .fixedSize()
                    .frame(width: codeWidth)
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
                Circle().fill(AppTheme.Palette.fillSubtle)
                Image(systemName: "globe")
                    .font(.system(size: diameter * 0.52, weight: .medium))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            .frame(width: diameter, height: diameter)
        }
    }

    /// The bundled flag for this currency, or `nil` to draw the globe.
    private var flagAsset: String? {
        code.flatMap(FlagArtwork.assetName(for:))
    }
}

/// Which currencies actually have flag artwork in this build, memoized.
///
/// The existence check is not defensive noise. `CurrencyRegion` derives a
/// name from the currency code's own letters, so it will happily name
/// `flag-zz` for a code whose first two letters are not a real region — and
/// `Image(_:)` given a name it cannot find draws **nothing at all**,
/// silently, leaving a hole where the badge should be. Asking the bundle
/// first turns that into the globe every other unknown currency gets. It
/// matters more now than it did: the bundle carries currency-bearing
/// regions only (see `CurrencyFlagAssetTests`), so the miss is a real,
/// reachable case rather than a theoretical one.
///
/// It has to be **cached**, though. `CurrencyBadge` read it from a computed
/// property inside `body`, so every render did an asset-catalogue lookup
/// purely as a boolean test and then loaded the same image again to draw it
/// — once per row, per render, in a list the expanded Currency Exposure
/// widget can fill. The answer cannot change within a process (the bundle is
/// read-only), so it is asked once per currency and remembered.
///
/// Same `NSLock` + `nonisolated(unsafe)` shape as `HexColorCache` and
/// `FormatterCache`, and for the same reason: the values are immutable once
/// built, so concurrent reads are safe.
enum FlagArtwork {
    private static let lock = NSLock()
    /// A `nil` *value* is a cached miss — distinct from an absent key, which
    /// means "not asked yet". Without that, every globe-drawing currency
    /// would re-probe the bundle on every render, which is most of what this
    /// exists to stop.
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func assetName(for currencyCode: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[currencyCode] { return cached }
        let resolved = CurrencyRegion.flagAssetName(for: currencyCode)
            .flatMap { UIImage(named: $0) != nil ? $0 : nil }
        cache[currencyCode] = resolved
        return resolved
    }
}
