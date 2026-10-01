import KeepoCore
import SwiftUI

/// The single transactions screen — day-grouped history for a day/week/
/// month/year/custom period, with account/category/kind as a complementary
/// filter on top. Reads straight off the local GRDB mirror (Phase L6) — no
/// server round trip, no payload cache. `Outbox`'s optimistic write-through
/// means a queued-but-unsynced create/edit/delete is already reflected in
/// the same `transactions` rows this screen queries.
struct TransactionsListView: View {
    let session: SessionStore

    enum Period: String, CaseIterable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case year = "Year"
        case custom = "Custom"

        var component: Calendar.Component? {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            case .custom: return nil
            }
        }
    }

    // Not `private` — read/written from TransactionsListView+Loading.swift,
    // an extension in a different file (kept there purely for file-length).
    @State var transactions: [PublicSchema.TransactionsWithDetailsSelect] = []
    /// Transfers this device holds both halves of — see `canDelete(_:)`.
    @State var completeTransferGroups: Set<UUID> = []
    @State var isLoading = true
    @State var loadErrorMessage: String?
    @State var filterCategories: [PublicSchema.CategoriesSelect] = []
    @State var filterAccounts: [LocalAccountRow] = []
    @State private var isAddingTransaction = false
    // Not `private` — read/written from TransactionsListView+Adding.swift,
    // which owns what a tap on a row opens.
    @State var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State var recurringEditChoice: PublicSchema.TransactionsWithDetailsSelect?
    @State var editingRecurringRule: PublicSchema.RecurringRulesSelect?
    @State var filter = TransactionFilter()
    // Not `private` — read/written from TransactionsListView+Filters.swift.
    @State var isSearching = false
    /// Not `private` for the same reason, and `@FocusState` rather than a
    /// `@State` flag because only the field can own whether it holds the
    /// keyboard — see `searchField`, which claims it as it appears.
    @FocusState var isSearchFieldFocused: Bool
    /// The picker the pinned row's chevron opens; its body opens the form.
    @State var isAccountPickerPresented = false
    @State var editingAccountId: UUID?
    /// Which of the drop-down's multi-select sheets is open, if any.
    @State var activeFilterSheet: TransactionFilterSheet?
    /// Who the "Added by" filter may offer — empty without a paired household,
    /// which is also what hides that pill (`TransactionAuthors`).
    @State var authors: [TransactionAuthor] = []
    /// Which sources this ledger actually holds. Fewer than two and the Source
    /// pill is hidden, for the reason the "Added by" pill hides without a
    /// household: an axis with one option cannot narrow anything.
    @State var availableSources: [PublicSchema.TransactionSource] = []
    /// The scope's net worth, for the pinned row and the picker's "All
    /// accounts". `load()` computes it through `LocalMoneyConversion.netWorth`,
    /// the Home hero's own read, never by summing what is on screen — those
    /// rows are one period of one filter, and a balance is neither. Not cleared
    /// when a load starts, so stepping months does not flash an em dash.
    @State var allAccountsBalance: AccountFilterBalance?
    /// Whether the header's filter panel is showing. Owned here rather than
    /// by the banner: `applyPendingRequest` opens it when another screen
    /// hands this one a filter, so the state has to outlive the button.
    @State var isFiltersExpanded = false
    /// The slice another screen handed this one, kept **after** it has been
    /// applied so the header can offer the way back to where it came from.
    ///
    /// Deliberately not the same thing as `AppNavigation.transactionsRequest`,
    /// which is cleared the moment it is consumed so it cannot re-apply
    /// itself on a later visit. This is the memory of that hand-over, and
    /// `isShowingHandedOverSlice` is what decides whether it is still true.
    ///
    /// Not `private` — read/written from TransactionsListView+Period.swift.
    @State var originRequest: TransactionsRequest?
    /// Whether the Needs Review drawer has taken over the screen. Owned here
    /// because the ledger is what it takes over *from* — the drawer cannot
    /// hide a sibling it does not own.
    @State private var isInboxExpanded = false
    // Not `private` — derived by `regroup()` in TransactionsListView+Loading.swift,
    // which is where the load that produces them lives.
    @State var groupedByDay: [DayGroup] = []
    @State var categoriesById: [UUID: PublicSchema.CategoriesSelect] = [:]

    // Not `private` — read/written from TransactionsListView+Period.swift.
    @State var period: Period = .month
    @State var anchor = Date()
    @State var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State var customThrough = Date()
    /// Custom's third state: no bounds at all. Not a sixth period pill —
    /// six options do not fit the track's one row — and not a very wide
    /// range either, which is the point: see `range`.
    @State var isAllTime = false
    @State var isCustomRangePresented = false
    /// The pre-filled Export sheet — see TransactionsListView+Export.swift.
    @State var exportRequest: ExportRequest?

    /// The filter pills' width while **unset** — wide enough for the longest
    /// axis name, and the same for all three so they read as one control.
    /// `@ScaledMetric` so a chip still fits its own label at larger Dynamic
    /// Type sizes instead of truncating the axis name at AX1.
    ///
    /// Not `private` — read from TransactionsListView+Filters.swift.
    @ScaledMetric(relativeTo: .subheadline) var pillWidth: CGFloat = 104
    /// The width of a pill that has an answer on it, which needs more room:
    /// the label goes from "Category" to a category's name or "Category · 2",
    /// in semibold. Three unset pills plus the search button fit a 402pt row
    /// exactly; three *answered* ones do not, and scroll — which is the right
    /// way round, since the row only outgrows the screen once the user has
    /// actually narrowed something.
    ///
    /// Two fixed widths rather than one flexible one: a pill that sizes to its
    /// own text makes the row re-lay itself out on every pick, and a `minWidth`
    /// does the same thing more quietly. Not `private`, same reason as above.
    @ScaledMetric(relativeTo: .subheadline) var answeredPillWidth: CGFloat = 132

    // Not `private` — read from TransactionsListView+Period.swift.
    let calendar = Calendar.current

    /// Optional on purpose: this screen has to keep working anywhere the tab
    /// shell isn't above it (a preview, a future standalone presentation),
    /// and a non-optional `@Environment(AppNavigation.self)` would trap
    /// instead. Not `private` — read from TransactionsListView+Period.swift.
    @Environment(AppNavigation.self) var navigation: AppNavigation?
    @Environment(ScopeContext.self) private var scopeContext: ScopeContext?
    /// Optional for the same reason as `navigation` above.
    @Environment(FTUXCoordinator.self) private var ftux: FTUXCoordinator?

    // Not `private` — read from TransactionsListView+Filters.swift.
    var scope: PublicSchema.AccountScope { session.scope }

    /// Computed once per load into `@State`, never as a computed property
    /// read from `body`. SwiftUI re-evaluates a body on every unrelated
    /// state change — a sheet opening, the privacy toggle, a scroll-driven
    /// update — and this is a full `Dictionary(grouping:)` plus a sort over
    /// every transaction in the period. As a computed property it ran on
    /// every one of those, which is a real part of why this screen felt
    /// heavy on a busy month.
    struct DayGroup: Identifiable {
        let day: Date
        let items: [TransactionEntry]
        var id: Date { day }
    }

    // MARK: - Body

    var body: some View {
        ledgerWithFilterSheets
            .dropsBottomSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: navigation?.pendingAdd) { _, _ in
                if navigation?.consumeAdd(.transactions) == true { isAddingTransaction = true }
            }
            .sheet(isPresented: $isAddingTransaction) {
                TransactionFormView(session: session, seed: newTransactionSeed) {
                    session.refresh.bump()
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                TransactionFormView(session: session, mode: .edit(transaction)) {
                    session.refresh.bump()
                }
            }
            .sheet(item: $editingRecurringRule) { rule in
                RecurringRuleFormView(session: session, mode: .edit(rule)) {
                    session.refresh.bump()
                }
            }
            .confirmationDialog(
                "This is a recurring transaction", isPresented: recurringChoiceBinding, presenting: recurringEditChoice
            ) { transaction in
                Button("Edit this transaction") { editingTransaction = transaction }
                Button("Edit all future occurrences") {
                    Task { await openRecurringRule(for: transaction) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $isCustomRangePresented) {
                customRangeSheet
            }
            .modifier(ExportSheetModifier(request: $exportRequest, session: session))
            .task(id: TransactionsLoadKey(
                token: session.refresh.token, scope: session.scope, filter: filter, range: range
            )) { await load() }
            // Its own task, not part of `load()`: resolving a partner's name
            // can cost a network round trip on a first-ever read, and the
            // ledger must not wait behind it. Keyed on the refresh token
            // alone, so pairing or dissolving a household re-reads it while
            // changing a filter or a period does not.
            .task(id: session.refresh.token) { await loadAuthors() }
            // Another screen asking for a specific slice of the ledger — the
            // Cashflow widget's category chevron. `onAppear` as well as
            // `onChange` because the request is set in the same turn as the
            // tab switch, and this screen may not have been on screen to
            // observe the change.
            .onAppear { applyPendingRequest() }
            // Only with a row to point at. The inbox drawer offers its own
            // lesson when it has something in it — see `NeedsReviewPanel`.
            .onAppear { Task { await offerLessons() } }
            .task(id: firstTransactionId) { await offerLessons() }
            .onChange(of: navigation?.transactionsRequest) { _, _ in applyPendingRequest() }
    }

    // MARK: - Content

    // Not `private` — wrapped by `ledgerWithFilterSheets` in
    // TransactionsListView+FilterBar.swift, which attaches the filter
    // controls' own sheets.
    var listContent: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: 0) {
                ScopeBannerView(
                    title: "Transactions",
                    session: session,
                    isFiltersExpanded: isFiltersExpanded,
                    onBack: backToDashboard,
                    onOpenProfile: { navigation?.openProfileRoot() },
                    accessory: { headerActions },
                    filters: { filterPanel }
                )
                .zIndex(1)

                // Deliberately outside the scope blank state below: a
                // capture waiting for review is a task, not a balance, and
                // it does not stop existing because the user swiped to a
                // scope with nothing in it.
                //
                // `zIndex(0)` against the banner's 1 is what puts the
                // drawer *behind* it — see `NeedsReviewPanel`'s own header.
                NeedsReviewPanel(session: session, isExpanded: $isInboxExpanded)
                    .zIndex(0)

                if !isInboxExpanded {
                    // Pinned rather than scrolling with the list: these
                    // two say what the list is, and an explanation that
                    // scrolls off is not one. Below the drawer because they
                    // are the *ledger's* controls — when the inbox takes the
                    // screen there is no list left for them to filter.
                    filterBar
                        .padding(.horizontal, AppTheme.Spacing.l)
                        .padding(.top, AppTheme.Spacing.s)

                    ledger
                        .padding(.top, AppTheme.Spacing.s)
                        .fadingEdges()
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var ledger: some View {
        if let emptiness = scopeContext?.emptiness(for: session.scope) {
            ScopeEmptyStateView(emptiness: emptiness, session: session)
        } else if isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else if transactions.isEmpty {
            Spacer()
            Text(emptyLedgerMessage)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.l)
            Spacer()
        } else {
            transactionList

            if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.statusNegative)
                    .padding()
            }
        }
    }

    private var transactionList: some View {
        List {
            ForEach(groupedByDay) { group in
                Section {
                    ForEach(group.items) { entry in
                        let transaction = entry.transaction
                        // A `Button`, not `.onTapGesture`: a bare tap
                        // gesture inside a `List` loses races with the
                        // scroll recogniser (the "first tap does nothing
                        // after scrolling" bug) and draws no press state.
                        Button {
                            handleTap(on: transaction)
                        } label: {
                            TransactionRow(
                                transaction: transaction,
                                category: category(for: transaction),
                                counterpart: entry.counterpart
                            )
                        }
                        .buttonStyle(.pressableRow)
                        // The top row is what the swipe coach mark cuts its
                        // hole around, and it stays swipeable underneath —
                        // so a touch on it is the lesson being performed,
                        // and ends it. Zero distance for the reason the
                        // accounts row uses zero: a list claims a drag
                        // before a competing gesture reaches any threshold.
                        .ftuxAnchor(
                            transaction.transactionId == firstTransactionId
                                ? FTUXLessons.swipeDelete : nil,
                            expandedBy: Self.rowTileExpansion
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in ftux?.dismiss(FTUXLessons.swipeDelete) },
                            including: transaction.transactionId == firstTransactionId
                                && ftux?.isVisible(FTUXLessons.swipeDelete) == true ? .all : .none
                        )
                        .swipeActions(edge: .trailing) {
                            // A second, quick path to confirm a capture,
                            // alongside the full review form's Save — only
                            // offered once an account is actually known
                            // (unresolved captures still route through the
                            // form, which requires the explicit account
                            // verification a blind swipe can't provide).
                            if transaction.status == .pending, transaction.accountId != nil {
                                Button("Confirm") {
                                    Task { await confirmCapture(transaction) }
                                }
                                .tint(AppTheme.Palette.textPrimary)
                            }
                        }
                        // Half of a transfer whose other half is on an account
                        // this viewer cannot see: `delete_transfer` would
                        // refuse it, so the swipe is not offered at all.
                        .deleteDisabled(!canDelete(entry))
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets, in: group.items.map(\.transaction)) }
                    }
                } header: {
                    Text(group.day.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, KeepoTabBarMetrics.clearance, for: .scrollContent)
        .refreshable { await load() }
    }

    // MARK: - Coach marks

    /// How far the white tile reaches past the row's own bounds.
    ///
    /// Unlike the Accounts list, this one lets the system draw each row's
    /// card, and an inset-grouped `List` insets the content a good way
    /// inside it. Without this the hole was 44×338 inside a tile of 55×369
    /// — a highlight visibly smaller than the thing it highlights, which is
    /// the one mistake a cut-out cannot get away with. Measured from a
    /// screenshot rather than reasoned from the row's padding, because half
    /// of it is the system's and not ours to read.
    private static let rowTileExpansion = CGSize(width: AppTheme.Spacing.l, height: 6)

    private var firstTransactionId: UUID? {
        groupedByDay.first?.items.first?.transaction.transactionId
    }

    private func offerLessons() async {
        guard firstTransactionId != nil else { return }
        await ftux?.offer([FTUXLessons.swipeDelete])
    }
}

// MARK: - Supporting types

extension PublicSchema.TransactionsWithDetailsSelect: Identifiable {
    /// Optional, and never `?? UUID()` — see `TransactionEntry.id` for what
    /// a freshly-minted fallback identity does to a `List` row and to
    /// `.sheet(item:)`.
    public var id: UUID? { transactionId }
}
