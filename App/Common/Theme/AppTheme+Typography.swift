import SwiftUI

// MARK: - Typography

extension AppTheme {
    /// The app's type ramp, named by the role a piece of text plays rather
    /// than by the SF style behind it — so the mapping below is a decision
    /// that can be revisited in one place, which is exactly what could not
    /// happen while 40 views each wrote `.font(.system(size: 15, weight:
    /// .semibold))` by hand.
    ///
    /// **Every token is a Dynamic Type text style.** That is not a stylistic
    /// preference: `keepo-brand-identity.md` §3 requires it, and a fixed
    /// point size is text that does not grow when a user turns the type size
    /// up. The 21 fixed sizes the app had (9, 10, 12, 14, 15, 16, 19, 20,
    /// 21, 22, 24, 26, 28, 34, 40, 48) are gone; the four that survive are
    /// figures too large for any text style, and they scale through
    /// `Number.display(_:weight:scale:)` instead.
    ///
    /// Two sizes only ever differed by a point or two, so they merged:
    /// `.callout` into `body`, `.title` into `sectionTitle`, and every
    /// `.medium` weight into its `.semibold` neighbour — a one-step weight
    /// difference nobody could name the reason for.
    enum Typography {
        /// The one big title on a screen that has one.
        ///
        /// `.title`, not `.largeTitle`. At 34pt almost every screen title in
        /// the app wrapped to two lines on a 6.1" phone — "Choose your
        /// starting categories", "Automatic payment detection", "Create your
        /// first account" — which cost a whole line of vertical space on
        /// screens that then had to compress everything under it. At 28pt
        /// most of them fit on one line and the ones that do not are
        /// genuinely long. It is still unambiguously the largest text on any
        /// screen that has one.
        static let screenTitle = Font.title.weight(.bold)
        /// A section heading inside a screen or sheet.
        static let sectionTitle = Font.title2.weight(.semibold)
        /// A card's or a widget's own title.
        static let cardTitle = Font.title3.weight(.semibold)
        /// The bold line at the top of a list row or an alert.
        static let rowTitle = Font.headline

        /// Running text.
        static let body = Font.body
        static let bodyEmphasis = Font.body.weight(.semibold)

        /// A row's primary label — the workhorse of every list in the app.
        static let label = Font.subheadline
        static let labelEmphasis = Font.subheadline.weight(.semibold)

        /// Supporting text under a label; error messages.
        static let caption = Font.footnote
        static let captionEmphasis = Font.footnote.weight(.semibold)

        /// Metadata, chips, axis labels.
        static let micro = Font.caption
        static let microEmphasis = Font.caption.weight(.semibold)

        /// The smallest text the app draws — a badge, a tab label, a page
        /// dot's letter. Nothing smaller exists, because nothing smaller is
        /// legible at the default type size.
        static let nano = Font.caption2
        static let nanoEmphasis = Font.caption2.weight(.bold)
    }
}

// MARK: - Numbers

extension AppTheme.Typography {
    /// Figures, everywhere they appear.
    ///
    /// Numbers get their own tokens for one reason the rest of the ramp
    /// doesn't need: **tabular digits**. `keepo-brand-identity.md` §2 asks
    /// for `.monospacedDigit()` on every currency figure so a balance
    /// updating from 1,111 to 8,888 doesn't jitter the layout around it.
    /// Getting that right per call site is exactly the kind of thing that
    /// gets forgotten on the forty-first screen.
    enum Number {
        /// A figure inline in a list row, beside its label.
        static let inline = AppTheme.Typography.label.monospacedDigit()
        /// A figure in supporting text — a converted amount, a rate note.
        static let caption = AppTheme.Typography.caption.monospacedDigit()
        /// A figure in metadata — a chart axis, a chip.
        static let micro = AppTheme.Typography.micro.monospacedDigit()

        /// Point sizes for figures larger than any text style goes. Four,
        /// down from the seven the app had (48, 44, 40, 34, 32, 28, 26).
        ///
        /// Always passed through `display(_:weight:scale:)` with a
        /// `@ScaledMetric` factor — never handed to `.system(size:)` raw.
        /// `hero` is the sign-in screen's mark; `balance` is a screen's one
        /// headline figure; `metric` and `metricCompact` are a dashboard
        /// widget's collapsed and expanded headline, which change together
        /// for every widget or not at all.
        static let hero: CGFloat = 48
        static let balance: CGFloat = 40
        static let metric: CGFloat = 32
        static let metricCompact: CGFloat = 28

        /// A display figure at `size`, multiplied by the caller's Dynamic
        /// Type scale factor.
        ///
        /// `scale` comes from an `@ScaledMetric(relativeTo: .largeTitle)
        /// private var typeScale: CGFloat = 1` on the view — SwiftUI's own
        /// scaling, so it re-renders when the user changes the type size,
        /// which `UIFontMetrics` read at body-evaluation time would not
        /// reliably do. Views that just need a font, rather than a `Text +
        /// Text` concatenation, should use `.numberFont(_:weight:)` below
        /// and never see `scale` at all.
        static func display(
            _ size: CGFloat, weight: Font.Weight = .bold, scale: CGFloat = 1
        ) -> Font {
            .system(size: size * scale, weight: weight).monospacedDigit()
        }
    }
}

// MARK: - Scaled display figures

/// Applies a display-size numeric font that grows with Dynamic Type.
///
/// The `@ScaledMetric` lives here rather than in each caller so a widget
/// headline, a keypad readout and a balance all scale by the same factor.
private struct NumberFontModifier: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1
    private let size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        self.size = size
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(AppTheme.Typography.Number.display(size, weight: weight, scale: scale))
    }
}

extension View {
    /// A figure at one of `AppTheme.Typography.Number`'s display sizes,
    /// scaled by Dynamic Type and drawn with tabular digits.
    func numberFont(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        modifier(NumberFontModifier(size: size, weight: weight))
    }
}
