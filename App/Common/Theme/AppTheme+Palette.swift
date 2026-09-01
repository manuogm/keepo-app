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
        /// Electric Coral. Primary actions, data lines, the keyword the eye
        /// should land on. Single value — no dark variant, per brand doc §1.
        static let brandPrimary = Color("BrandPrimary")
        /// Mango Fizz. Reminders, benchmarks, budget limits, the Needs
        /// Review inbox — things that should catch the eye *without* reading
        /// as an error.
        static let brandSecondary = Color("BrandSecondary")

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
        /// Text and glyphs drawn on a saturated fill — a scope banner, a
        /// tinted circle. Replaces `Color.white` at every such call site.
        static let textOnAccent = Color("TextOnAccent")

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
        /// **Income is blue, not green.** Coral-vs-green is the canonical
        /// red-green colour-vision failure (ΔE 7.6); coral-vs-blue clears it
        /// (ΔE 19.5). Validated against CVD tooling, not picked by eye — see
        /// `app-architecture.md` §5. Carried forward from `CashflowPalette`.
        static let cashflowIncome = Color("CashflowIncome")
        /// Expense. The brand coral, because money leaving is the thing this
        /// app is mostly about.
        static let cashflowExpense = Color("CashflowExpense")
        /// The default series colour, for anything that is neither a verdict
        /// nor a user-chosen identity. Near-black on the light card, near-
        /// white on the dark one.
        static let chartNeutral = Color("ChartNeutral")

        // MARK: Scope
        /// The three scope tints, already pulled back from full saturation —
        /// a whole screen of `brandPrimary` shouted at everything on it, and
        /// the softening is now baked into the asset rather than recomputed
        /// on every render. Cool and green counterparts to Total so the three
        /// cards stay distinguishable to a colour-vision-deficient user.
        static let scopeTotal = Color("ScopeTotal")
        static let scopePrivate = Color("ScopePrivate")
        static let scopeHousehold = Color("ScopeHousehold")
    }
}
