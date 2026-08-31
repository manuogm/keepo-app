import KeepoCore
import SwiftUI

/// What a main screen shows instead of its content when the current scope
/// has nothing behind it (`ScopeContext.emptiness(for:)`).
///
/// One view for all four cases and all three screens. The alternative —
/// each screen deciding for itself — is how "you have no accounts" ends up
/// phrased three ways and offering a button on two screens out of three.
/// The account-creation sheet is presented from **here** rather than by the
/// caller for the same reason: the screens that most need this state
/// (Dashboard, Transactions) have no account sheet of their own to borrow.
struct ScopeEmptyStateView: View {
    let emptiness: ScopeEmptiness
    let session: SessionStore

    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @State private var isAddingAccount = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 80, height: 80)
                .background(tint.opacity(0.12), in: Circle())

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }

            if let action {
                Button(action.title) { perform(action.kind) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(tint, in: Capsule())
                    .buttonStyle(.plain)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isAddingAccount) {
            AddAccountFlowView(session: session) { session.refresh.bump() }
        }
    }

    // MARK: - Copy

    private enum ActionKind {
        case addAccount
        case openHousehold
    }

    private struct Action {
        let title: String
        let kind: ActionKind
    }

    private var icon: String {
        switch emptiness {
        case .noAccounts: return "creditcard"
        case .noHousehold, .noSharedAccounts: return "person.2"
        case .noPrivateAccounts: return "lock"
        }
    }

    /// The empty state wears the colour of the scope it is explaining, so a
    /// screen that has gone blank still says *which* scope went blank. The
    /// account case is scope-independent, so it takes the brand accent.
    private var tint: Color {
        switch emptiness {
        case .noAccounts: return Color(hex: "#FF5A5F")
        case .noHousehold, .noSharedAccounts: return PublicSchema.AccountScope.household.tint
        case .noPrivateAccounts: return PublicSchema.AccountScope.me.tint
        }
    }

    private var title: String {
        switch emptiness {
        case .noAccounts: return "No accounts yet"
        case .noHousehold: return "No household yet"
        case .noPrivateAccounts: return "Nothing private here"
        case .noSharedAccounts: return "Nothing shared yet"
        }
    }

    private var message: String {
        switch emptiness {
        case .noAccounts:
            return "Add your first account and Keepo starts tracking balances, spending and transfers."
        case .noHousehold:
            return "Create a household to share accounts with someone and see your money side by side."
        case .noPrivateAccounts:
            return "Every account you have is shared with your household, so there is nothing private to show."
        case .noSharedAccounts:
            return "Share an account with your household and it shows up here."
        }
    }

    private var action: Action? {
        switch emptiness {
        case .noAccounts: return Action(title: "Add Account", kind: .addAccount)
        case .noHousehold: return Action(title: "Create Household", kind: .openHousehold)
        case .noSharedAccounts: return Action(title: "Share Accounts", kind: .openHousehold)
        // Deliberately no button (the user's own call): nothing is broken
        // and nothing needs doing — the answer is "swipe back to Total".
        case .noPrivateAccounts: return nil
        }
    }

    private func perform(_ kind: ActionKind) {
        switch kind {
        case .addAccount: isAddingAccount = true
        case .openHousehold: navigation?.openProfile(.household)
        }
    }
}
