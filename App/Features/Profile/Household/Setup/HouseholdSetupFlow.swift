import KeepoCore
import SwiftUI

/// Creating or joining a household, from the first explanation to the moment
/// two phones find each other.
///
/// **One flow, two roles.** The spec describes Create and Join as separate
/// journeys, and they read as separate journeys — different titles, different
/// words, a different button at the end. But they ask the same three
/// questions in the same order, and building them twice would mean the day
/// somebody adds a fourth question, one side gets it. So the difference lives
/// in `role`, which changes every sentence and nothing else.
///
/// The steps are a `NavigationStack` path rather than a `switch` on an enum,
/// because the spec asks for a chevron back to the previous step: pushing is
/// what gives the interactive swipe-back and the animation for free, and a
/// hand-rolled step index would have to reimplement both.
struct HouseholdSetupFlow: View {
    let session: SessionStore
    let avatars: AvatarStore
    let role: HouseholdPairingIdentity.Role
    /// Called once the household exists and both phones have finished. The
    /// Household screen reloads onto its populated state.
    var onBuilt: () -> Void

    private enum Step: Hashable {
        case accounts
        case categories
        case discovery
    }

    @Environment(\.dismiss) private var dismiss

    @State private var path: [Step] = []
    /// A reference type, deliberately — see `HouseholdSetupModel`'s own note.
    /// Reading this flow's data from `@State` inside the
    /// `navigationDestination` closure below silently rendered a stale, empty
    /// copy on every pushed step.
    @State private var model = HouseholdSetupModel()

    var body: some View {
        NavigationStack(path: $path) {
            intro
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .accounts: accountsStep
                    case .categories: categoriesStep
                    case .discovery: discoveryStep
                    }
                }
        }
        .task { await model.load(session: session) }
    }

    // MARK: - A. What is about to happen

    private var intro: some View {
        HouseholdSetupIntro(role: role) {
            HouseholdFlowBar(nextTitle: "Next") { path.append(.accounts) }
        }
        .navigationTitle(role == .owner ? "New Household" : "Join Household")
        .navigationBarTitleDisplayMode(.inline)
        // The local-network permission is asked for here, while the user is
        // reading what the flow does, rather than on the discovery screen
        // three steps later — see `primeLocalNetworkPermission`. Detached
        // from the two picker steps on purpose: it takes two seconds of
        // radio and must not hold up `Next`.
        .task { await HouseholdPairingSession.primeLocalNetworkPermission() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
        }
    }

    // MARK: - B. Which accounts

    private var accountsStep: some View {
        HouseholdAccountPicker(
            accounts: model.accounts,
            isLoaded: model.isLoaded,
            selection: Bindable(model).selectedAccountIds
        ) {
            HouseholdFlowBar(nextTitle: "Next") { path.append(.categories) }
        }
        .householdSetupChrome()
    }

    // MARK: - C. Which categories

    private var categoriesStep: some View {
        HouseholdCategoryPicker(
            categories: model.categories,
            isLoaded: model.isLoaded,
            selection: Bindable(model).selectedCategoryIds
        ) {
            HouseholdFlowBar(nextTitle: "Next") { path.append(.discovery) }
        }
        .householdSetupChrome()
    }

    // MARK: - D/E. Finding the other phone, then building

    private var discoveryStep: some View {
        HouseholdDiscoveryView(
            session: session,
            avatars: avatars,
            role: role,
            accountIds: Array(model.selectedAccountIds),
            categoryIds: Array(model.selectedCategoryIds),
            onBuilt: {
                onBuilt()
                dismiss()
            }
        )
        .householdSetupChrome()
    }

}

private extension View {
    /// Every step after the first wears the same title and the same back
    /// chevron. Written once so the three cannot drift — the chevron is
    /// `NavigationStack`'s own, so nothing here re-implements going back.
    func householdSetupChrome() -> some View {
        navigationTitle("Household Setup")
            .navigationBarTitleDisplayMode(.inline)
    }
}
