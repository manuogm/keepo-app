import KeepoCore
import SwiftUI

/// The one place a base-currency secondary amount renders, per
/// app-architecture.md §2 ("used by Home, Insights, Sync Ritual banners —
/// renders `—` when has_missing_rate"). Accounts and Transactions are the
/// first two screens to need it.
///
/// Renders nothing when the row's own currency already equals the base
/// currency — a redundant "$100 / $100" line isn't useful. Renders "—" via
/// the existing MoneyFormatter nil-path when `hasMissingRate`, never a
/// blank space (a missing rate and "nothing to show" must look different).
struct CurrencyConversionLabel: View {
    let nativeCurrency: String?
    let amountBase: Decimal?
    let baseCurrency: String?
    let baseMinorUnit: Int16?
    let hasMissingRate: Bool

    var body: some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(Color("TextSecondary"))
        }
    }

    private var text: String? {
        guard let baseCurrency, let baseMinorUnit, baseCurrency != nativeCurrency else { return nil }
        let currency = CurrencyInfo(code: baseCurrency, minorUnit: Int(baseMinorUnit))
        return MoneyFormatter.format(hasMissingRate ? nil : amountBase, currency: currency)
    }
}
