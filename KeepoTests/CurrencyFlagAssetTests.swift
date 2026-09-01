import Foundation
import KeepoCore
import Testing
import UIKit
@testable import Keepo

/// The flag artwork and its licence, checked against the built bundle.
///
/// `CurrencyRegionTests` in KeepoCore proves a currency resolves to a *name*;
/// only this target can prove the name resolves to an image. Without that
/// second half, forgetting to vendor a flag fails silently — `Image(_:)` given
/// a missing name draws nothing, so a badge would simply be blank on a screen
/// nobody re-checks.
@Suite("Currency flag assets")
struct CurrencyFlagAssetTests {
    /// The set seeded by `20260804184433_init_schema.sql`.
    ///
    /// Written out rather than read from anywhere, because there is nowhere
    /// to read it from: the client learns its currencies by sync and the
    /// local schema creates the `currencies` table without seeding it. This
    /// is the single copy — `CurrencyRegionTests` in KeepoCore deliberately
    /// keeps none, since a list checked without a bundle cannot catch the
    /// failure this suite exists for.
    static let supportedCurrencies = [
        "USD", "JPY", "BGN", "CZK", "DKK", "GBP", "HUF", "PLN", "RON", "SEK", "CHF", "ISK",
        "NOK", "TRY", "AUD", "BRL", "CAD", "CNY", "HKD", "IDR", "ILS", "INR", "KRW", "MXN",
        "MYR", "NZD", "PHP", "SGD", "THB", "ZAR", "EUR"
    ]

    /// Currencies not seeded today, whose artwork is bundled anyway.
    ///
    /// The bundle used to carry the **entire** ISO 3166-1 alpha-2 space —
    /// 265 imagesets, 2.1MB — so that a currency added by a future server
    /// migration (which reaches this client by sync, with no code change and
    /// no compile-time list to update) could never degrade to the grey globe
    /// on a build that had already shipped. That reasoning still holds; the
    /// scope was simply far wider than it needed to be. Roughly two thirds
    /// of those regions have no currency of their own at all — every
    /// eurozone member among them, since `EUR` resolves to `EU` and never to
    /// a member state's flag — so their artwork could never be reached by
    /// any currency code.
    ///
    /// What ships now is the currency-bearing set: today's 31 above, plus
    /// every remaining widely-traded or large-economy currency below. That
    /// keeps the "a new currency already has art" guarantee for anything
    /// plausibly added next, at 800KB instead of 2.1MB. A currency outside
    /// both lists still renders correctly — `CurrencyBadge` draws its globe,
    /// which is the same fallback an `X`-prefixed code has always taken.
    static let headroomCurrencies = [
        "RUB", "TWD", "SAR", "AED", "CLP", "COP", "PEN", "ARS", "VND", "EGP", "NGN", "KES",
        "PKR", "BDT", "LKR", "UAH", "MAD", "QAR", "KWD", "BHD", "OMR", "JOD", "KZT", "UZS",
        "GHS", "TZS", "ETB", "MMK", "NPR", "DZD", "TND", "IQD", "LBP", "AZN", "GEL", "RSD",
        "BAM", "MKD", "ALL", "MDL", "BYN", "DOP", "GTQ", "CRC", "UYU", "PYG", "BOB", "VES",
        "JMD", "TTD", "BND", "MOP", "MUR", "NAD", "BWP", "ZMW", "UGX", "MZN", "AOA", "LYD",
        "YER", "AFN", "IRR", "KGS", "MNT", "LAK", "KHR", "PGK", "FJD"
    ]

    /// Every currency the backend seeds today has artwork in the bundle.
    @Test("Every supported currency has a bundled flag")
    func supportedCurrenciesHaveArtwork() throws {
        for code in Self.supportedCurrencies {
            let name = try #require(
                CurrencyRegion.flagAssetName(for: code), "no flag name for \(code)"
            )
            #expect(UIImage(named: name) != nil, "\(code) resolves to \(name), which is not bundled")
        }
    }

    /// Currencies beyond today's 31 are bundled too — the headroom that
    /// stops a sync-delivered new currency degrading to the globe on an
    /// already-shipped build.
    @Test("Currencies beyond today's set are bundled too")
    func headroomCurrenciesHaveArtwork() throws {
        for code in Self.headroomCurrencies {
            let name = try #require(
                CurrencyRegion.flagAssetName(for: code), "no flag name for \(code)"
            )
            #expect(UIImage(named: name) != nil, "\(code) resolves to \(name), which is not bundled")
        }
    }

    /// The bundle carries currency-bearing regions only — not the whole
    /// alpha-2 space.
    ///
    /// Pinned so the trim can't silently creep back: a eurozone member has
    /// no currency code of its own (`EUR` resolves to `EU`), so its flag is
    /// unreachable from any code and must not be paying for itself in the
    /// download. `zz` is the never-a-region case `CurrencyBadge`'s existence
    /// check has always had to survive; these now take the identical path.
    @Test("Regions no currency can reach are not bundled")
    func nonCurrencyRegionsAreNotBundled() {
        for region in ["de", "fr", "it", "es", "nl", "pt", "ie", "zz"] {
            #expect(UIImage(named: "flag-\(region)") == nil, "flag-\(region) is bundled but unreachable")
        }
    }

    /// A currency with no honest flag must resolve to nothing, so the badge
    /// draws its globe rather than a hole.
    @Test("A code with no region has no artwork to find")
    func noRegionMeansNoAsset() {
        #expect(CurrencyRegion.flagAssetName(for: "XAU") == nil)
        #expect(FlagArtwork.assetName(for: "XAU") == nil)
    }

    /// The cache in front of `UIImage(named:)` answers exactly what an
    /// uncached probe would, both ways round, and stays stable across
    /// repeated reads — it is consulted from a view body, so a wrong second
    /// answer would show as a badge that changes its mind mid-scroll.
    @Test("The flag-artwork cache agrees with the bundle")
    func artworkCacheMatchesBundle() {
        for code in Self.supportedCurrencies + ["XAU", "QQQ", "DEM"] {
            let expected = CurrencyRegion.flagAssetName(for: code).flatMap {
                UIImage(named: $0) != nil ? $0 : nil
            }
            #expect(FlagArtwork.assetName(for: code) == expected, "\(code)")
            #expect(FlagArtwork.assetName(for: code) == expected, "\(code) on a second, cached read")
        }
    }

    /// MIT requires the notice to travel with "all copies or substantial
    /// portions of the Software", so it has to be *in the app*, not only in
    /// the repository. A folder reference keeps the path intact; copied as a
    /// flat resource it would land at the bundle root and collide with the
    /// next dependency's licence.
    @Test("The circle-flags licence ships inside the app bundle")
    func licenceIsBundled() throws {
        let url = try #require(
            Bundle.main.url(
                forResource: "LICENSE", withExtension: "md", subdirectory: "ThirdPartyLicenses/circle-flags"
            ),
            "circle-flags LICENSE.md is not in the app bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("MIT License"))
        #expect(text.contains("HatScripts"))
        #expect(text.contains("shall be included in all"))
    }
}
