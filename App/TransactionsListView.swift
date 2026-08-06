import KeepoCore
import SwiftUI

struct TransactionsListView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.TransactionsWithDetailsSelect>(cacheKey: "transactions_page_0")
    @State private var isAddingTransaction = false
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var recurringEditChoice: PublicSchema.TransactionsWithDetailsSelect?
    @State private var editingRecurringRule: PublicSchema.RecurringRulesSelect?
    @State private var showConflictAlert = false
    @State private var filter = TransactionFilter()
    @State private var isFilterSheetPresented = false
    @State private var filterAccounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var filterCategories: [PublicSchema.CategoriesSelect] = []

    private var transactions: [PublicSchema.TransactionsWithDetailsSelect] { store.items }

    /// Pending *creates* only (Phase 11) — resolved against whatever
    /// accounts/categories are already loaded for the filter sheet, since
    /// those already carry names and are refreshed the same way this
    /// screen refreshes everything else. Updates/deletes stay invisible
    /// until drained; see Outbox.pendingCreateTransactions' own doc comment.
    private var pendingRows: [PendingTransactionDisplay] {
        session.outbox.pendingCreateTransactions.map { pending in
            let account = filterAccounts.first { $0.accountId == pending.accountId }
            let category = filterCategories.first { $0.id == pending.categoryId }
            return PendingTransactionDisplay(
                id: pending.id,
                accountName: account?.name ?? "—",
                categoryName: category?.name ?? "—",
                amount: pending.amount,
                currency: pending.currency,
                minorUnit: Int(account?.minorUnit ?? 2)
            )
        }
    }

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else if transactions.isEmpty && pendingRows.isEmpty {
                Text("No transactions yet")
                    .foregroundStyle(Color("TextSecondary"))
            } else {
                List {
                    if let asOf = store.asOf {
                        Text("Showing data as of \(asOf.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(Color("TextSecondary"))
                    }
                    if !pendingRows.isEmpty {
                        Section("Pending sync") {
                            ForEach(pendingRows) { pending in
                                PendingTransactionRow(pending: pending)
                            }
                        }
                    }
                    ForEach(transactions, id: \.transactionId) { transaction in
                        TransactionRow(transaction: transaction)
                            .contentShape(Rectangle())
                            .onTapGesture { handleTap(on: transaction) }
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets) }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .searchable(text: searchBinding, prompt: "Merchant, category, or account")
        .navigationTitle("Transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingTransaction = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isFilterSheetPresented = true
                } label: {
                    Image(systemName: filterIconName)
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
        .sheet(isPresented: $isFilterSheetPresented) {
            TransactionFilterView(filter: $filter, accounts: filterAccounts, categories: filterCategories)
        }
        .alert("This transaction changed elsewhere", isPresented: $showConflictAlert) {
            Button("OK") {}
        } message: {
            Text("The list has been refreshed with the latest version.")
        }
        .task { store.restore(from: session.payloadCache) }
        .task(id: TransactionsLoadKey(token: session.refresh.token, filter: filter)) { await load() }
    }

    /// `.searchable` needs a plain `Binding<String>`; `filter.search` is an
    /// `Optional` (nil means "no search filter" everywhere else it's read).
    private var searchBinding: Binding<String> {
        Binding(get: { filter.search ?? "" }, set: { filter.search = $0.isEmpty ? nil : $0 })
    }

    private var filterIconName: String {
        filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
    }

    private func sibling(
        of transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.TransactionsWithDetailsSelect? {
        guard let groupId = transaction.transferGroupId else { return nil }
        return transactions.first { $0.transferGroupId == groupId && $0.transactionId != transaction.transactionId }
    }

    /// A row materialized from a recurring rule needs a choice before
    /// editing at all — "this one" (the historical row, unaffected by any
    /// future rule change) vs "all future" (the rule itself). An ordinary
    /// manual/capture/transfer row skips straight to the normal edit sheet.
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
        editingRecurringRule = try? await RecurringRuleRepository.fetchOne(client: session.client, id: ruleId)
    }

    private func load() async {
        if filterAccounts.isEmpty {
            let fetched = try? await AccountRepository.fetchAllWithBalances(client: session.client)
            filterAccounts = fetched ?? cachedAccounts()
        }
        if filterCategories.isEmpty {
            let fetched = try? await CategoryRepository.fetchAll(client: session.client)
            filterCategories = fetched ?? cachedCategories()
        }
        // Caching only applies to the default, unfiltered page — caching
        // every filter permutation would be pointless; a filtered view
        // simply has no offline fallback beyond whatever's already shown.
        await store.load(
            { try await TransactionRepository.fetchFiltered(client: session.client, filter: filter) },
            cache: filter.isEmpty ? session.payloadCache : nil
        )
    }

    /// Same on-device cache `TransactionFormView` falls back to — needed
    /// here too so a pending-create row (Phase 11) can resolve its account/
    /// category names even on a cold, fully-offline start.
    private func cachedAccounts() -> [PublicSchema.AccountsWithBalancesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "accounts_with_balances") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.AccountsWithBalancesSelect].self, from: data)) ?? []
    }

    private func cachedCategories() -> [PublicSchema.CategoriesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "categories") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.CategoriesSelect].self, from: data)) ?? []
    }

    /// Routed through `session.outbox` (Phase 11), same as every write in
    /// `TransactionFormView` — an offline delete queues instead of erroring.
    private func delete(at offsets: IndexSet) async {
        var hadConflict = false
        for index in offsets {
            let transaction = transactions[index]
            guard let id = transaction.transactionId, let version = transaction.version else { continue }
            let result: OutboxSubmitResult
            if let groupId = transaction.transferGroupId, let siblingVersion = sibling(of: transaction)?.version {
                let payload = DeleteTransferPayload(
                    transferGroupId: groupId,
                    fromExpectedVersion: (transaction.amount ?? 0) < 0 ? Int(version) : Int(siblingVersion),
                    toExpectedVersion: (transaction.amount ?? 0) < 0 ? Int(siblingVersion) : Int(version)
                )
                result = await session.outbox.submitDeleteTransfer(payload)
            } else {
                let payload = DeleteTransactionPayload(id: id, expectedVersion: Int(version))
                result = await session.outbox.submitDeleteTransaction(payload)
            }
            if result == .conflict { hadConflict = true }
        }
        session.refresh.bump()
        if hadConflict { showConflictAlert = true }
    }
}

