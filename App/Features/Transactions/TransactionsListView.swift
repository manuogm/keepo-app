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
    @State var isCustomRangePresented = false

    // Not `private` — read from TransactionsListView+Period.swift.
    let calendar = Calendar.current

    /// Optional on purpose: this screen has to keep working anywhere the tab
    /// shell isn't above it (a preview, a future standalone presentation),
    /// and a non-optional `@Environment(AppNavigation.self)` would trap
    /// instead. Not `private` — read from TransactionsListView+Period.swift.
    @Environment(AppNavigation.self) var navigation: AppNavigation?
    @Environment(ScopeContext.self) private var scopeContext: ScopeContext?

    // Not `private` — read from TransactionsListView+Filters.swift.
    var scope: PublicSchema.AccountScope { session.scope }

    var range: DateInterval {
        guard let component = period.component else {
            return DateInterval(start: calendar.startOfDay(for: customFrom), end: customThrough)
        }
        return calendar.dateInterval(of: component, for: anchor) ?? DateInterval(start: anchor, duration: 0)
    }

    /// Computed once per load into `@State`, never as a computed property
    /// read from `body`. SwiftUI re-evaluates a body on every unrelated
    /// state change — a sheet opening, the privacy toggle, a scroll-driven
    /// update — and this is a full `Dictionary(grouping:)` plus a sort over
    /// every transaction in the period. As a computed property it ran on
    /// every one of those, which is a real part of why this screen felt
    /// heavy on a busy month.
    struct DayGroup: Identifiable {
        let day: Date
        let items: [PublicSchema.TransactionsWithDetailsSelect]
        var id: Date { day }
    }

    func regroup() {
        let groups = Dictionary(grouping: transactions) { transaction -> Date in
            guard
                let occurredAt = transaction.occurredAt, let date = PostgresDate.date(fromTimestamp: occurredAt)
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
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: navigation?.pendingAdd) { _, _ in
                if navigation?.consumeAdd(.transactions) == true { isAddingTransaction = true }
            }
            .sheet(isPresented: $isAddingTransaction) {
                TransactionFormView(session: session) {
                    session.refresh.bump()
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                TransactionFormView(session: session, mode: .edit(transaction, sibling: sibling(of: transaction))) {
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
            .task(id: TransactionsLoadKey(
                token: session.refresh.token, scope: session.scope, filter: filter, range: range
            )) { await load() }
            // Another screen asking for a specific slice of the ledger — the
            // Cashflow widget's category chevron. `onAppear` as well as
            // `onChange` because the request is set in the same turn as the
            // tab switch, and this screen may not have been on screen to
            // observe the change.
            .onAppear { applyPendingRequest() }
            .onChange(of: navigation?.transactionsRequest) { _, _ in applyPendingRequest() }
    }

    // MARK: - Content

    private var listContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                ScopeBannerView(
                    title: "Transactions",
                    session: session,
                    isFiltersExpanded: isFiltersExpanded,
                    onOpenProfile: { navigation?.openProfileRoot() },
                    accessory: { filterToggle },
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
                        .padding(.top, 4)
                        .fadingTopEdge()
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
                .foregroundStyle(Color.secondary)
            Spacer()
        } else {
            transactionList

            if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }

    private var transactionList: some View {
        List {
            ForEach(groupedByDay) { group in
                Section {
                    ForEach(group.items, id: \.transactionId) { transaction in
                        // A `Button`, not `.onTapGesture`: a bare tap
                        // gesture inside a `List` loses races with the
                        // scroll recogniser (the "first tap does nothing
                        // after scrolling" bug) and draws no press state.
                        Button {
                            handleTap(on: transaction)
                        } label: {
                            TransactionRow(transaction: transaction, category: category(for: transaction))
                        }
                        .buttonStyle(.pressableRow)
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
                                .tint(Color.primary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets, in: group.items) }
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

    // MARK: - Transaction helpers

    func sibling(
        of transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.TransactionsWithDetailsSelect? {
        guard let groupId = transaction.transferGroupId else { return nil }
        return transactions.first { $0.transferGroupId == groupId && $0.transactionId != transaction.transactionId }
    }

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
    public var id: UUID { transactionId ?? UUID() }
}

private struct TransactionsLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
    let filter: TransactionFilter
    let range: DateInterval
}
