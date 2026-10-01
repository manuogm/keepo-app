import KeepoCore
import SwiftUI

// The controls around `AmountField`'s figure — the currency pill, the
// calculator and the expand chevron — and its header-less init, split out of
// AmountField.swift for the file-length lint. Same precedent as
// TransactionFormView's extensions.

extension AmountField {
    @ViewBuilder
    var accessories: some View {
        if let onPickCurrency, let currency {
            currencyChip(code: currency.code, action: onPickCurrency)
        }
        if isEnabled && showsCalculator {
            calculatorButton
        }
    }

    /// The currency the figure is in, and the way to change it. Deliberately
    /// the same quiet weight as the calculator button beside it: it answers
    /// a question most entries never ask, and the figure is what the screen
    /// is about.
    func currencyChip(code: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                // The same disc every other currency control in the app
                // draws, at chip size. A three-letter code is the thing you
                // read *after* recognising the flag, and the chip carried
                // only the code.
                CurrencyBadge(code: code, diameter: AppTheme.Size.glyphSmall, showsCode: false)
                Text(code)
                    .font(AppTheme.Typography.captionEmphasis)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppTheme.Typography.nano)
            }
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.s)
            .frame(height: AppTheme.Size.icon)
            .background(AppTheme.Palette.fillSubtle, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Currency: \(code). Change it")
    }

    /// Deliberately quiet — a thin outline in the icon's own grey, no larger
    /// than the fields it sits beside. It is a convenience for the times an
    /// amount needs working out, not a second thing competing with the figure
    /// for attention on a screen whose whole point is that figure.
    var calculatorButton: some View {
        Button {
            if let onCalculator { onCalculator() } else { isCalculatorPresented = true }
        } label: {
            KeepoIcon(name: "icon-calculator2", size: AppTheme.Size.glyphSmall)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .overlay(Circle().stroke(AppTheme.Palette.textSecondary, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Work the amount out on a calculator")
    }

    /// Shows the full figure, or shortens it again.
    func expandToggle(expands: Bool) -> some View {
        Button {
            withAnimation(AppTheme.Motion.standard) { isPeeking = expands }
        } label: {
            Image(systemName: expands ? "chevron.right" : "chevron.left")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pinned low: a stack's baseline is its highest child's, and the
        // chevron's would otherwise pull "$" up off the digits.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        .accessibilityLabel(expands ? "Show the full amount" : "Show the short amount")
    }
}

extension AmountField where Header == EmptyView {
    /// No row above: expanded, the pill and calculator get a row of their own.
    init(
        text: Binding<String>,
        currency: CurrencyInfo?,
        showsCurrencySymbol: Bool = true,
        isEnabled: Bool = true,
        onPickCurrency: (() -> Void)? = nil,
        showsCalculator: Bool = true,
        size: CGFloat = AppTheme.Typography.Number.balance
    ) {
        self.init(
            text: text, currency: currency, showsCurrencySymbol: showsCurrencySymbol, isEnabled: isEnabled,
            onPickCurrency: onPickCurrency, showsCalculator: showsCalculator, size: size
        ) { EmptyView() }
    }
}
