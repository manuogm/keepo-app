import SwiftUI

/// Every layout constant the app is allowed to use, in one namespace.
///
/// Before this existed the app had 21 distinct padding values, 17 distinct
/// stack spacings and 5 corner radii — 7pt beside 8pt beside 10pt, 20pt
/// screen insets on some sheets and 16pt on others. None of that was a
/// decision; it was the residue of writing each screen on its own day. The
/// scale below is the decision, and it is deliberately short: a value that
/// isn't on it is a value nobody should be reaching for.
///
/// Colours live in `AppTheme.Palette` (asset catalogue), type in
/// `AppTheme.Typography`. Nothing here names a colour or a font — the one
/// member that carries one, `Elevation`, takes it from `Palette`.
enum AppTheme {}

// MARK: - Spacing

extension AppTheme {
    /// Gaps and insets, on a 4pt grid.
    ///
    /// One half-step (`xxs`) survives the grid on purpose: the leading
    /// between a row's title and its subtitle is genuinely 2pt work, and
    /// rounding it to 4 loosens every list row in the app. Everything else
    /// is a multiple of 4.
    ///
    /// The consolidations that changed real numbers:
    /// - **5, 6 → `xs` (4)** — inline gaps and chip insets that had drifted apart.
    /// - **7, 10 → `s` (8)** — control padding; 7pt and 10pt were the same intent.
    /// - **11, 14 → `m` (12)** — row vertical padding.
    /// - **18, 20 → `l` (16)** — the app had *two* screen-edge insets. 16 wins
    ///   because it is the one `WidgetStyle.padding` and the dashboard grid
    ///   already draw from, so a sheet's edge now lines up with a widget's.
    /// - **22, 26 → `xl` (24)** — section separation.
    /// - **28, 40 → `xxl` (32)** — the largest gap any layout needs.
    enum Spacing {
        /// 2 — the one sub-grid half-step: leading inside a single label stack.
        static let xxs: CGFloat = 2
        /// 4 — between an icon and its label, inside a chip.
        static let xs: CGFloat = 4
        /// 8 — between related controls, a control's own inset.
        static let s: CGFloat = 8
        /// 12 — between rows, a row's vertical inset, the dashboard gutter.
        static let m: CGFloat = 12
        /// 16 — **the screen edge**, and a card's inner inset.
        static let l: CGFloat = 16
        /// 24 — between sections.
        static let xl: CGFloat = 24
        /// 32 — between a screen's major blocks; empty-state breathing room.
        static let xxl: CGFloat = 32
    }
}

// MARK: - Radius

extension AppTheme {
    /// Three corners, because the app only ever meant three things.
    ///
    /// It had five (12, 14, 16, 20, 22) and no rule for choosing between
    /// them — 14 and 16 appeared on the same kind of card in different
    /// files. `keepo-brand-identity.md` §4 names two (20 for cards and
    /// sheets, 12 for toggles and chips); `card` is the third, for a surface
    /// nested *inside* another one, which the brand doc predates.
    enum Radius {
        /// 12 — chips, segmented controls, small buttons, keypad keys.
        static let control: CGFloat = 12
        /// 16 — a surface nested inside another surface: a row inside a card.
        static let card: CGFloat = 16
        /// 20 — top-level surfaces: dashboard widgets, sheets, the Needs
        /// Review drawer, a credit-card face. Brand doc §4's value; the
        /// dashboard's 22 and the drawer's 24 both fold into it.
        static let surface: CGFloat = 20
    }
}

// MARK: - Size

extension AppTheme {
    /// Square dimensions for round or boxed glyphs — avatars, category
    /// icons, currency badges, the circle behind a status symbol.
    ///
    /// Was 20, 22, 24, 26, 28, 30, 32, 34, 40, 44, 48, 52, 56, 64 across the
    /// app, most of them a default argument on some view nobody compared
    /// against its neighbour.
    enum Size {
        /// 8 — a status dot or a page indicator.
        static let dot: CGFloat = 8
        /// 12 — an icon packed next to caption2-sized text: the scope title
        /// badge, a transaction row's provenance markers. Matched to the
        /// letterforms, not the line — anything larger crowds them.
        static let glyphNano: CGFloat = 12
        /// 16 — an icon sitting inline with a line of caption-sized text: a
        /// provenance marker on a transaction row, the leading glyph in a
        /// search field. `glyph` would tower over the words beside it.
        static let glyphSmall: CGFloat = 16
        /// 24 — a badge, a compact leading icon on a widget's row, or a
        /// standalone tappable control glyph (the privacy toggle, the filter
        /// and search buttons, the calculator affordance).
        static let glyph: CGFloat = 24
        /// 32 — the standard leading icon on a list row, and the tab bar.
        static let icon: CGFloat = 32
        /// 44 — HIG's minimum touch target. Applied as hit area, not layout —
        /// see `View.hitTarget(_:)`.
        static let touchTarget: CGFloat = 44
        /// 56 — an avatar, or the circle behind a status symbol.
        static let avatar: CGFloat = 56
        /// 80 — the mark an empty state is built around.
        static let illustration: CGFloat = 80
        /// 140 — an avatar that is the subject of the screen rather than a
        /// marker on it: onboarding's profile step, where it and one text
        /// field are the only things present and `illustration` left the
        /// screen looking mostly empty.
        static let avatarHero: CGFloat = 140
        /// 280 — how wide a bubble of wrapping prose may be: an info
        /// popover. The one member here that is not a square, and it earns
        /// its place for the same reason as the rest — the alternative is
        /// the number being retyped, differently, at every screen that
        /// explains itself.
        static let proseWidth: CGFloat = 280

