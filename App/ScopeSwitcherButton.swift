import KeepoCore
import SwiftUI

/// Top-left toolbar icon: tap opens the scope menu (Total / Personal /
/// Household) that every financial screen computes its totals for. Scope
/// lives in `SessionStore` so it persists across tab switches. The icon
/// itself reflects the current scope, the same way `PrivacyToggleButton`'s
/// icon reflects its own state.
struct ScopeSwitcherButton: View {
    let session: SessionStore

    var body: some View {
        Menu {
            scopeButton(.total, label: "Total Net Worth", icon: "globe")
            scopeButton(.me, label: "Personal", icon: "person.fill")
            scopeButton(.household, label: "Household", icon: "person.2.fill")
        } label: {
            Image(systemName: scopeIconName)
                .foregroundStyle(Color.primary)
        }
    }

    private var scopeIconName: String {
        switch session.scope {
        case .total: return "globe"
        case .me: return "person.fill"
        case .household: return "person.2.fill"
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
