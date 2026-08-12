import KeepoCore
import Supabase
import SwiftUI

/// Biometric step-up and recovery identity settings. Base currency lives in
/// Preferences now (an inline picker there, no push) — this screen is
/// purely about the account's security posture.
struct SecuritySettingsView: View {
    let session: SessionStore

    @AppStorage(AppSettingsKeys.isFaceIDEnabled) private var isFaceIDEnabled = true
    @AppStorage(AppSettingsKeys.isHideBalanceEnabled) private var isHideBalanceEnabled = true
    @State private var recoveryEmail = ""
    @State private var isSendingRecoveryEmail = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if session.authCapabilities.requiresBiometricStepUp {
                    Toggle("Enable Face ID", isOn: $isFaceIDEnabled)
                } else {
                    Text("Biometric step-up isn't available with this account type.")
                        .foregroundStyle(Color.secondary)
                }
            } header: {
                Text("Security")
            } footer: {
                Text(
                    "When enabled, export, account deletion, and household actions require a fresh "
                        + "biometric check. When disabled, Face ID is never requested."
                )
            }

            Section {
                Toggle("Enable Hiding Balance", isOn: $isHideBalanceEnabled)
            } footer: {
                Text(
                    "Adds a button to Home, Accounts, and Transactions to hide financial figures "
                        + "when using the app in public. Turning this off also un-hides anything "
                        + "currently hidden."
                )
            }
            .onChange(of: isHideBalanceEnabled) { _, enabled in
                // The button that would normally let the user reveal it
                // again is the very thing being turned off here — force it
                // back on so nothing stays stuck hidden with no affordance
                // to undo it.
                if !enabled { session.isPrivacyMode = false }
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
        .navigationTitle("Security")
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
