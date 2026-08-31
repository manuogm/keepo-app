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

/// Sits beside the screen title: tap toggles financial data visibility.
/// Scope switching (Total/Personal/Household) lives in `ScopeSwitcherButton`
/// on the opposite corner — this button only ever does one thing.
struct PrivacyToggleButton: View {
    let session: SessionStore
    /// Defaults to the neutral treatment it has always had; the scope
    /// banner draws it on a saturated gradient card and passes white.
    var tint: Color = .secondary
    var font: Font = .caption

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
                Image(systemName: session.isPrivacyMode ? "eye.slash" : "eye")
                    .font(font)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }
    }
}
