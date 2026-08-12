import KeepoCore
import SwiftUI

struct TransactionsListView: View {
    let session: SessionStore

    // MARK: - Transactions state

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

    // MARK: - Needs-review inbox state

    // Not `private` — read/written from TransactionsListView+NeedsReview.swift,
    // an extension in a different file (kept there purely for file-length).
    @State var reviewStore = DataStore<PublicSchema.NeedsReviewSelect>()
    @State var reviewCurrencies: [String: Int] = [:]
    @State var reviewActionError: String?
    @State var reviewEditingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State var showReviewEditing = false
    @State var reviewMappingCard: PublicSchema.NeedsReviewSelect?
    @State var showReviewCardMapping = false

    // MARK: - Computed

    private var transactions: [PublicSchema.TransactionsWithDetailsSelect] { store.items }

    private var reviewDisplayItems: [PublicSchema.NeedsReviewSelect] {
        reviewStore.items.filter { $0.kind != "reconciliation_gap" }
    }

    /// Pending *creates* only (Phase 11) — resolved against whatever
    /// accounts/categories are already loaded for the filter sheet, since
    /// those already carry names and are refreshed the same way this
    /// screen refreshes everything else.
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

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if store.isLoading && reviewStore.isLoading {
                ProgressView()
            } else if transactions.isEmpty && pendingRows.isEmpty && reviewDisplayItems.isEmpty {
                Text("No transactions yet")
                    .foregroundStyle(Color.secondary)
            } else {
                List {
                    if let asOf = store.asOf {
                        Text("Showing data as of \(asOf.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }

                    // Needs-review inbox — most actionable items first
                    if !reviewDisplayItems.isEmpty {
                        Section("Needs Review") {
                            ForEach(reviewDisplayItems, id: \.itemId) { item in
                                reviewRow(item)
                            }
                        }
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

            if let errorMessage = store.errorMessage ?? reviewActionError {
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
            ToolbarItem(placement: .topBarLeading) {
                PrivacyToggleButton(session: session)
            }
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
        .navigationDestination(isPresented: $showReviewEditing) {
            if let reviewEditingTransaction {
                TransactionFormView(
                    session: session,
                    mode: .edit(reviewEditingTransaction, sibling: nil)
                ) {
                    session.refresh.bump()
                }
            }
        }
        .sheet(isPresented: $showReviewCardMapping) {
            if let reviewMappingCard {
                MapCardSheet(session: session, item: reviewMappingCard) {
                    session.refresh.bump()
                }
            }
        }
        .task { store.restore(from: session.payloadCache) }
        .task(id: TransactionsLoadKey(token: session.refresh.token, filter: filter)) { await load() }
    }

    // MARK: - Transaction helpers

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
        if reviewCurrencies.isEmpty {
            let currencies = (try? await CurrencyRepository.fetchAll(client: session.client)) ?? []
            reviewCurrencies = Dictionary(uniqueKeysWithValues: currencies.map { ($0.code, Int($0.minorUnit)) })
        }
        await reviewStore.load { try await NeedsReviewRepository.fetchAll(client: session.client) }
        // Caching only applies to the default, unfiltered page — a filtered
        // view has no offline fallback beyond whatever's already shown.
        await store.load(
            { try await TransactionRepository.fetchFiltered(client: session.client, filter: filter) },
            cache: filter.isEmpty ? session.payloadCache : nil
        )
    }

    private func cachedAccounts() -> [PublicSchema.AccountsWithBalancesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "accounts_with_balances") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.AccountsWithBalancesSelect].self, from: data)) ?? []
    }

    private func cachedCategories() -> [PublicSchema.CategoriesSelect] {
        guard let (data, _) = session.payloadCache.load(key: "categories") else { return [] }
        return (try? JSONDecoder().decode([PublicSchema.CategoriesSelect].self, from: data)) ?? []
    }

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

// MARK: - Supporting types

extension PublicSchema.TransactionsWithDetailsSelect: Identifiable {
    public var id: UUID { transactionId ?? UUID() }
}

private struct TransactionsLoadKey: Equatable {
    let token: Int
    let filter: TransactionFilter
}

private struct TransactionRow: View {
    let transaction: PublicSchema.TransactionsWithDetailsSelect

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    private var isTransfer: Bool { transaction.kind == "transfer" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isTransfer ? "Transfer" : (transaction.categoryName ?? "—"))
                    .foregroundStyle(Color.primary)
                Text(transaction.accountName ?? "—")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(isPrivacyMode ? "••••" : formattedAmount)
                    .monospacedDigit()
                    .foregroundStyle(amountColor)
                if !isPrivacyMode {
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
    }

    private var formattedAmount: String {
        guard let currencyCode = transaction.currency, let minorUnit = transaction.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: currencyCode, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(transaction.amount, currency: currency)
    }

    private var amountColor: Color {
        guard let amount = transaction.amount, amount < 0 else { return Color.primary }
        return Color.primary
    }
}
