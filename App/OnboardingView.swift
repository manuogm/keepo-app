import KeepoCore
import SwiftUI

/// Base currency → first account → opening balance, per
/// keepo-v1-feature-spec.md §Onboarding. The Wallet automation walkthrough
/// is deferred to Phase 8 (capture) — nothing to walk through yet.
struct OnboardingView: View {
    let session: SessionStore
    var onComplete: () -> Void

    private enum Step {
        case currency
        case firstAccount
    }

    @State private var step: Step = .currency
    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var selectedCurrency: String = "USD"
    @State private var accountName = ""
    @State private var accountSubtype: PublicSchema.AccountSubtype = .checking
    @State private var openingBalanceText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            VStack(spacing: 24) {
                switch step {
                case .currency:
                    currencyStep
                case .firstAccount:
                    firstAccountStep
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .task {
            currencies = (try? await CurrencyRepository.fetchAll(client: session.client)) ?? []
        }
    }

    private var currencyStep: some View {
        VStack(spacing: 16) {
            Text("Welcome to Keepo")
                .font(.title).fontWeight(.bold)
                .foregroundStyle(Color("TextPrimary"))
            Text("What's your base currency? Every balance converts into this.")
                .font(.callout)
                .foregroundStyle(Color("TextSecondary"))
                .multilineTextAlignment(.center)

            // Currency picker is restricted to `currencies` — the ECB set —
            // so an unpriceable account can never be created (spec: FX Rate History).
            Picker("Base currency", selection: $selectedCurrency) {
                ForEach(currencies, id: \.code) { currency in
                    Text(currency.code).tag(currency.code)
                }
            }
            .pickerStyle(.wheel)

            Button("Continue") { step = .firstAccount }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandPrimary"))
                .disabled(currencies.isEmpty)
        }
    }

    private var firstAccountStep: some View {
        VStack(spacing: 16) {
            Text("Add your first account")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color("TextPrimary"))

            TextField("Account name (e.g. Checking)", text: $accountName)
                .textFieldStyle(.roundedBorder)

            Picker("Type", selection: $accountSubtype) {
                Text("Checking").tag(PublicSchema.AccountSubtype.checking)
                Text("Cash").tag(PublicSchema.AccountSubtype.cash)
                Text("Credit Card").tag(PublicSchema.AccountSubtype.creditCard)
                Text("Loan").tag(PublicSchema.AccountSubtype.loan)
                Text("Investment").tag(PublicSchema.AccountSubtype.investment)
            }
            .pickerStyle(.segmented)

            TextField("Opening balance", text: $openingBalanceText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)

            Text("Required — without it, the first Sync Ritual would have nothing to reconcile against.")
                .font(.caption)
                .foregroundStyle(Color("TextSecondary"))
                .multilineTextAlignment(.center)

            Button {
                Task { await createFirstAccount() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Finish")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandPrimary"))
            .disabled(isFinishDisabled)
        }
    }

    private var isFinishDisabled: Bool {
        accountName.trimmingCharacters(in: .whitespaces).isEmpty || openingBalanceText.isEmpty || isLoading
    }

    private func createFirstAccount() async {
        guard let userId = session.profile?.id, let openingBalance = Decimal(string: openingBalanceText) else {
            errorMessage = "Enter a valid opening balance."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let kind: PublicSchema.AccountKind = accountSubtype == .investment ? .valuation : .ledger
            try await AccountRepository.create(
                client: session.client,
                ownerId: userId,
                kind: kind,
                subtype: accountSubtype,
                name: accountName,
                currency: selectedCurrency,
                openingBalance: openingBalance
            )
            try await session.completeOnboarding(baseCurrency: selectedCurrency)
            onComplete()
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }
}
