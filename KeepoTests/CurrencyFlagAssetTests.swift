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

    /// The whole ISO 3166-1 alpha-2 space is vendored, not just today's 31.
    ///
    /// That is what stops a currency added by a future migration — which
    /// reaches this client by sync, with no code change and no compile-time
    /// list to update — from degrading to the grey globe on a build that has
    /// already shipped. A representative sample of regions no current
    /// currency uses.
    @Test("Regions beyond today's currencies are bundled too")
    func alpha2SpaceIsCovered() {
        for region in ["ke", "ng", "vn", "pk", "ar", "cl", "eg", "sa", "ua", "rs"] {
            #expect(UIImage(named: "flag-\(region)") != nil, "flag-\(region) is not bundled")
        }
    }

    /// A currency with no honest flag must resolve to nothing, so the badge
    /// draws its globe rather than a hole.
    @Test("A code with no region has no artwork to find")
    func noRegionMeansNoAsset() {
        #expect(CurrencyRegion.flagAssetName(for: "XAU") == nil)
        #expect(UIImage(named: "flag-zz") == nil)
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
