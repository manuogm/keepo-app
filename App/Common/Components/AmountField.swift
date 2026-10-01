import KeepoCore
import SwiftUI

/// The one large money input in the app — an account's balance and a
/// transaction's amount are the same control, per CLAUDE.md's reuse rule.
/// Both are the single most important field on their screen, so both get
/// the same treatment: oversized whole part, smaller fraction, and a grey
/// placeholder that shows the shape of the expected input rather than
/// labelling it.
///
/// **On the split rendering.** `TextField` cannot render two font sizes in
/// one field — SwiftUI has no attributed-text field. So the field always
/// defines the layout at the full size, and the styled `Text` is drawn over
/// it *only while unfocused*: focusing swaps to a plain uniform field — no
/// reflow, since the field was the layout driver all along — and the split
/// styling returns on blur. The user sees the designed treatment whenever
/// they are reading, and an ordinary, completely predictable text field
/// whenever they are typing.
///
/// The overlay and the caret must never coexist. The two lay out at
/// different widths (that is the whole point of the smaller fraction), so a
/// caret drawn under the styled text drifts away from the digits the user
/// is aiming at. Swapping on focus is what keeps that from happening.
///
/// **At rest it reads like every other amount in the app**: exact below a
/// thousand, short from a thousand up ("56.8K", `MoneyFormatter.format`'s
/// rule) with a chevron beside it that shows the exact figure. Shown, the
/// exact figure keeps its line beside the currency pill and calculator if
/// it fits there; if not, those move up into `header`, the caller's row
/// above (the account picker, the account's name), which gives up width to
/// make room — and if even the whole line is too short, the figure shrinks,
/// symbol and all, never cut with "…". Editing ends the peek. While typing,
/// the field is always the exact digits, by the same fitting rules.
///
/// No figure passes `AmountIssue.maximumWholeDigits`: the keystroke that
/// would cross it is refused, with the rejection haptic.
struct AmountField<Header: View>: View {
    @Binding var text: String
    /// Drives the placeholder's decimal places and the split point. `nil`
    /// while an account is still being chosen — the field stays usable, it
    /// just cannot know how many decimals to suggest yet.
    var currency: CurrencyInfo?
    /// Drawn ahead of the number, at the same size as the whole part — the
    /// symbol is part of the figure, not a label attached to it.
    var showsCurrencySymbol = true
    var isEnabled = true
    /// When set, a chip carrying `currency`'s code sits beside the figure
    /// and opens a picker. Absent everywhere the currency is not the user's
    /// to choose — an existing account's balance is in that account's
    /// currency and nothing else — which is why this is opt-in rather than
    /// a flag to turn off. A NEW account sets it, which is what keeps its
    /// pill identical to the transaction form's.
    var onPickCurrency: (() -> Void)?
    /// Off on onboarding's first-account step. The calculator is a
    /// convenience for an amount that needs working out, and an opening
    /// balance is a number the user reads off their bank — a second control
    /// beside the figure there is one more thing to explain on the one
    /// screen that cannot be skipped.
    var showsCalculator = true
    /// Set when the keypad button belongs to a calculator the caller owns —
    /// the transaction card's one calculator for its two figures. `nil`
    /// opens this field's own.
    var onCalculator: (() -> Void)?
    /// Point size of the whole part, from `AppTheme.Typography.Number`. The
    /// fraction and the symbol derive from it, so a caller only ever picks
    /// one number.
    var size: CGFloat = AppTheme.Typography.Number.balance
    /// The row above the figure, which the pill and calculator join while the full figure is shown.
    var headerSpacing: CGFloat
    let header: Header

