import KeepoCore
import SwiftUI

struct TransactionsListView: View {
    let session: SessionStore

    @State private var store = DataStore<PublicSchema.TransactionsWithDetailsSelect>()
    @State private var isAddingTransaction = false
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var showConflictAlert = false
    @State private var deleteErrorMessage: String?
    @State private var filter = TransactionFilter()
    @State private var isFilterSheetPresented = false
    @State private var filterAccounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var filterCategories: [PublicSchema.CategoriesSelect] = []

    private var transactions: [PublicSchema.TransactionsWithDetailsSelect] { store.items }

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if store.isLoading {
                ProgressView()
            } else if transactions.isEmpty {
                Text("No transactions yet")
                    .foregroundStyle(Color("TextSecondary"))
            } else {
                List {
                    ForEach(transactions, id: \.transactionId) { transaction in
                        TransactionRow(transaction: transaction)
                            .contentShape(Rectangle())
                            .onTapGesture { editingTransaction = transaction }
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets) }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = store.errorMessage ?? deleteErrorMessage {
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
        .sheet(isPresented: $isFilterSheetPresented) {
            TransactionFilterView(filter: $filter, accounts: filterAccounts, categories: filterCategories)
        }
        .alert("This transaction changed elsewhere", isPresented: $showConflictAlert) {
            Button("OK") {}
        } message: {
            Text("The list has been refreshed with the latest version.")
        }
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

    private func load() async {
        if filterAccounts.isEmpty {
            filterAccounts = (try? await AccountRepository.fetchAllWithBalances(client: session.client)) ?? []
        }
        if filterCategories.isEmpty {
            filterCategories = (try? await CategoryRepository.fetchAll(client: session.client)) ?? []
        }
        await store.load { try await TransactionRepository.fetchFiltered(client: session.client, filter: filter) }
    }

    private func delete(at offsets: IndexSet) async {
        var hadConflict = false
        deleteErrorMessage = nil
        for index in offsets {
            let transaction = transactions[index]
            guard let id = transaction.transactionId, let version = transaction.version else { continue }
            do {
                let deleted: Bool
                if let groupId = transaction.transferGroupId, let siblingVersion = sibling(of: transaction)?.version {
                    deleted = try await TransactionRepository.deleteTransfer(
                        client: session.client,
                        transferGroupId: groupId,
                        fromExpectedVersion: (transaction.amount ?? 0) < 0 ? Int(version) : Int(siblingVersion),
                        toExpectedVersion: (transaction.amount ?? 0) < 0 ? Int(siblingVersion) : Int(version)
                    )
                } else {
                    deleted = try await TransactionRepository.delete(
                        client: session.client, id: id, expectedVersion: Int(version)
                    )
                }
                if !deleted { hadConflict = true }
            } catch {
                deleteErrorMessage = String(describing: error)
            }
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
