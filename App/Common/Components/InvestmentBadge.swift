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
/// row is tight on horizontal space beside the name; every other caller
/// keeps the spelled-out "Investment" the accessibility label always uses.
struct InvestmentBadge: View {
    var compact: Bool = false

    var body: some View {
        Text(compact ? "Inv." : "Investment")
            .font(.caption2)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .accessibilityLabel("Investment account")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        Text("Brokerage")
        InvestmentBadge()
    }
    .padding()
}
