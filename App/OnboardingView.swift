import KeepoCore
import SwiftUI
import UserNotifications

/// Base currency → first account → opening balance → the Wallet-automation
/// walkthrough, per keepo-v1-feature-spec.md §Onboarding.
struct OnboardingView: View {
    let session: SessionStore
    var onComplete: () -> Void

    private enum Step {
        case currency
        case firstAccount
        case captureWalkthrough
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
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                switch step {
                case .currency:
                    currencyStep
                case .firstAccount:
                    firstAccountStep
                case .captureWalkthrough:
                    captureWalkthroughStep
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
            currencies = (try? await session.dbQueue.read { database in
                try LocalTableQueries.currencies(database)
            }) ?? []
        }
    }

    private var currencyStep: some View {
        VStack(spacing: 16) {
            Text("Welcome to Keepo")
                .font(.title).fontWeight(.bold)
                .foregroundStyle(Color.primary)
            Text("What's your base currency? Every balance converts into this.")
                .font(.callout)
                .foregroundStyle(Color.secondary)
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
                .tint(Color.primary)
                .disabled(currencies.isEmpty)
        }
    }

    private var firstAccountStep: some View {
        VStack(spacing: 16) {
            Text("Add your first account")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color.primary)

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
                .foregroundStyle(Color.secondary)
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
            .tint(Color.primary)
            .disabled(isFinishDisabled)
        }
    }

    private var isFinishDisabled: Bool {
        accountName.trimmingCharacters(in: .whitespaces).isEmpty || openingBalanceText.isEmpty || isLoading
    }

    private func createFirstAccount() async {
        guard let userId = session.profile?.id, let openingBalanceE4 = AmountParser.parse(openingBalanceText) else {
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
                openingBalanceE4: openingBalanceE4,
                icon: AccountAppearance.defaultIcon(forSubtype: accountSubtype),
                color: CategoryAppearance.randomColor()
            )
            try await session.completeOnboarding(baseCurrency: selectedCurrency)
            step = .captureWalkthrough
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    private var captureWalkthroughStep: some View {
        VStack(spacing: 16) {
            Text("Log Apple Pay purchases automatically")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)

            Text("Optional — set it up now, or skip and find it later in Settings.")
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)

            NavigationStack {
                WalletAutomationGuideView()
            }
            .frame(maxHeight: 320)

            Button("Done") {
                Task {
                    await requestNotificationAuthorizationIfNeeded()
                    onComplete()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.primary)
        }
    }

    /// The one point in the app that both explains Wallet automation *and*
    /// runs unconditionally for every new sign-in (C-06) — unlike
    /// `NotificationSettingsView`'s deliberate per-level ask, this is a
    /// single one-time request so a fresh install's default `.full`
    /// preference is backed by an iOS permission that was actually
    /// requested, not just assumed. A user who already answered this
    /// system dialog (any status other than `.notDetermined`) gets no
    /// second prompt — `requestAuthorization` would just silently replay
    /// the existing answer.
    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
}