        /// The leading inset that lines a `Divider` up with the text beside
        /// a row's leading icon, rather than with the icon itself.
        ///
        /// Derived, never typed: the app had 16, 32, 40 and 56 hand-written
        /// for this, and at least one of them no longer matched the row it
        /// was drawn under — a divider that starts four points off the label
        /// above it is the kind of thing nobody can name but everybody sees.
        ///
        /// `leading` is 0 for a row inside a card that is already inset —
        /// a dashboard widget's list — and the screen edge otherwise.
        static func dividerInset(
            icon: CGFloat, gap: CGFloat = Spacing.m, leading: CGFloat = Spacing.l
        ) -> CGFloat {
            leading + icon + gap
        }
    }
}

// MARK: - Opacity

extension AppTheme {
    /// Fixed alphas, for the cases a `Palette` colour cannot cover — a tint
    /// the app doesn't own (a user's category colour, a scope's) softened
    /// into a background.
    ///
    /// Prefer `Palette.fillSubtle`/`fillStrong` when the thing being
    /// softened is the app's own neutral: those are asset colours and get a
    /// high-contrast variant, which an `.opacity()` never can.
    enum Opacity {
        /// 0.08 — a hairline wash; the faintest a fill may be.
        static let hairline: Double = 0.08
        /// 0.15 — a tinted chip or icon-well behind its own accent.
        static let fill: Double = 0.15
        /// 0.25 — the pressed or selected version of that chip.
        static let fillStrong: Double = 0.25
        /// 0.35 — a mark pushed into the background of a chart.
        static let dim: Double = 0.35
        /// 0.5 — disabled, or half-there.
        static let muted: Double = 0.5
        /// 0.6 — a coach mark's scrim. The only value on this scale that
        /// exists to make the app behind it *unreadable* rather than
        /// quieter, which is why it sits past `muted` and why nothing but
        /// `SpotlightOverlay` uses it: a modal curtain in Keepo is
        /// `.ultraThinMaterial` over `fill` (see `MappedCardSheet`), which
        /// deliberately keeps its background legible as context. A spotlight
        /// wants the opposite.
        static let scrim: Double = 0.6
    }
}

// MARK: - Elevation

extension AppTheme {
    /// A shadow, as one value rather than four arguments.
    ///
    /// Six shadows existed with six opacities (0.10, 0.13, 0.15, 0.18, 0.22,
    /// 0.30) and six radii, and the difference between any two of them was
    /// not a design decision anyone had made.
    struct Elevation {
        var color: Color
        var radius: CGFloat
        var y: CGFloat

        /// A surface resting on the canvas: the scope banner, the Needs
        /// Review drawer, the offline bar.
        static let resting = Elevation(color: tint.opacity(0.12), radius: 10, y: 4)
        /// A surface floating over content: the tab bar, a sheet's grabber
        /// deck, a card face.
        static let floating = Elevation(color: tint.opacity(0.18), radius: 20, y: 8)
        /// A tile the finger is currently holding.
        static let lifted = Elevation(color: tint.opacity(0.28), radius: 28, y: 10)

        /// The one colour all three are drawn in — `Palette.shadowTint`, so
        /// the appearance switch happens in the asset and not here.
        ///
        /// It used to be `.black`, which the palette no longer contains and
        /// which was in any case appearance-blind: on a `#262626` dark canvas
        /// a black shadow is invisible, so every surface in dark mode was
        /// floating on nothing. The asset inverts to a grey *lighter* than
        /// the canvas there — the only direction left once `#262626` is the
        /// floor — and elevation reads as ambient lift rather than a void.
        private static let tint = Palette.shadowTint
    }
}

extension View {
    /// The only way a shadow should be applied.
    func elevation(_ elevation: AppTheme.Elevation, isActive: Bool = true) -> some View {
        shadow(
            color: isActive ? elevation.color : .clear,
            radius: elevation.radius,
            y: elevation.y
        )
    }
}
