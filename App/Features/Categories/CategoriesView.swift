import KeepoCore
import SwiftUI

/// Square icon+color tiles rather than plain rows — tap opens the edit
/// sheet, which is also where deletion now lives (see CategoryFormView):
/// a `LazyVGrid` tile has no swipe-actions affordance the way a `List` row
/// does, so consolidating delete into the sheet isn't a compromise, it's
/// the natural consequence of the tile layout.
///
/// A **top-level tab** since tags landed, not a row two levels inside
/// Profile → Preferences. A category stopped being a thing you configure
/// once at signup the moment tags started hanging off it.
///
/// It wears the same `ScopeBannerView` as the three money screens, and since
/// household category sharing landed the swipe **filters this grid too**:
/// Household shows the categories you share, Private the ones you do not.
/// The banner was inert here until then, which is what the previous version
/// of this comment described.
struct CategoriesView: View {
    let session: SessionStore

    private enum KindTab: String, CaseIterable {
        case expense = "Expense"
        case income = "Income"

        var categoryKind: PublicSchema.CategoryKind {
            self == .income ? .income : .expense
        }
    }

    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isAddingCategory = false
    @State private var editingCategoryId: UUID?
    @State private var isShowingAllTags = false
    @State private var selectedTab: KindTab = .expense
    /// Whether the user has never had a category beyond the seeded `Other`
    /// rows (`LocalTableQueries.ownsOnlyStarterCategories`).
    @State private var ownsOnlyStarterCategories = false
    @State private var isShowingSuggestions = false

    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    /// Shared with the three money screens (see `MainTabView`) purely for the
    /// one fact this screen also needs: whether a household exists at all.
    /// Its account-shaped emptiness cases (`noAccounts`, `noSharedAccounts`,
    /// ...) don't apply here — a category isn't scoped money — so this reads
    /// `hasHousehold` directly rather than going through `emptiness(for:)`.
    @Environment(ScopeContext.self) private var scopeContext: ScopeContext?

