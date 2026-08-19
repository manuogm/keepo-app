import SwiftUI

/// The one permanent visual marker distinguishing an investment account
/// from a regular one, now that both behave identically otherwise (every
/// account takes income/expense/transfer and can have cards mapped to it —
/// `kind` is purely presentational). Shown wherever an account's identity
/// is displayed, never conditional on anything but `kind == .investment`.
struct InvestmentBadge: View {
    var body: some View {
        Text("Investment")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}