    /// Same reason as `BalanceHeaderView`'s: the figure is the largest text
    /// on the form, so it is the text that most needs to grow with the
    /// user's type size.
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1
    @FocusState private var isFocused: Bool
    // Not `private` — written from AmountField+Controls.swift.
    @State var isCalculatorPresented = false
    /// The user asked to see the full figure (the chevron). Only while not
    /// typing — see `isExpanded`.
    @State var isPeeking = false
    /// The figure's own width, the width it has, and the width it had last
    /// time the pill and calculator sat beside it — what decides whether a
    /// figure being typed has outgrown its space. See `isExpanded`.
    @State private var figureWidth: CGFloat = 0
    @State private var fieldWidth: CGFloat = 0
    @State private var collapsedFieldWidth: CGFloat = 0
    /// Bumped by every keystroke refused for crossing the digit ceiling.
    @State private var refusedEdits = 0

    init(
        text: Binding<String>,
        currency: CurrencyInfo?,
        showsCurrencySymbol: Bool = true,
        isEnabled: Bool = true,
        onPickCurrency: (() -> Void)? = nil,
        showsCalculator: Bool = true,
        onCalculator: (() -> Void)? = nil,
        size: CGFloat = AppTheme.Typography.Number.balance,
        headerSpacing: CGFloat = AppTheme.Spacing.s,
        @ViewBuilder header: () -> Header
    ) {
        _text = text
        self.currency = currency
        self.showsCurrencySymbol = showsCurrencySymbol
        self.isEnabled = isEnabled
        self.onPickCurrency = onPickCurrency
        self.showsCalculator = showsCalculator
        self.onCalculator = onCalculator
        self.size = size
        self.headerSpacing = headerSpacing
        self.header = header()
    }

    private var minorUnit: Int { currency?.minorUnit ?? 2 }

    private func figureFont(_ points: CGFloat) -> Font {
        AppTheme.Typography.Number.display(points, weight: .semibold, scale: typeScale)
    }

    /// The minus belongs in FRONT of the symbol — "-$840.00", not "$-840.00",
    /// which is what you get if the sign is left inside the number while the
    /// symbol is drawn separately. Only balances are ever negative here (a
    /// transaction's sign lives in its kind), but that is exactly the field
    /// where getting it wrong is most noticeable.
    private var isNegative: Bool { text.hasPrefix("-") }

    /// **At rest only.** While the field is focused, the minus is a
    /// character in the text the user is editing, sitting in front of the
    /// digits where they typed it — so moving it in front of the symbol as
    /// well drew it twice: "-$-840". It moves out of the text and ahead of
    /// the symbol when the styled overlay takes over on blur.
    private var symbol: String? {
        let sign = isNegative && !isFocused ? "-" : ""
        guard showsCurrencySymbol, let currency else { return sign.isEmpty ? nil : sign }
        return sign + MoneyFormatter.symbol(for: currency)
    }

    /// What the styled overlay draws. The `TextField` underneath keeps the
    /// raw text, sign and all — this only affects the at-rest rendering.
    private var displayText: String {
        isNegative ? String(text.dropFirst()) : text
    }

    private var fractionSize: CGFloat { size * 0.6 }

    /// "0.00" for a 2-decimal currency, "0" for JPY — the placeholder is
    /// itself a hint about the currency's precision, so it is derived, never
    /// a hardcoded string.
    private var placeholder: String {
        AmountFormatter.editableString(0, minorUnit: minorUnit)
    }

    /// "56.8K" — the short form every list shows for this figure — or `nil`
    /// below a thousand, and for text that is not a number.
    private var compactFigure: String? {
        guard let amount = AmountParser.parse(displayText, minorUnit: minorUnit),
              MoneyFormatter.isShort(amount, minorUnit: minorUnit) else { return nil }
        return MoneyFormatter.compactFigure(amount)
    }

    /// The figure has a line of its own, because the exact digits do not
    /// fit beside the pill and calculator — so those move up, and the whole
    /// value stays in view. While typing that is decided keystroke by
    /// keystroke; at rest only once the chevron has asked for the exact
    /// figure, which then also shares its line with the collapse chevron.
    var isExpanded: Bool {
        guard collapsedFieldWidth > 0 else { return false }
        if isFocused { return figureWidth > collapsedFieldWidth }
        return isPeeking && figureWidth + AppTheme.Size.icon + AppTheme.Spacing.xs > collapsedFieldWidth
    }

