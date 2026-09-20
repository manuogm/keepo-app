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
    /// account-specific cases that don't mean anything here. Gated on
    /// `isLoaded` so a household that simply hasn't loaded yet doesn't flash
    /// as "no household" for a frame.
    private var showsHouseholdBlankState: Bool {
        session.scope == .household && scopeContext?.isLoaded == true && scopeContext?.hasHousehold == false
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.m), count: 3)

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                ScopeBannerView(
                    title: "Categories", session: session, showsPrivacyToggle: false,
                    onOpenProfile: { navigation?.openProfileRoot() }
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
                    // Pinned below rather than the tab bar's own distance: the
                    // grid now hands off to the "All Tags" row sitting right
                    // under it, not to the physical bottom of the display.
                    .contentMargins(.bottom, AppTheme.Spacing.l, for: .scrollContent)
                    .refreshable { await load() }
                    .fadingEdges(bottom: 22)

                    // Pinned below the grid instead of scrolling with it, so
                    // it stays reachable at a glance instead of being the
                    // last thing after however many categories exist — and
                    // the grid gets the rest of the screen to itself.
                    allTagsLink
                        .padding(.horizontal)
                        .padding(.top, AppTheme.Spacing.s)
                        .padding(.bottom, KeepoTabBarMetrics.clearance)
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

    /// Below the grid rather than in the toolbar: tags are a *second*
    /// thing this screen is about, reached after looking at the categories,
    /// not a competing primary action next to "+" — which on this tab
    /// already means "new category".
    ///
    /// Pinned to the bottom of the screen rather than scrolling with the
    /// grid: a household with a long category list would otherwise push it
    /// past however many tiles exist, and the grid above it gets the whole
    /// scroll area to itself instead of giving up its last slot to this row.
    private var allTagsLink: some View {
        Button {
            isShowingAllTags = true
        } label: {
            HStack(spacing: AppTheme.Spacing.s) {
                KeepoIcon(name: "icon-tag", size: AppTheme.Size.glyphSmall)
                Text("All Tags")
                    .font(AppTheme.Typography.label)
                Spacer()
                // Overridden against the row's own `textPrimary`: every
                // disclosure chevron in the app is `textSecondary`, matching
                // the system indicator `List` draws for a `NavigationLink`.
                Image(systemName: "chevron.right")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .padding(AppTheme.Spacing.l)
            .background(
                AppTheme.Palette.bgSurface,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.card)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        }
        .buttonStyle(.pressableCard)
    }

    private func load() async {
        errorMessage = nil
        guard let ownerId = session.profile?.id else {
            isLoading = false
            return
        }
        do {
            categories = try await session.dbQueue.read { database in
                try LocalTableQueries.categories(database, ownerId: ownerId.uuidString)
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }
}
