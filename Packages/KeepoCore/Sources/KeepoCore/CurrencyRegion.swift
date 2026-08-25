import Foundation

/// A currency's flag, as the name of a bundled image asset.
///
/// The artwork is HatScripts' `circle-flags` — circular SVGs vendored into
/// `App/Resources/Flags.xcassets`, one imageset per ISO 3166-1 alpha-2
/// region. See `App/Resources/ThirdPartyLicenses/circle-flags/` for the
/// licence and provenance.
///
/// This returns a *name*, not an image: `KeepoCore` is a pure-logic package
/// with no bundle to load from, and the mapping from a currency to its region
/// is exactly the part worth testing without one. `CurrencyBadge` does the
/// loading, and falls back to a globe when the name resolves to nothing —
/// which is also what a caller must do for a currency this returns `nil` for.
///
/// **The two-letter rule is not a shortcut.** ISO 4217 builds a currency
/// code from its country's ISO 3166-1 alpha-2 code plus a letter for the
/// currency's own name, so `USD`→`US`, `SEK`→`SE`, `CHF`→`CH`. It holds for
/// every currency in v1's supported (ECB/Frankfurter) set, checked one by
/// one. Where it doesn't hold the answer is `nil`, never a wrong flag:
/// `X`-prefixed codes are supranational or not currencies at all (`XAU` is
/// gold), and a made-up flag on a money figure is worse than no flag.
public enum CurrencyRegion {
    /// Currencies whose region is not simply the code's first two letters.
    /// `EUR` is the one that matters today — the euro belongs to the union,
    /// not to a country, and `EU` is a real alpha-2 code with its own flag.
    private static let overrides: [String: String] = [
        "EUR": "EU"
    ]

    /// The prefix every flag imageset carries, so a two-letter region can
    /// never collide with one of the app's own asset names.
    private static let assetPrefix = "flag-"

    /// The ISO 3166-1 alpha-2 region a currency belongs to, or `nil` when
    /// it doesn't belong to one.
    public static func region(for currencyCode: String) -> String? {
        let code = currencyCode.uppercased()
        if let override = overrides[code] { return override }
        guard code.count == 3, !code.hasPrefix("X") else { return nil }
        let region = String(code.prefix(2))
        guard region.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return region
    }

    /// The asset catalogue name of a currency's flag — `"flag-us"` — or
    /// `nil` when there is no honest flag to show and the caller should draw
    /// a globe instead.
    ///
    /// A non-`nil` name is not a promise that the asset exists: the whole
    /// alpha-2 space is bundled, but a currency code whose first two letters
    /// are not a real region would still produce a name here. The caller
    /// checks, and falls back to the same globe.
    public static func flagAssetName(for currencyCode: String) -> String? {
        guard let region = region(for: currencyCode) else { return nil }
        return assetPrefix + region.lowercased()
    }
}
