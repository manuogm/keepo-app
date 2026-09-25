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
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var recurringEditChoice: PublicSchema.TransactionsWithDetailsSelect?
    @State private var editingRecurringRule: PublicSchema.RecurringRulesSelect?
    @State var filter = TransactionFilter()
    // Not `private` — read/written from TransactionsListView+Filters.swift.
    @State var isSearching = false
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
    @State private var groupedByDay: [DayGroup] = []
    @State private var categoriesById: [UUID: PublicSchema.CategoriesSelect] = [:]

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

    /// The filter pills' fixed width — the fix for the distortion
    /// `pillLabel` documents, and the reason it is a *width* rather than a
    /// minimum. `@ScaledMetric` so a chip still fits its own label at larger
    /// Dynamic Type sizes instead of truncating "Categories" at AX1.
    ///
    /// Not `private` — read from TransactionsListView+Filters.swift.
    @ScaledMetric(relativeTo: .subheadline) var pillWidth: CGFloat = 104

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

    func regroup() {
        // Transfer legs are folded into one entry BEFORE the day grouping,
        // not inside it — both legs carry the same `occurred_at`, but the
        // pairing is a property of the transfer, not of the day it landed on.
        let groups = Dictionary(grouping: TransactionEntry.collapsingTransfers(transactions)) { entry -> Date in
            guard
                let occurredAt = entry.transaction.occurredAt,
                let date = PostgresDate.date(fromTimestamp: occurredAt)
            else { return .distantPast }
            return calendar.startOfDay(for: date)
        }
        groupedByDay = groups.keys.sorted(by: >).map { day in DayGroup(day: day, items: groups[day] ?? []) }
        // Same reasoning: the filter list is small but the lookup runs once
        // per row per render, so it is built once here instead.
        categoriesById = Dictionary(filterCategories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func category(
        for transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.CategoriesSelect? {
        transaction.categoryId.flatMap { categoriesById[$0] }
    }

    // MARK: - Body

    var body: some View {
        listContent
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

    private var listContent: some View {
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
                    ledger
                        .padding(.top, AppTheme.Spacing.xs)
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
            Text("No transactions in this period")
                .foregroundStyle(AppTheme.Palette.textSecondary)
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

    // MARK: - Adding

    /// What the ledger is currently narrowed to, handed to the form so that
    /// filtering and adding are one gesture instead of the same answers
    /// given twice. Read at presentation time, so it is whatever the panel
    /// says the moment the sheet opens rather than whatever it said when
    /// this screen was built.
    ///
    /// The period travels as a **date**, clamped into the range on screen:
    /// the list filters on `occurred_at`, so a transaction added while
    /// looking at March and dated today would save and then vanish. See
    /// `TransactionSeed.date(in:now:calendar:)`.
    private var newTransactionSeed: TransactionSeed {
        TransactionSeed(filter: filter, visible: range)
    }

    // MARK: - Transaction helpers

    private func handleTap(on transaction: PublicSchema.TransactionsWithDetailsSelect) {
        if transaction.recurringRuleId != nil {
            recurringEditChoice = transaction
        } else {
            editingTransaction = transaction
        }
    }

    private var recurringChoiceBinding: Binding<Bool> {
        Binding(get: { recurringEditChoice != nil }, set: { if !$0 { recurringEditChoice = nil } })
    }

    private func openRecurringRule(for transaction: PublicSchema.TransactionsWithDetailsSelect) async {
        guard let ruleId = transaction.recurringRuleId else { return }
        editingRecurringRule = try? await session.dbQueue.read { database in
            try LocalTableQueries.recurringRule(database, id: ruleId.uuidString)
        }
    }
}

// MARK: - Supporting types

extension PublicSchema.TransactionsWithDetailsSelect: Identifiable {
    /// Optional, and never `?? UUID()` — see `TransactionEntry.id` for what
    /// a freshly-minted fallback identity does to a `List` row and to
    /// `.sheet(item:)`.
    public var id: UUID? { transactionId }
}
