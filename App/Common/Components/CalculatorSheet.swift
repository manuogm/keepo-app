import KeepoCore
import SwiftUI

/// The pop-up calculator behind every `AmountField`'s keypad button — for
/// the split bill, the three-of-those, the balance minus the bit that has
/// not cleared yet. It hands back a string, not a number: the field it
/// fills is a text field like any other, and the value takes the same
/// `AmountParser` route on save as one typed by hand.
///
/// Arithmetic lives in `CalculatorEngine` (KeepoCore, unit-tested) rather
/// than in this view. What is here is only the keypad and what a key press
/// does to the expression being built.
struct CalculatorSheet: View {
    let minorUnit: Int
    /// Seeds the calculator with whatever is already in the field, so
    /// "×3" on a number you just typed does not mean typing it twice.
    var initialText: String = ""
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Everything settled so far — `12 ×`. The number still being typed is
    /// `entry`, kept as text rather than a `Decimal` so a half-finished
    /// "12." survives until the user commits it.
    @State private var tokens: [CalculatorToken] = []
    @State private var entry = ""
    /// Set by `=`. The next digit starts a new number rather than extending
    /// the answer, which is what every calculator does and what fingers
    /// expect.
    @State private var isShowingResult = false
    /// A keystroke is not a state change — two `7`s in a row leave `entry`
    /// looking different but a `.sensoryFeedback` trigger has to *move*.
    /// A counter is the trigger, so every press fires exactly once.
    @State private var keyTick = 0

    private var separator: String { MoneyFormatter.decimalSeparator() }

    /// The expression as the engine sees it right now, including the number
    /// mid-entry — so the result line updates on every keystroke.
    private var pendingTokens: [CalculatorToken] {
        guard let value = AmountParser.parseRate(entry) else { return tokens }
        return tokens + [.number(value)]
    }

    private var result: Decimal? { CalculatorEngine.evaluate(pendingTokens) }

    private var expression: String {
        var parts = tokens.map { token -> String in
            switch token {
            case .number(let value): return AmountFormatter.editableString(decimal: value, minorUnit: minorUnit)
            case .operation(let operation): return operation.rawValue
            }
        }
        if !entry.isEmpty { parts.append(entry) }
        return parts.joined(separator: " ")
    }

