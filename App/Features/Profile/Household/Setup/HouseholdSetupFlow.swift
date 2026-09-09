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
    @State private var accounts: [LocalAccountRow] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var selectedAccountIds: Set<UUID> = []
    @State private var selectedCategoryIds: Set<UUID> = []

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
        .task { await load() }
    }

    // MARK: - A. What is about to happen

    private var intro: some View {
        HouseholdSetupIntro(role: role)
            .navigationTitle(role == .owner ? "New Household" : "Join Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HouseholdFlowBar(nextTitle: "Next") { path.append(.accounts) }
            }
    }

    // MARK: - B. Which accounts

    private var accountsStep: some View {
        HouseholdAccountPicker(accounts: accounts, selection: $selectedAccountIds)
            .householdSetupChrome()
            .safeAreaInset(edge: .bottom) {
                HouseholdFlowBar(nextTitle: "Next") { path.append(.categories) }
            }
    }

    // MARK: - C. Which categories

    private var categoriesStep: some View {
        HouseholdCategoryPicker(categories: shareableCategories, selection: $selectedCategoryIds)
            .householdSetupChrome()
            .safeAreaInset(edge: .bottom) {
                HouseholdFlowBar(nextTitle: "Next") { path.append(.discovery) }
            }
    }

    // MARK: - D/E. Finding the other phone, then building

    private var discoveryStep: some View {
        HouseholdDiscoveryView(
            session: session,
            avatars: avatars,
            role: role,
            accountIds: Array(selectedAccountIds),
            categoryIds: Array(selectedCategoryIds),
            onBuilt: {
                onBuilt()
                dismiss()
            }
        )
        .householdSetupChrome()
    }

    // MARK: - Data

    /// The two "Other" rows are each member's own fallback and `share_category`
    /// refuses one, so they are never offered — a control that always fails is
    /// worse than no control.
    private var shareableCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { !$0.isDefault }
    }

    private func load() async {
        guard let ownerId = session.profile?.id.uuidString else { return }
        let baseCurrency = session.profile?.baseCurrency ?? "EUR"
        let loaded = try? await session.dbQueue.read { database in
            (
                try LocalAccountRow.fetchAll(database, ownerId: ownerId, baseCurrency: baseCurrency),
                try LocalTableQueries.categories(database, ownerId: ownerId)
            )
        }
        guard let loaded else { return }
        // Only your own, and only the live ones. An archived account holds no
        // money the household would see, and the other member's accounts are
        // not yours to offer.
        accounts = loaded.0.filter { $0.ownerId == session.profile?.id && $0.archivedAt == nil }
        categories = loaded.1
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
