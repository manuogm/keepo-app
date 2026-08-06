import KeepoCore
import Supabase
import SwiftUI

/// Phase 17: base-currency change (triggers Phase 13's FX backfill
/// automatically, server-side — nothing extra to call from here), the
/// biometric step-up mechanism, and email-OTP as a linked recovery
/// identity. Reached from Settings, not folded into the main list — this
/// screen is entirely about the account's security/identity posture, a
/// distinct concern from Household/Recurring/Budgets.
struct SecuritySettingsView: View {
    let session: SessionStore

    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var selectedCurrency = ""
    @State private var recoveryEmail = ""
    @State private var isSavingCurrency = false
    @State private var isSendingRecoveryEmail = false
    @State private var isTestingStepUp = false
    @State private var stepUpResultMessage: String?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Form {
            if isLoading {
                ProgressView()
            } else {
                Section {
                    Picker("Base currency", selection: $selectedCurrency) {
                        ForEach(currencies, id: \.code) { currency in
                            Text(currency.code).tag(currency.code)
                        }
                    }
                    Button {
                        Task { await saveBaseCurrency() }
                    } label: {
                        if isSavingCurrency {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSavingCurrency || selectedCurrency == session.profile?.baseCurrency)
                } header: {
                    Text("Base Currency")
                } footer: {
                    Text(
                        "Every balance and chart converts into this currency. Changing it refreshes exchange "
                            + "rate history for the new currency automatically."
                    )
                }

                Section {
                    if session.authCapabilities.requiresBiometricStepUp {
                        Button {
                            Task { await testStepUp() }
                        } label: {
                            if isTestingStepUp {
                                ProgressView()
                            } else {
                                Text("Test Step-Up Authentication")
                            }
                        }
                        .disabled(isTestingStepUp)
                    } else {
                        Text("Biometric step-up isn't available with this account type.")
                            .foregroundStyle(Color("TextSecondary"))
                    }
                    if let stepUpResultMessage {
                        Text(stepUpResultMessage).font(.footnote).foregroundStyle(Color("TextSecondary"))
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text(
                        "Export, account deletion, and household actions require a fresh biometric check, "
                            + "never a cached one."
                    )
                }

                Section {
                    TextField("Recovery email", text: $recoveryEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    Button {
                        Task { await sendRecoveryEmail() }
                    } label: {
                        if isSendingRecoveryEmail {
                            ProgressView()
                        } else {
                            Text("Add Recovery Email")
                        }
                    }
                    .disabled(isSendingRecoveryEmail || recoveryEmail.isEmpty)
                } header: {
                    Text("Recovery Identity")
                } footer: {
                    Text(
                        "A linked recovery contact — not a login method. Without one, losing your sign-in "
                            + "identity means losing access to your financial history."
                    )
                }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Security")
        .task { await load() }
    }

    private func load() async {
        currencies = (try? await CurrencyRepository.fetchAll(client: session.client)) ?? []
        selectedCurrency = session.profile?.baseCurrency ?? currencies.first?.code ?? "USD"
        isLoading = false
    }

    private func saveBaseCurrency() async {
        guard let userId = session.profile?.id else { return }
        isSavingCurrency = true
        errorMessage = nil
        do {
            try await ProfileRepository.updateBaseCurrency(
                client: session.client, userId: userId, baseCurrency: selectedCurrency
            )
            try await session.refreshProfile()
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSavingCurrency = false
    }

    private func testStepUp() async {
        isTestingStepUp = true
        stepUpResultMessage = nil
        errorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm it's you")
            stepUpResultMessage = "Step-up succeeded."
        } catch {
            stepUpResultMessage = "Step-up declined: \(UserFacingError.describe(error))"
        }
        isTestingStepUp = false
    }

    /// `enable_manual_linking = false` locally (config.toml) means this is
    /// a plain email change/verify flow, not true multi-identity linking —
    /// flip that flag to get real linking later; nothing else here changes.
    private func sendRecoveryEmail() async {
        isSendingRecoveryEmail = true
        errorMessage = nil
        do {
            _ = try await session.client.auth.update(user: UserAttributes(email: recoveryEmail))
            recoveryEmail = ""
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSendingRecoveryEmail = false
    }
}
