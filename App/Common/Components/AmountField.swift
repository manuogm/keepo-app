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
/// one field — SwiftUI has no attributed-text field. Overlaying a styled
/// `Text` on a transparent `TextField` was tried and rejected: the two lay
/// out at different widths (that is the whole point of the smaller
/// fraction), so the real caret drifts away from the drawn digits as soon
/// as the user taps to move it mid-string.
///
/// Instead the `TextField` always defines the layout at the full size, and
/// the styled `Text` is drawn over it only while unfocused. Focusing swaps
/// to a plain uniform field — no reflow, since the field was the layout
/// driver all along — and the split styling returns on blur. The user sees
/// the designed treatment whenever they are reading, and an ordinary,
/// completely predictable text field whenever they are typing.
struct AmountField: View {
    @Binding var text: String
    /// Drives the placeholder's decimal places and the split point. `nil`
    /// while an account is still being chosen — the field stays usable, it
    /// just cannot know how many decimals to suggest yet.
    var currency: CurrencyInfo?
    /// Drawn ahead of the number, at the same size as the whole part — the
    /// symbol is part of the figure, not a label attached to it.
    var showsCurrencySymbol = true
    var isEnabled = true
    /// Point size of the whole part. The fraction and the symbol derive from
    /// it, so a caller only ever picks one number.
    var size: CGFloat = 40

    @FocusState private var isFocused: Bool

    private var minorUnit: Int { currency?.minorUnit ?? 2 }

    /// The minus belongs in FRONT of the symbol — "-$840.00", not "$-840.00",
    /// which is what you get if the sign is left inside the number while the
    /// symbol is drawn separately. Only balances are ever negative here (a
    /// transaction's sign lives in its kind), but that is exactly the field
    /// where getting it wrong is most noticeable.
    private var isNegative: Bool { text.hasPrefix("-") }

    private var symbol: String? {
        guard showsCurrencySymbol, let currency else { return isNegative ? "-" : nil }
        return (isNegative ? "-" : "") + MoneyFormatter.symbol(for: currency)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Text(symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.5) : Color.primary)
            }

            ZStack(alignment: .leading) {
                TextField("", text: $text)
                    .font(.system(size: size, weight: .semibold))
                    .monospacedDigit()
                    .keyboardType(.decimalPad)
                    .focused($isFocused)
                    .disabled(!isEnabled)
                    // Still hit-testable at zero opacity, which is what makes
                    // tapping the styled overlay focus the real field.
                    .opacity(isFocused ? 1 : 0)

                if !isFocused {
                    display.allowsHitTesting(false)
                }
            }
        }
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .animation(nil, value: isFocused)
    }

    @ViewBuilder
    private var display: some View {
        if text.isEmpty {
            Text(placeholder)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.secondary.opacity(0.5))
        } else {
            splitText
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// Splits at the locale's own separator via the same helper
    /// `MoneyFormatter.formatSplit` uses, so a typed "12,34" on a
    /// comma-decimal locale splits exactly where a formatted balance would.
    private var splitText: Text {
        let split = MoneyFormatter.split(
            displayText, separator: MoneyFormatter.decimalSeparator(), minorUnit: minorUnit
        )
        return Text(split.whole).font(.system(size: size, weight: .semibold))
            + Text(split.fraction).font(.system(size: fractionSize, weight: .semibold))
    }
}

#Preview {
    @Previewable @State var empty = ""
    @Previewable @State var filled = "1250.75"
    return VStack(alignment: .leading, spacing: 24) {
        AmountField(text: $empty, currency: CurrencyInfo(code: "USD", minorUnit: 2))
        AmountField(text: $filled, currency: CurrencyInfo(code: "USD", minorUnit: 2))
        AmountField(text: $filled, currency: CurrencyInfo(code: "JPY", minorUnit: 0), isEnabled: false)
    }
    .padding()
}
