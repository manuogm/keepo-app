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
    @State private var isSearching = false
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
        mainContent
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ScopeSwitcherButton(session: session)
                }
                ToolbarItem(placement: .principal) {
                    ScreenTitleBar(title: "Transactions", session: session)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingTransaction = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
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
            .task(id: TransactionsLoadKey(token: session.refresh.token, filter: filter, range: range)) { await load() }
    }

    // MARK: - Content

    /// `.searchable` is attached only while `isSearching` is true — attaching
    /// it unconditionally makes SwiftUI render a persistent full-width search
    /// row in the List regardless of the `isPresented` binding, which is
    /// exactly the row the toolbar search icon was meant to replace.
    @ViewBuilder
    private var mainContent: some View {
        if isSearching {
            listContent
                .searchable(text: searchBinding, isPresented: $isSearching, prompt: "Merchant, category, or account")
        } else {
            listContent
        }
    }

    private var listContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                accountFilterMenu
                periodNavigator

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if transactions.isEmpty {
                    Spacer()
                    Text("No transactions in this period")
                        .foregroundStyle(Color.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(groupedByDay) { group in
                            Section {
                                ForEach(group.items, id: \.transactionId) { transaction in
                                    // A `Button`, not `.onTapGesture`: a bare
                                    // tap gesture inside a `List` loses races
                                    // with the scroll recogniser (the "first
                                    // tap does nothing after scrolling" bug)
                                    // and draws no press state at all.
                                    Button {
                                        handleTap(on: transaction)
                                    } label: {
                                        TransactionRow(
                                            transaction: transaction, category: category(for: transaction)
                                        )
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
                    .refreshable { await load() }
                }

                if let loadErrorMessage {
                    Text(loadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
    }

    // MARK: - Account filter

    private var accountFilterMenu: some View {
        Menu {
            Button {
                filter.accountId = nil
            } label: {
                if filter.accountId == nil {
                    Label("All Accounts", systemImage: "checkmark")
                } else {
                    Text("All Accounts")
                }
            }
            ForEach(filterAccounts) { account in
                Button {
                    filter.accountId = account.id
                } label: {
                    if filter.accountId == account.id {
                        Label(account.name, systemImage: "checkmark")
                    } else {
                        Text(account.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedAccountName)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedAccountName: String {
        guard let accountId = filter.accountId else { return "All Accounts" }
        return filterAccounts.first { $0.id == accountId }?.name ?? "All Accounts"
    }

    // MARK: - Transaction helpers

    private var searchBinding: Binding<String> {
        Binding(get: { filter.search ?? "" }, set: { filter.search = $0.isEmpty ? nil : $0 })
    }

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
    let filter: TransactionFilter
    let range: DateInterval
}