    /// How far the whole figure — symbol, digits and fraction together —
    /// shrinks to fit a line even the expanded layout cannot give it. One
    /// scale for all of it (the digits alone left a full-size "$" towering
    /// over them), and no floor: the expanded figure exists to be read
    /// whole, so it keeps shrinking rather than being cut with "…".
    ///
    /// Only the glyphs scale: the gap after the symbol and the collapse
    /// chevron come off the room first. The 2% margin is San Francisco
    /// spacing its glyphs looser at smaller sizes, plus the caret.
    private var figureScale: CGFloat {
        guard isExpanded, figureWidth > 0 else { return 1 }
        let gap = symbol == nil ? 0 : AppTheme.Spacing.xs
        let fixed = gap + (isFocused ? 0 : AppTheme.Size.icon + AppTheme.Spacing.xs)
        return min(1, (fieldWidth - fixed) / (figureWidth - gap) * 0.98)
    }

    /// Shown and edited with the locale's grouping ("1,234,567.89"), stored
    /// without it — every parse, save and conversion reads the same plain
    /// digits it always has. See `AmountFormatter.grouping`.
    private var groupedText: Binding<String> {
        Binding(
            get: { AmountFormatter.grouping(text) },
            set: { text = AmountFormatter.ungrouping($0) }
        )
    }

    private var hasHeaderRow: Bool { Header.self != EmptyView.self || isExpanded }

    var body: some View {
        // The header keeps its place in both layouts, so its identity (a
        // text field's focus, a menu) survives the figure expanding.
        VStack(alignment: .leading, spacing: headerSpacing) {
            if hasHeaderRow {
                HStack(spacing: AppTheme.Spacing.s) {
                    header
                    if isExpanded {
                        Spacer(minLength: 0)
                        accessories
                    }
                }
            }
            // Two levels: the symbol and the figure share a baseline, because
            // "$" belongs to the number. The keypad button is not part of the
            // figure, so it centres on the row instead — hung off a baseline
            // it sat level with the digits' feet.
            HStack(spacing: AppTheme.Spacing.s) {
                figure
                if !isExpanded {
                    accessories
                }
            }
            .foregroundStyle(isEnabled ? AppTheme.Palette.textPrimary : AppTheme.Palette.textSecondary)
        }
        .animation(nil, value: isFocused)
        .onChange(of: text) { old, new in
            // `!exceeds(old)`: a value already over the line is not bounced.
            guard AmountIssue.exceedsMaximum(new), !AmountIssue.exceedsMaximum(old) else { return }
            text = old
            refusedEdits += 1
        }
        .sensoryFeedback(AppTheme.Feedback.rejection, trigger: refusedEdits)
        // Typing is free-form, committing is not: a figure with more
        // decimals than the currency has ("12.345" dollars) is rounded the
        // moment the field lets go, so what the user reads back is the
        // figure `AmountParser.parse(_:minorUnit:)` will store. Skipped
        // until the currency is known — rounding to a guessed precision
        // would take digits away from a figure that may have needed them.
        .onChange(of: isFocused) { _, focused in
            guard !focused else { return }
            // Editing ends the peek: the figure just changed, so whether it
            // still needs a line of its own is a new question.
            isPeeking = false
            guard let currency,
                  let rounded = AmountFormatter.rounded(text, minorUnit: currency.minorUnit) else { return }
            text = rounded
        }
        .sheet(isPresented: $isCalculatorPresented) {
            CalculatorSheet(minorUnit: minorUnit, initialText: text) { amount in
                text = amount
            }
        }
    }

    private var figure: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
            if let symbol {
                Text(symbol)
                    .font(figureFont(size * figureScale))
                    .foregroundStyle(text.isEmpty ? AppTheme.Palette.fillStrong : AppTheme.Palette.textPrimary)
            }

