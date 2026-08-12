import KeepoCore
import SwiftUI

// MARK: - Environment key

private struct PrivacyModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPrivacyMode: Bool {
        get { self[PrivacyModeKey.self] }
        set { self[PrivacyModeKey.self] = newValue }
    }
}

// MARK: - Button

/// Top-bar leading button: tap toggles financial data visibility; long-press
/// (context menu) selects the scope that all financial screens compute totals
/// for (Total / Personal / Household).
struct PrivacyToggleButton: View {
    let session: SessionStore

    /// Read fresh on every render rather than cached — the "Enable Hiding
    /// Balance" toggle in Security lives in a different screen, and this
    /// button needs to disappear the moment it's turned off, not just on
    /// next launch.
    @AppStorage(AppSettingsKeys.isHideBalanceEnabled) private var isHideBalanceEnabled = true

    var body: some View {
        if isHideBalanceEnabled {
            Button {
                session.isPrivacyMode.toggle()
            } label: {
                Image(systemName: session.isPrivacyMode ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(Color.primary)
            }
            .contextMenu {
                Section("Scope") {
                    scopeButton(.total, label: "Total Net Worth", icon: "globe")
                    scopeButton(.me, label: "Personal", icon: "person.fill")
                    scopeButton(.household, label: "Household", icon: "person.2.fill")
                }
            }
        }
    }

    private func scopeButton(
        _ scope: PublicSchema.AccountScope,
        label: String,
        icon: String
    ) -> some View {
        Button {
            session.scope = scope
        } label: {
            Label {
                Text(label)
            } icon: {
                Image(systemName: session.scope == scope ? "checkmark" : icon)
            }
        }
    }
}
