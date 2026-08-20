import SwiftUI

/// The one permanent visual marker distinguishing an investment account
/// from a regular one, now that both behave identically otherwise (every
/// account takes income/expense/transfer and can have cards mapped to it —
/// `kind` is purely presentational). Shown wherever an account's identity
/// is displayed, never conditional on anything but `kind == .investment`.
///
/// Deliberately quiet. It used to be an accent-tinted pill sitting inline
/// with the account name, where it competed with the name and the balance —
/// the three loudest things in the row were a label, a label, and a number.
/// It is metadata, so it now reads as metadata: secondary text weight, on
/// the row's own fill rather than a colour of its own, and placed under the
/// name rather than beside it (that placement is the caller's job).
struct InvestmentBadge: View {
    var body: some View {
        Text("Investment")
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