extension PublicSchema.TransactionsWithDetailsSelect: Identifiable {
    public var id: UUID { transactionId ?? UUID() }
}

/// `.task(id:)` needs an `Equatable` id — bundles the refresh token and the
/// filter together so either changing triggers exactly one reload, same
/// convention as `HomeLoadKey`.
private struct TransactionsLoadKey: Equatable {
    let token: Int
    let filter: TransactionFilter
}

/// Account/category/kind/date-range — every field optional, AND'd
/// together server-side (`TransactionRepository.fetchFiltered`). Search
/// lives on the list's own `.searchable`, not in this sheet.
private struct TransactionFilterView: View {
    @Binding var filter: TransactionFilter
    let accounts: [PublicSchema.AccountsWithBalancesSelect]
    let categories: [PublicSchema.CategoriesSelect]

    @Environment(\.dismiss) private var dismiss
    @State private var hasDateRange = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var through = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Account", selection: $filter.accountId) {
                        Text("Any").tag(UUID?.none)
                        ForEach(accounts, id: \.accountId) { account in
                            Text(account.name ?? "—").tag(account.accountId)
                        }
                    }
                }
                Section("Category") {
                    Picker("Category", selection: $filter.categoryId) {
                        Text("Any").tag(UUID?.none)
                        ForEach(categories, id: \.id) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                }
                Section("Kind") {
                    Picker("Kind", selection: $filter.kind) {
                        Text("Any").tag(String?.none)
                        Text("Expense").tag(String?.some("expense"))
                        Text("Income").tag(String?.some("income"))
                        Text("Transfer").tag(String?.some("transfer"))
                    }
                    .pickerStyle(.segmented)
                }
                Section("Date range") {
                    Toggle("Limit to a date range", isOn: $hasDateRange)
                    if hasDateRange {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("Through", selection: $through, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        filter = TransactionFilter(search: filter.search)
                        hasDateRange = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        filter.from = hasDateRange ? from : nil
                        filter.through = hasDateRange ? through : nil
                        dismiss()
                    }
                }
            }
        }
        .task {
            hasDateRange = filter.from != nil || filter.through != nil
            from = filter.from ?? from
            through = filter.through ?? through
        }
    }
}

private struct TransactionRow: View {
    let transaction: PublicSchema.TransactionsWithDetailsSelect

    private var isTransfer: Bool { transaction.kind == "transfer" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isTransfer ? "Transfer" : (transaction.categoryName ?? "—"))
                    .foregroundStyle(Color("TextPrimary"))
                Text(transaction.accountName ?? "—")
                    .font(.caption)
                    .foregroundStyle(Color("TextSecondary"))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // MoneyFormatter is the one place amounts render (Engineering
                // Principles) — the same call AccountsListView and
                // TransactionFormView use, not a per-screen formatter.
                Text(formattedAmount)
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                CurrencyConversionLabel(
                    nativeCurrency: transaction.currency,
                    amountBase: transaction.amountBase,
                    baseCurrency: transaction.baseCurrency,
                    baseMinorUnit: transaction.baseMinorUnit,
                    hasMissingRate: transaction.hasMissingRate ?? false
                )
            }
        }
    }

    private var formattedAmount: String {
        guard let currencyCode = transaction.currency, let minorUnit = transaction.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(transaction.amount, currency: currency)
    }

    private var amountColor: Color {
        guard let amount = transaction.amount, amount < 0 else { return Color("TextPrimary") }
        return Color("BrandPrimary")
    }
}
