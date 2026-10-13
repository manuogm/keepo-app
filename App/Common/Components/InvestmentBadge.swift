import SwiftUI

/// The one permanent visual marker distinguishing an investment account
/// from a regular one, now that both behave identically otherwise (every
/// account takes income/expense/transfer and can have cards mapped to it —
/// `kind` is purely presentational). Shown wherever an account's identity
/// is displayed, never conditional on anything but `kind == .investment`.
///
/// Deliberately quiet: secondary text weight, on the row's own fill rather
/// than a colour of its own. Placement (under the name, or beside it) is the
/// caller's job.
///
/// `compact` shortens the label to "Inv." for the Accounts list, where the
/// row is tight on horizontal space beside the name, and in the account
/// form whenever the name would otherwise be cut (`AccountNameRow`); every
/// other caller keeps the spelled-out "Investment" the accessibility label
/// always uses.
struct InvestmentBadge: View {
    var compact: Bool = false
    /// Drawn in the brand colour when it is the thing that differs — the
    /// Sync Conflict sheet's way of pointing at a changed account type.
    var isHighlighted = false

    var body: some View {
        Text(compact ? "Inv." : "Investment")
            .font(isHighlighted ? AppTheme.Typography.nanoEmphasis : AppTheme.Typography.nano)
            .foregroundStyle(isHighlighted ? AppTheme.Palette.brandPrimary : AppTheme.Palette.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                isHighlighted ? AppTheme.Palette.brandPrimary.opacity(AppTheme.Opacity.fill)
                    : AppTheme.Palette.fillSubtle,
                in: Capsule()
            )
            .accessibilityLabel("Investment account")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
        Text("Brokerage")
        InvestmentBadge()
    }
    .padding()
}