    private var expenseCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .expense }
    }

    private var incomeCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == .income }
    }

    private var visibleCategories: [PublicSchema.CategoriesSelect] {
        (selectedTab == .expense ? expenseCategories : incomeCategories).filter(isInScope)
    }

    /// The same question the money screens ask, now that a category can
    /// genuinely be shared: a shared category is one with a `shared_group_id`,
    /// exactly as a shared account is one with a `household_accounts` row.
    ///
    /// This screen's header comment used to say the swipe was inert here and
    /// would stop being so "the moment household category sharing lands". It
    /// landed; switching scope with the grid unchanged read as the filter
    /// being broken.
    private func isInScope(_ category: PublicSchema.CategoriesSelect) -> Bool {
        switch session.scope {
        case .total: return true
        case .me: return category.sharedGroupId == nil
        case .household: return category.sharedGroupId != nil
        }
    }

    /// Household scope with nobody to share a category with — the same
    /// "nothing behind this scope" state the money screens show, minus the
    /// account-specific cases that don't mean anything here.
    private var showsHouseholdBlankState: Bool {
        scopeContext?.isMissingHousehold(in: session.scope) == true
    }

    /// The catalogue onboarding offered, offered again to someone who
    /// skipped it — over a grid holding nothing but `Other`, which is
    /// otherwise a screen that looks broken rather than new.
    ///
    /// A fact about the data, not a flag: it lasts exactly until the user
    /// owns a category of their own, from the sheet or from "+", and never
    /// comes back — deleting everything later is a choice, not a fresh
    /// start (the query counts tombstones for that reason). Not in
    /// Household scope, where the grid is the categories you share and a
    /// starter kit of private ones would be an answer to the wrong question.
    private var offersSuggestions: Bool {
        ownsOnlyStarterCategories && session.scope != .household
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.m), count: 3)

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                ScopeBannerView(
                    title: "Categories", session: session, showsPrivacyToggle: false,
                    onOpenProfile: { navigation?.openProfileRoot() },
                    accessory: { allTagsButton }
                )
                .padding(.bottom, AppTheme.Spacing.xs)
                .zIndex(1)

                // Hidden in the household blank state: there is nothing behind
                // either tab to switch to, so the control would offer a choice
                // between two views of the same emptiness.
                if !showsHouseholdBlankState {
                    Picker("Kind", selection: $selectedTab) {
                        ForEach(KindTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .sensoryFeedback(AppTheme.Feedback.selection, trigger: selectedTab)
                }

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if showsHouseholdBlankState {
                    ScopeEmptyStateView(emptiness: .noHousehold, session: session)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: AppTheme.Spacing.m) {
                            ForEach(visibleCategories, id: \.id) { category in
                                Button {
                                    editingCategoryId = category.id
                                } label: {
                                    CategoryTile(category: category)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    // Runs under the floating tab bar like the Accounts list
                    // does, now that no pinned row sits between the two.
                    .contentMargins(.bottom, KeepoTabBarMetrics.clearance, for: .scrollContent)
                    .refreshable { await load() }
                    .fadingEdges()
                    .overlay {
                        if offersSuggestions { suggestionsPrompt }
                    }
                }
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    FormErrorText(message: errorMessage)
                        .padding()
                }
            }
        }
        .dropsBottomSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        // The "+" is the tab bar's Add button now, not a toolbar item — it
        // acts on whichever tab you are on, and on this one that means a new
        // category. Same contract as Accounts and Transactions.
        .onChange(of: navigation?.pendingAdd) { _, _ in
            if navigation?.consumeAdd(.categories) == true { isAddingCategory = true }
        }
        // The kind picker above has already answered "expense or income", so the
        // form is opened for that kind rather than asking a second time. Two
        // entry points, one form — the kind is a parameter, not a control.
        .sheet(isPresented: $isAddingCategory) {
            CategoryFormView(session: session, mode: .create(kind: selectedTab.categoryKind), existing: categories) {
                session.refresh.bump()
            }
        }
        .sheet(isPresented: $isShowingSuggestions) {
            SuggestedCategoriesSheet(session: session) { session.refresh.bump() }
        }
        .sheet(isPresented: $isShowingAllTags) {
            TagsListView(session: session)
        }
        .sheet(item: $editingCategoryId) { id in
            if let category = categories.first(where: { $0.id == id }) {
                CategoryFormView(session: session, mode: .edit(category), existing: categories) {
                    session.refresh.bump()
                }
            }
        }
        .task(id: session.refresh.token) { await load() }
    }

    /// In the header's trailing corner — the spot the privacy toggle holds
    /// on Transactions, which this screen has nothing to mask with. It was a
    /// full-width "All Tags" row pinned above the tab bar, which took a
    /// band of screen from the grid on every visit to offer something most
    /// visits never use. As a glyph it stays one tap away and costs nothing,
    /// and the "+" still means a new category, not a tag.
    private var allTagsButton: some View {
        Button {
            isShowingAllTags = true
        } label: {
            KeepoIcon(name: "icon-tag")
                .foregroundStyle(.white)
                .frame(width: AppTheme.Size.icon, height: AppTheme.Size.icon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All tags")
    }

    /// Centred in the space the `Other` tile leaves, and laid out like the
    /// app's other empty states (`ScopeEmptyStateView`): a line of copy and
    /// one capsule button.
    private var suggestionsPrompt: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            Text("Not sure where to start? See some commonly used categories here.")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Size.proseWidth)
            Button("See categories") { isShowingSuggestions = true }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(AppTheme.Palette.brandPrimary, in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        // Centred in what the user can actually see, not in a region that
        // runs under the floating tab bar.
        .padding(.bottom, KeepoTabBarMetrics.clearance)
    }

    private func load() async {
        errorMessage = nil
        guard let ownerId = session.profile?.id else {
            isLoading = false
            return
        }
        do {
            (categories, ownsOnlyStarterCategories) = try await session.dbQueue.read { database in
                (
                    try LocalTableQueries.categories(database, ownerId: ownerId.uuidString),
                    try LocalTableQueries.ownsOnlyStarterCategories(database, ownerId: ownerId.uuidString)
                )
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }
}
