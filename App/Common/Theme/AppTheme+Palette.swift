import SwiftUI

// MARK: - Palette

extension AppTheme {
    /// Every colour the app draws, as a name.
    ///
    /// **All of them are `Assets.xcassets` colour sets**, and that is the
    /// whole point: a colour set carries its own Any / Dark / High Contrast
    /// variants, so the app gets light mode, dark mode and Increase Contrast
    /// with no `colorScheme` branch anywhere in the view layer. The two
    /// places that *did* branch — `CashflowPalette` resolving a
    /// `UITraitCollection` by hand, and the raw `#FF5A5F` literals scattered
    /// through Needs Review and Scope — are gone.
    ///
    /// Values come from `keepo-brand-identity.md` §1. Tokens the brand doc
    /// does not name (`bgSurfaceRaised`, the fills, the statuses, the
    /// cashflow and scope pairs) were already decided in code; they are
    /// listed here so they are decided in *one* place.
    ///
    /// Referenced by string rather than by generated asset symbol so the
    /// name appears exactly once per token — a typo is a compile-clean blank
    /// colour, and this file is the only place it could happen.
    enum Palette {
        // MARK: Brand
        /// Mango — **the app's only accent**, and the whole of it. There is
        /// no `brandSecondary`; the coral it used to sit beside is gone.
        ///
        /// **It is not one value, and it cannot be.** Mango is a light hue:
        /// `#FF9F1C` measures 2.05:1 on white, which fails as text at any
        /// size, and 7.37:1 on `#262626`. So this token is deep amber in
        /// light mode and true mango in dark — the same accent at the two
        /// lightnesses its two grounds require. Nearly every use of it is
        /// *ink* at caption sizes (the Pending badge, the Needs Review
        /// inbox, the offline bar), which is the side that decides the light
        /// value. `scopeTotal` is the same hue on the fill side.
        static let brandPrimary = Color("BrandPrimary")

        // MARK: Surfaces
        /// The app canvas behind everything. Replaces
        /// `Color(.systemGroupedBackground)`.
        static let bgCanvas = Color("BGCanvas")
        /// Cards, list rows, floating blocks. Replaces
        /// `Color(.secondarySystemGroupedBackground)`.
        static let bgSurface = Color("BGSurface")
        /// A surface sitting on top of `bgSurface` — a well inside a card, a
        /// selected row. Replaces `Color(.tertiarySystemGroupedBackground)`.
        static let bgSurfaceRaised = Color("BGSurfaceRaised")

        // MARK: Text
        /// Balance figures, titles, row labels. Replaces `Color.primary`.
        static let textPrimary = Color("TextPrimary")
        /// Metadata, timestamps, captions. Replaces `Color.secondary`.
        static let textSecondary = Color("TextSecondary")
        /// A step lighter still than `textSecondary` — the disclosure
        /// chevron on My Profile's Base Currency card, matched to the system
        /// grey `List` itself draws for a `NavigationLink`'s chevron (which
        /// is `UIColor.tertiaryLabel`, not a token this app otherwise
        /// names). Baked as a flat colour rather than that system colour's
        /// own alpha, matching how every other token here is authored.
        static let textTertiary = Color("TextTertiary")
        /// Text and glyphs drawn on a saturated fill — a scope banner, a
        /// tinted circle. Replaces `Color.white` at every such call site.
        static let textOnAccent = Color("TextOnAccent")
        /// Text drawn on a fill that is itself `textPrimary` — a selected
        /// row inverted to stand out, whose background is therefore dark ink
        /// in light mode but a near-white in dark mode. `textOnAccent`
        /// (fixed white) only works for the light-mode half of that; this is
        /// the fixed dark ink the dark-mode half needs instead, since
        /// `textPrimary` itself already flips to supply the background.
        static let textOnLight = Color("TextOnLight")

