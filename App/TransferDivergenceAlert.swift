import Foundation
import KeepoCore
import Supabase
import SwiftUI

/// The pre-check itself, called from `TransactionFormView.saveTransfer`
/// before it queues the write — never inside `create_transfer` (that RPC's
/// signature/behavior stays untouched for every existing caller).
/// Best-effort: a network hiccup or missing market rate just means no
/// warning, never a blocked save (a UX warning, not a stored value, so
/// money rule 5's "—, not an error" spirit applies loosely here).
enum TransferDivergenceCheck {
    // swiftlint:disable:next function_parameter_count
    static func evaluate(
        client: SupabaseClient,
        sourceCurrency: String,
        destinationCurrency: String,
        fromAmountE4: Int64,
        toAmountE4: Int64,
        occurredAt: Date
    ) async -> RateDivergence? {
        let divergence = try? await TransactionRepository.checkTransferRateDivergence(
            client: client, fromCurrency: sourceCurrency, toCurrency: destinationCurrency,
            fromAmountE4: fromAmountE4, toAmountE4: toAmountE4, occurredAt: occurredAt
        )
        guard let divergence, divergence.diverges else { return nil }
        return divergence
    }
}

/// Extracted from `TransactionFormView` (Phase 18) to stay under the
/// project's file-length lint threshold — a `Binding` carries no access
/// restriction of its own, so this needs no access to any of that view's
/// private state beyond what it's handed.
struct TransferDivergenceAlertModifier: ViewModifier {
    @Binding var divergence: RateDivergence?
    let onConfirmAnyway: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Exchange rate looks off",
            isPresented: Binding(get: { divergence != nil }, set: { if !$0 { divergence = nil } })
        ) {
            Button("Cancel", role: .cancel) { divergence = nil }
            Button("Use Anyway") {
                divergence = nil
                onConfirmAnyway()
            }
        } message: {
            Text(message)
        }
    }

    private var message: String {
        guard let divergence else { return "" }
        let percent = Int(NSDecimalNumber(decimal: abs(divergence.pctDiff) * 100).doubleValue)
        return "This transfer implies a rate about \(percent)% off today's market rate — "
            + "check the amount before continuing."
    }
}

extension View {
    func transferDivergenceAlert(
        _ divergence: Binding<RateDivergence?>, onConfirmAnyway: @escaping () -> Void
    ) -> some View {
        modifier(TransferDivergenceAlertModifier(divergence: divergence, onConfirmAnyway: onConfirmAnyway))
    }
}
