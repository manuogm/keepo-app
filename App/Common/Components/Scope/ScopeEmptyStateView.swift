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

    @ViewBuilder
    var body: some View {
        if case .noHousehold = emptiness {
            // Not a case of the layout below: this state is the front door to
            // a feature, with two doors, and it is the same view the
            // Household screen shows. Both buttons open the setup flow in
            // place — see `AppNavigation.householdSetupRole`.
            HouseholdBlankState(
                onCreate: { navigation?.householdSetupRole = .owner },
                onJoin: { navigation?.householdSetupRole = .guest },
                bottomInset: KeepoTabBarMetrics.clearance
            )
        } else {
            explanation
        }
    }

    private var explanation: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            if let illustration {
                KeepoIllustration(name: illustration)
            } else {
                ScopeGlyph(name: icon, size: AppTheme.Size.icon)
                    .font(AppTheme.Typography.screenTitle.weight(.light))
                    .foregroundStyle(tint)
                    .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
                    .background(tint.opacity(AppTheme.Opacity.fill), in: Circle())
            }

            VStack(spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(AppTheme.Typography.rowTitle)
                Text(message)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let action {
                Button(action.title) { perform(action.kind) }
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.vertical, AppTheme.Spacing.m)
                    .background(tint, in: Capsule())
                    .buttonStyle(.plain)
                    .padding(.top, AppTheme.Spacing.xxs)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        // Centred in what the user can actually see, not in a region that
        // now runs under the floating tab bar.
        .padding(.bottom, KeepoTabBarMetrics.clearance)
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

    /// A drawing in place of the glyph, for the states that are a first
    /// step rather than a filter coming up empty: no accounts at all is the
    /// whole app waiting to start, the same weight as no household.
    private var illustration: String? {
        switch emptiness {
        case .noAccounts: return "illustration-no-account"
        case .noHousehold, .noSharedAccounts, .noPrivateAccounts: return nil
        }
    }

    private var icon: String {
        switch emptiness {
        // `.noAccounts` draws `illustration` instead, so its glyph is never
        // shown; it is grouped so the switch stays exhaustive. `.noHousehold`
        // is drawn by `HouseholdBlankState` and never reaches the arms below;
        // it is grouped the same way, without a second copy of that state's
        // copy.
        case .noAccounts, .noHousehold, .noSharedAccounts: return "icon-home"
        case .noPrivateAccounts: return "icon-lock"
        }
    }

    /// The empty state wears the colour of the scope it is explaining, so a
    /// screen that has gone blank still says *which* scope went blank. The
    /// account case is scope-independent, so it takes the brand accent.
    private var tint: Color {
        switch emptiness {
        case .noAccounts: return AppTheme.Palette.brandPrimary
        case .noHousehold, .noSharedAccounts: return PublicSchema.AccountScope.household.tint
        case .noPrivateAccounts: return PublicSchema.AccountScope.me.tint
        }
    }

    private var title: String {
        switch emptiness {
        case .noAccounts: return "No accounts yet"
        case .noPrivateAccounts: return "Nothing private here"
        case .noHousehold, .noSharedAccounts: return "Nothing shared yet"
        }
    }

    private var message: String {
        switch emptiness {
        case .noAccounts:
            return "Add your first account and start tracking your money."
        case .noPrivateAccounts:
            return "Every account you have is shared with your household, so there is nothing private to show."
        case .noHousehold, .noSharedAccounts:
            return "Share an account with your household and it shows up here."
        }
    }

    private var action: Action? {
        switch emptiness {
        case .noAccounts: return Action(title: "Add Account", kind: .addAccount)
        case .noHousehold, .noSharedAccounts: return Action(title: "Share Accounts", kind: .openHousehold)
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