    /// The big line: what you are typing, or the answer once there is one.
    private var displayText: String {
        if !entry.isEmpty { return entry }
        if let result { return AmountFormatter.editableString(decimal: result, minorUnit: minorUnit) }
        return "0"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.Spacing.l) {
                readout
                Spacer(minLength: 0)
                keypad
            }
            .sensoryFeedback(AppTheme.Feedback.typing, trigger: keyTick)
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.bottom, AppTheme.Spacing.l)
            .navigationTitle("Calculator")
            .navigationBarTitleDisplayMode(.inline)
            // The same pair the transaction and account forms carry, in the
            // same places — a keypad the user reached from one of those
            // forms should not close by a different gesture than the form
            // itself. The tick is disabled until there is a whole
            // expression to take, so an unfinished `12 ×` cannot be saved.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { use() } label: { Image(systemName: "checkmark") }
                        .disabled(result == nil)
                }
            }
        }
        // Sized to its contents rather than left at the default full
        // height: a keypad centred in a screen-tall sheet floats in a field
        // of nothing, and the form the amount is going into should stay
        // visible behind it. The detent clamps itself on a shorter phone.
        .presentationDetents([.height(500)])
        .presentationDragIndicator(.hidden)
        .onAppear {
            guard AmountParser.parseRate(initialText) != nil else { return }
            entry = initialText
        }
    }

    private var readout: some View {
        VStack(alignment: .trailing, spacing: AppTheme.Spacing.xs) {
            Text(expression.isEmpty ? " " : expression)
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Text(displayText)
                .numberFont(AppTheme.Typography.Number.balance, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, AppTheme.Spacing.s)
    }

    private var keypad: some View {
        Grid(horizontalSpacing: AppTheme.Spacing.s, verticalSpacing: AppTheme.Spacing.s) {
            GridRow {
                key(.clear); key(.backspace); key(.negate); key(.operation(.divide))
            }
            GridRow {
                key(.digit(7)); key(.digit(8)); key(.digit(9)); key(.operation(.multiply))
            }
            GridRow {
                key(.digit(4)); key(.digit(5)); key(.digit(6)); key(.operation(.subtract))
            }
            GridRow {
                key(.digit(1)); key(.digit(2)); key(.digit(3)); key(.operation(.add))
            }
            GridRow {
                key(.digit(0)).gridCellColumns(2); key(.decimal); key(.equals)
            }
        }
    }

    private func use() {
        guard let result else { return }
        onUse(AmountFormatter.editableString(decimal: result, minorUnit: minorUnit))
        dismiss()
    }

    private func key(_ key: CalculatorKey) -> some View {
        Button {
            press(key)
        } label: {
            key.label
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(key.tint)
                .frame(maxWidth: .infinity)
                .frame(height: AppTheme.Size.avatar)
                .background(
                    key.background,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
                )
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel(key.accessibilityLabel)
    }

    // MARK: - Key handling

    private func press(_ pressed: CalculatorKey) {
        keyTick += 1
        switch pressed {
        case .digit(let digit): appendDigit(digit)
        case .decimal: appendDecimal()
        case .operation(let operation): append(operation)
        case .clear: clearAll()
        case .backspace: deleteLast()
        case .negate: toggleSign()
        case .equals: evaluate()
        }
    }

    private func appendDigit(_ digit: Int) {
        startNewEntryIfNeeded()
        // A leading zero is a typo, not a number: "0" then "5" is 5.
        entry = entry == "0" ? String(digit) : entry + String(digit)
    }

    private func appendDecimal() {
        startNewEntryIfNeeded()
        guard !entry.contains(separator) else { return }
        entry = entry.isEmpty ? "0" + separator : entry + separator
    }

    private func clearAll() {
        tokens = []
        entry = ""
        isShowingResult = false
    }

    /// Backs out of the number being typed first, then out of the expression
    /// behind it — so one key undoes whatever the last key did.
    private func deleteLast() {
        isShowingResult = false
        if !entry.isEmpty {
            entry.removeLast()
        } else if !tokens.isEmpty {
            tokens.removeLast()
        }
    }

    private func toggleSign() {
        guard !entry.isEmpty else { return }
        entry = entry.hasPrefix("-") ? String(entry.dropFirst()) : "-" + entry
    }

    private func evaluate() {
        guard let result else { return }
        tokens = []
        entry = AmountFormatter.editableString(decimal: result, minorUnit: minorUnit)
        isShowingResult = true
    }

    /// An operator commits whatever is being typed. With nothing typed it
    /// either continues from the answer already on screen or, if the last
    /// thing pressed was itself an operator, replaces it — pressing `×`
    /// after `+` by mistake should correct the sum, not refuse the key.
    private func append(_ operation: CalculatorOperator) {
        isShowingResult = false
        if let value = AmountParser.parseRate(entry) {
            tokens.append(.number(value))
            entry = ""
            tokens.append(.operation(operation))
            return
        }
        guard let last = tokens.last else { return }
        if case .operation = last {
            tokens[tokens.count - 1] = .operation(operation)
        } else {
            tokens.append(.operation(operation))
        }
    }

    private func startNewEntryIfNeeded() {
        guard isShowingResult else { return }
        entry = ""
        isShowingResult = false
    }
}

/// Flattened out of `CalculatorSheet` rather than nested inside it — the
/// project's lint allows one level of nesting, and `CalculatorKey.digit`
/// inside a view would already be two.
private enum CalculatorKey: Hashable {
    case digit(Int)
    case decimal
    case operation(CalculatorOperator)
    case clear
    case backspace
    case negate
    case equals

    @ViewBuilder
    var label: some View {
        switch self {
        case .digit(let digit): Text(String(digit))
        case .decimal: Text(MoneyFormatter.decimalSeparator())
        case .operation(let operation): Text(operation.rawValue)
        case .clear: Text("C")
        case .backspace: Image(systemName: "delete.left")
        case .negate: Image(systemName: "plus.forwardslash.minus")
        case .equals: Text("=")
        }
    }

    /// Digits are the content; everything else is a control, so the two are
    /// separated by weight rather than by colour — the app's palette belongs
    /// to money, not to a keypad.
    var background: Color {
        switch self {
        case .digit, .decimal: return AppTheme.Palette.bgSurfaceRaised
        case .equals: return AppTheme.Palette.fillStrong
        default: return AppTheme.Palette.fillSubtle
        }
    }

    var tint: Color {
        switch self {
        case .digit, .decimal, .equals: return AppTheme.Palette.textPrimary
        default: return AppTheme.Palette.textSecondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .digit(let digit): return String(digit)
        case .decimal: return "Decimal point"
        case .operation(let operation): return operation.spokenName
        case .clear: return "Clear"
        case .backspace: return "Delete"
        case .negate: return "Change sign"
        case .equals: return "Equals"
        }
    }
}

private extension CalculatorOperator {
    var spokenName: String {
        switch self {
        case .add: return "Plus"
        case .subtract: return "Minus"
        case .multiply: return "Times"
        case .divide: return "Divided by"
        }
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        CalculatorSheet(minorUnit: 2, initialText: "12.50") { _ in }
    }
}
