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
        /// Teal — **the app's accent**, from the app icon's family and the
        /// same hue `scopeTotal` fills with.
        ///
        /// **It is not one value, and it cannot be.** Nearly every use of
        /// it is *ink* at caption sizes (the Needs Review inbox, the offline
        /// bar, a checked box), and the teal that reads on a light ground
        /// (`#127268`, 5.3:1 on the canvas) is 2.6:1 on `#262626`. So dark
        /// mode lifts it to `#3CC4B3` (7.0:1) — the same accent at the two
        /// lightnesses its two grounds require. `scopeTotal` is the same
        /// hue on the fill side.
        ///
        /// The one thing it does not mark is *Pending* — see
        /// `statusPending`.
        static let brandPrimary = Color("BrandPrimary")

        /// The app icon's own teal, one value in every appearance — the
        /// launch screen's ground (`UILaunchScreen` in `Info.plist`) and
        /// `RootLoadingView`'s, so the launch reads as the icon opening out
        /// to fill the screen. Sign-in's header and its Continue button
        /// carry it too: the first screen a new user sees after the splash. Sampled from the icon rather than borrowed
        /// from `brandPrimary`, which is a different, lighter teal tuned
        /// for text: a splash a shade off the icon the user just tapped
        /// reads as a mismatch. Used only on the splash and sign-in.
        static let launchBackground = Color("LaunchBackground")

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

        /// Text and glyphs drawn on a fill that is `textPrimary` itself —
        /// an inverted selected row, the currency wheel's chosen pill, the
        /// range calendar's endpoint discs.
        ///
        /// It has to be a function of the colour scheme rather than one
        /// more asset, because the fill underneath is *already* adaptive:
        /// dark ink in light mode, near-white in dark. One fixed colour can
        /// only ever be right for one half of that. Three screens derived
        /// this same pair privately before it moved here — which is the
        /// signal CLAUDE.md names for extracting a shared helper.
        static func inkOnPrimaryFill(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? textOnLight : textOnAccent
        }

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
        /// Waiting on the user, not wrong — an automatic capture nobody has
        /// reviewed yet (`PendingBadge`, `PendingEdgeStrip`). **Mango**, the
        /// accent before the palette went teal, kept for this one job: a
        /// teal Pending sits too close to `statusPositive` and reads as
        /// "fine", where a warm one reads as "look at me". Deep amber in
        /// light mode, true mango in dark — mango is 2.05:1 on white, so it
        /// needs the same two-lightness treatment `brandPrimary` gets.
        static let statusPending = Color("StatusPending")
        /// Something is missing but nothing is wrong — a rate that has not
        /// arrived. The system's own yellow, which already adapts to dark
        /// mode and High Contrast; only ever a wash or a glyph, never text,
        /// which it is too light to carry on the light canvas.
        static let statusWarning = Color(uiColor: .systemYellow)

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
        /// The three banner tints. Total is **teal** — the fill side of
        /// `brandPrimary` — Household indigo, Private a dark grey. The grey
        /// is achromatic, so the three stay distinguishable at a glance to
        /// a colour-vision-deficient user; the closest pair is Total and
        /// Private, ΔE 22 under deuteranopia (Total–Household 54), and the
        /// badge glyph and word tell those two apart as well.
        ///
        /// All three carry `textOnAccent`, and all three clear AA against
        /// it in every appearance — light / dark / HC / dark HC: Total
        /// 4.8 / 5.8 / 6.0 / 6.0, Household 5.6 / 6.3 / 7.1 / 7.1, Private
        /// 11.2 / 7.8 / 13.2 / 9.3. Private lifts to `#525252` in dark mode
        /// rather than deepening like the other two: a grey as dark as the
        /// light one would sink into the `#262626` canvas.
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