        // MARK: Neutral fills
        /// A neutral wash behind a chip or an icon well. Replaces
        /// `Color.secondary.opacity(0.08...0.15)` and
        /// `Color(.quaternarySystemFill)`.
        static let fillSubtle = Color("FillSubtle")
        /// The selected or pressed state of that wash. Replaces
        /// `Color.secondary.opacity(0.18...0.28)` and `Color(.systemFill)`.
        static let fillStrong = Color("FillStrong")

        // MARK: Status
        /// A verdict that the news is good — a trend up, a toggle on, a
        /// finished sync. Replaces `Color.green`, which had too little
        /// contrast to be legible as text on either canvas.
        static let statusPositive = Color("StatusPositive")
        /// An error, a destructive action, a trend down. Replaces
        /// `Color.red`.
        static let statusNegative = Color("StatusNegative")

        // MARK: Money
        /// **Income is blue, not green.** Warm-vs-green is the canonical
        /// red-green colour-vision failure; warm-vs-blue clears it. Validated
        /// against CVD tooling, not picked by eye — see `app-architecture.md`
        /// §5 and `CashflowPalette`, which carries the measured figures.
        static let cashflowIncome = Color("CashflowIncome")
        /// Expense. A deep red rather than the brand coral it used to be —
        /// coral *was* `brandPrimary`, and that colour no longer exists. Kept
        /// warm rather than folded into `chartNeutral` so a cashflow chart
        /// still reads as two opposed quantities at a glance; deliberately a
        /// shade off `statusNegative`, which is a verdict, not a direction.
        static let cashflowExpense = Color("CashflowExpense")
        /// The default series colour, for anything that is neither a verdict
        /// nor a user-chosen identity. Near-black on the light card, near-
        /// white on the dark one.
        static let chartNeutral = Color("ChartNeutral")

        // MARK: Scope
        /// The three banner tints. Total is **mango** — the fill side of
        /// `brandPrimary` — with the cool and green counterparts that keep
        /// the three cards distinguishable at a glance to a colour-vision-
        /// deficient user (worst pair ΔE 53 under deuteranopia).
        ///
        /// All three carry `textOnAccent`, and **Total does not clear AA in
        /// its default appearances** — white on `#FF9F1C` is 2.05:1. That is
        /// a deliberate, user-made call to run the mango card on a real
        /// device and judge it there, not an oversight. The High Contrast
        /// variants are where it is made good: switch Increase Contrast on
        /// and Total drops to a deep amber that clears 4.5:1, exactly as
        /// Private and Household deepen to clear it. Dark mode takes every
        /// card one step deeper to cut glare.
        static let scopeTotal = Color("ScopeTotal")
        static let scopePrivate = Color("ScopePrivate")
        static let scopeHousehold = Color("ScopeHousehold")

        // MARK: Tags
        /// **Every tag is this one colour.** Categories are the colourful
        /// layer — the user picks an icon and a hue per category — so tags
        /// are deliberately uniform: a screen where both carried identity
        /// colour would have two competing colour systems and no way to tell
        /// at a glance which kind of thing a chip is.
        ///
        /// A mid-neutral off the palette's own ramp, carrying `textOnAccent`
        /// (white) in all four appearances. It does not follow the usual
        /// light-recedes/dark-lifts pattern: the chip is a *fill* with white
        /// ink on it, so every variant has to stay dark enough for white to
        /// clear 4.5:1 — 7.5:1 light, 5.3:1 dark, 11.6:1 and 7.5:1 in the two
        /// High Contrast appearances.
        static let tagTint = Color("TagTint")

        // MARK: Elevation
        /// The colour every shadow is drawn in — see `AppTheme.Elevation`.
        ///
        /// Not `.black`: the palette's floor is `#262626` and nothing in the
        /// app goes darker. In dark mode it inverts to a **grey lighter than
        /// the canvas**, because a shadow darker than a `#262626` ground has
        /// nowhere to go — there, elevation reads as a soft ambient lift
        /// around the surface instead of a void beneath it.
        static let shadowTint = Color("ShadowTint")
    }
}