            ZStack(alignment: .leading) {
                TextField("", text: groupedText)
                    .font(figureFont(size * figureScale))
                    .monospacedDigit()
                    .keyboardType(.decimalPad)
                    .focused($isFocused)
                    .disabled(!isEnabled)
                    // Hidden by TEXT COLOUR, never by opacity. This carried
                    // `.opacity(isFocused ? 1 : 0)` and the comment "still
                    // hit-testable at zero opacity" — which is exactly what
                    // UIKit does not do: `hitTest` skips any view whose
                    // alpha is at or below 0.01. The field was therefore
                    // untappable in its resting state, so the amount showed
                    // its "$0.00" placeholder and no tap could ever focus
                    // it. At full opacity with clear text the field is a
                    // real touch target again, and tapping mid-string still
                    // lands the caret where the finger went.
                    .foregroundStyle(isFocused ? AppTheme.Palette.textPrimary : Color.clear)

                // Hit testing is off per text, not on the whole overlay: a tap
                // on the figure has to reach the field underneath, and a tap
                // on the expand chevron must not.
                if !isFocused {
                    display
                }
            }
        }
        // The symbol and digits together, measured two ways: the width the
        // row gives them, and — off-screen, at full size — the width they
        // want. Both are independent of `figureScale`, so shrinking the
        // figure can never feed back into how far it shrinks.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            fieldWidth = width
            if !isExpanded { collapsedFieldWidth = width }
        }
        .background(alignment: .leading) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                if let symbol { Text(symbol).font(figureFont(size)) }
                // The uniform typing text, or the split rendering at rest.
                if isFocused {
                    Text(AmountFormatter.grouping(text)).font(figureFont(size))
                } else {
                    splitText()
                }
            }
            .monospacedDigit()
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // Animated only when this keystroke moves the pill and
                // calculator — the field rising to take the line, or
                // settling back beside them.
                let flips = (width > collapsedFieldWidth) != (figureWidth > collapsedFieldWidth)
                if isFocused && flips {
                    withAnimation(AppTheme.Motion.standard) { figureWidth = width }
                } else {
                    figureWidth = width
                }
            }
        }
    }

    @ViewBuilder
    private var display: some View {
        if text.isEmpty {
            Text(placeholder)
                .font(figureFont(size))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Palette.fillStrong)
                .allowsHitTesting(false)
        } else if let compactFigure, !isPeeking {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(compactFigure)
                    .font(figureFont(size))
                    .monospacedDigit()
                    .lineLimit(1)
                    .allowsHitTesting(false)
                expandToggle(expands: true)
            }
        } else {
            // The exact figure: beside the pill and calculator when it fits,
            // on a whole line when it does not, and — the longest figure,
            // twelve digits and a fraction — shrunk by `figureScale` when
            // even that is short, so the symbol shrinks with it.
            HStack(spacing: AppTheme.Spacing.xs) {
                splitText(scale: figureScale)
                    .monospacedDigit()
                    .lineLimit(1)
                    // Backstop for `figureScale`'s estimate: a point of size, never a digit.
                    .minimumScaleFactor(0.5)
                    .allowsHitTesting(false)
                if isPeeking {
                    expandToggle(expands: false)
                }
            }
        }
    }

    /// Splits at the locale's own separator via the same helper
    /// `MoneyFormatter.formatSplit` uses, so a typed "12,34" on a
    /// comma-decimal locale splits exactly where a formatted balance would.
    private func splitText(scale: CGFloat = 1) -> Text {
        let split = MoneyFormatter.split(
            AmountFormatter.grouping(displayText), separator: MoneyFormatter.decimalSeparator(), minorUnit: minorUnit
        )
        return Text(split.whole).font(figureFont(size * scale))
            + Text(split.fraction).font(figureFont(fractionSize * scale))
    }
}

#Preview {
    @Previewable @State var empty = ""
    @Previewable @State var filled = "1250.75"
    return VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
        AmountField(text: $empty, currency: CurrencyInfo(code: "USD", minorUnit: 2))
        AmountField(text: $filled, currency: CurrencyInfo(code: "USD", minorUnit: 2))
        AmountField(text: $filled, currency: CurrencyInfo(code: "JPY", minorUnit: 0), isEnabled: false)
    }
    .padding()
}
