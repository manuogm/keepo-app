import KeepoCore
import SwiftUI

/// Step 2 — the one answer setup cannot finish without.
///
/// `onboarded_requires_base_currency` is a CHECK, not a preference:
/// `onboarded_at` cannot be written without a `base_currency`.
///
/// **So there is no Skip here** (`SetupStep.isSkippable`). The wheel is
/// already sitting on an answer derived from the device's own locale, and
/// a Skip that accepted it would have run the identical code path as Next
/// — the same act, offered twice. Next *is* the skip: the user who does
/// not care taps it without touching the wheel.
///
/// The wheel is `CurrencyWheel`, the same body My Profile's base-currency
/// sheet renders. A currency picked here and the same currency changed
/// later must not be two different-looking controls.
struct SetupCurrencyStep: View {
    let store: OnboardingDraftStore
    let currencies: [PublicSchema.CurrenciesSelect]

    @State private var code = ""

    var body: some View {
        OnboardingScaffold(
            title: "Choose your base currency",
            // Two lines, deliberately. One sentence with a dash in it read
            // as a single dense line at the top of a screen whose only job
            // is one choice; as two it is a fact and a reassurance.
            subtitle: "Every balance converts to it\nChangeable any time",
            step: .currency,
            onBack: store.goBack,
            isPrimaryEnabled: !code.isEmpty,
            onPrimary: commitAndAdvance
        ) {
            // A spinner rather than an empty wheel over a dead button: on a
            // fresh install the currencies arrive with the first sync pull,
            // and a blank picker with no explanation is indistinguishable
            // from a broken app.
            if currencies.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: AppTheme.Size.illustration * 2)
            } else {
                CurrencyWheel(currencies: currencies, selection: $code, label: "Base currency")
            }
        }
        // Keyed on the list, not run once: the wheel has nothing to sit on
        // until the currencies land, so the default has to be chosen at the
        // moment they do.
        .task(id: currencies.count) {
            guard code.isEmpty, !currencies.isEmpty else { return }
            code = store.draft.baseCurrency
                ?? BaseCurrencyDefault.suggestion(supported: currencies.map(\.code))
        }
    }

    private func commitAndAdvance() {
        guard !code.isEmpty else { return }
        store.update { $0.baseCurrency = code }
        store.advance()
    }
}
