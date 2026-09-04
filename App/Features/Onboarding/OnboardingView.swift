import KeepoCore
import SwiftUI
import UserNotifications

/// Name → base currency → first account → opening balance → the
/// Wallet-automation walkthrough, per keepo-v1-feature-spec.md §Onboarding.
///
/// The name comes first because everything after it can use it. It is asked
/// rather than derived: the app knows the user's email address and could
/// split a name out of the local part, but "fam.samper.ona" is not what
/// anyone calls themselves, and a wrong name is worse than no name.
struct OnboardingView: View {
    let session: SessionStore
    var onComplete: () -> Void

    private enum Step {
        case name
        case currency
        case accountKind
        case firstAccount
        case captureWalkthrough
    }

    @State private var step: Step = .name
    @State private var displayName = ""
    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var selectedCurrency: String = "USD"
    @State private var accountName = ""
    @State private var accountKind: PublicSchema.AccountKind = .regular
    @State private var openingBalanceText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xl) {
                switch step {
                case .name:
                    nameStep
                case .currency:
                    currencyStep
                case .accountKind:
                    accountKindStep
                case .firstAccount:
                    firstAccountStep
                case .captureWalkthrough:
                    captureWalkthroughStep
                }

                if let errorMessage {
                    FormErrorText(message: errorMessage)
                }
            }
            .padding(AppTheme.Spacing.xl)
        }
        // Keyed on the refresh token, like every list screen in the app, and
        // for a reason this screen feels harder than they do: on a **fresh
        // install** the first sync pull has not landed when this view
        // appears, so a one-shot read finds no currencies and leaves the
        // picker empty with `Continue` disabled forever — onboarding
        // dead-ending on its own second step, recoverable only by relaunching.
        // `syncNow` bumps the token once the pull completes, which re-fires
        // this.
        .task(id: session.refresh.token) {
            currencies = (try? await session.dbQueue.read { database in
                try LocalTableQueries.currencies(database)
            }) ?? []
        }
    }

    /// The one screen in onboarding with nothing to explain: a single field,
    /// and the greeting it feeds appears on the very next step, so the user
    /// sees what it was for immediately rather than being told.
    ///
    /// 60 characters is `profiles_display_name_length`'s own ceiling, checked
    /// here so the constraint is a backstop rather than the error message.
    private var nameStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text("What should we call you?")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)

            TextField("Your name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .onSubmit { if !isNameInvalid { step = .currency } }

            Button("Continue") { step = .currency }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Palette.textPrimary)
                .disabled(isNameInvalid)
        }
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespaces)
    }

    private var isNameInvalid: Bool {
        trimmedName.isEmpty || trimmedName.count > 60
    }

    private var currencyStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text("Nice to meet you, \(trimmedName)")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("What's your base currency? Every balance converts into this.")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)

            // Currency picker is restricted to `currencies` — the ECB set —
            // so an unpriceable account can never be created (spec: FX Rate History).
            //
            // A spinner rather than an empty wheel while the list is still
            // arriving: an unexplained blank picker over a dead Continue
            // button reads as a broken app, which is exactly what it looked
            // like before the task above was keyed on the refresh token.
            if currencies.isEmpty {
                ProgressView()
                    .frame(maxHeight: .infinity)
            } else {
                Picker("Base currency", selection: $selectedCurrency) {
                    ForEach(currencies, id: \.code) { currency in
                        Text(currency.code).tag(currency.code)
                    }
                }
                .pickerStyle(.wheel)
            }

            Button("Continue") { step = .accountKind }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Palette.textPrimary)
                .disabled(currencies.isEmpty)
        }
    }

    private var accountKindStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text("Add your first account")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text("What kind of account is this?")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)

            AccountKindPicker { kind in
                accountKind = kind
                step = .firstAccount
            }
        }
    }

    private var firstAccountStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text(accountKind == .investment ? "Name your investment account" : "Name your account")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            TextField("Account name (e.g. Checking)", text: $accountName)
                .textFieldStyle(.roundedBorder)

            TextField("Opening balance", text: $openingBalanceText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)

            Text("Required — every balance is this figure plus everything you log after it.")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
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
            .tint(AppTheme.Palette.textPrimary)
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
            // Goes through the outbox, same as AccountFormView — the local
            // write-through means this account exists in the on-device
            // mirror by the time this call returns, even offline.
            let payload = CreateAccountPayload(
                id: UUID(), ownerId: userId, kind: accountKind,
                name: accountName, currency: selectedCurrency, openingBalanceE4: openingBalanceE4,
                icon: AccountAppearance.defaultIcon(forKind: accountKind), color: CategoryAppearance.randomColor()
            )
            await session.outbox.submitCreateAccount(payload)
            try await session.completeOnboarding(
                baseCurrency: selectedCurrency, displayName: trimmedName
            )
            step = .captureWalkthrough
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    private var captureWalkthroughStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text("Log Apple Pay purchases automatically")
                .font(AppTheme.Typography.sectionTitle).fontWeight(.bold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)

            Text("Optional — set it up now, or skip and find it later in Settings.")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
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
            .tint(AppTheme.Palette.textPrimary)
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
