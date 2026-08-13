import KeepoCore
import SwiftUI

/// Reads straight off the local GRDB mirror (Phase L6) — no server round
/// trip, no payload cache. `Outbox`'s optimistic write-through means a
/// queued-but-unsynced create/edit/delete is already reflected in the same
/// `transactions` rows this screen queries, so there is no separate
/// "pending" row/marker to overlay anymore — a transaction created offline
/// simply appears in Recent like any other, the moment it's submitted.
struct TransactionsListView: View {
    let session: SessionStore

    // MARK: - Transactions state

    // Not `private` — read/written from TransactionsListView+Loading.swift,
    // an extension in a different file (kept there purely for file-length,
    // same reasoning as the Needs-review state below).
    @State var transactions: [PublicSchema.TransactionsWithDetailsSelect] = []
    @State var isLoading = true
    @State var loadErrorMessage: String?
    @State var filterAccounts: [LocalAccountRow] = []
    @State var filterCategories: [PublicSchema.CategoriesSelect] = []
    @State var showConflictAlert = false
    @State private var isAddingTransaction = false
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var recurringEditChoice: PublicSchema.TransactionsWithDetailsSelect?
    @State private var editingRecurringRule: PublicSchema.RecurringRulesSelect?
    @State var filter = TransactionFilter()
    @State private var isFilterSheetPresented = false

    // MARK: - Needs-review inbox state

    // Not `private` — read/written from TransactionsListView+NeedsReview.swift,
    // an extension in a different file (kept there purely for file-length).
    @State var reviewItems: [PublicSchema.NeedsReviewSelect] = []
    @State var reviewCurrencies: [String: Int] = [:]
    @State var reviewActionError: String?
    @State var reviewEditingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State var showReviewEditing = false
    @State var reviewMappingCard: PublicSchema.NeedsReviewSelect?
    @State var showReviewCardMapping = false

    // MARK: - Computed

    /// The default page is already ordered newest-first (Phase 6's keyset
    /// index) — this is just the head of it. The full history lives one
    /// tap away in `TransactionRegisterView`, grouped by day with its own
    /// period navigator.
    private let recentLimit = 10

    private var recentTransactions: [PublicSchema.TransactionsWithDetailsSelect] {
        Array(transactions.prefix(recentLimit))
    }

    private func category(
        for transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.CategoriesSelect? {
        filterCategories.first { $0.id == transaction.categoryId }
    }

    private var reviewDisplayItems: [PublicSchema.NeedsReviewSelect] {
        reviewItems.filter { $0.kind != "reconciliation_gap" }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if transactions.isEmpty && reviewDisplayItems.isEmpty {
                Text("No transactions yet")
                    .foregroundStyle(Color.secondary)
            } else {
                List {
                    // Needs-review inbox — most actionable items first
                    if !reviewDisplayItems.isEmpty {
                        Section("Needs Review") {
                            ForEach(reviewDisplayItems, id: \.itemId) { item in
                                reviewRow(item)
                            }
                        }
                    }

                    Section {
                        ForEach(recentTransactions, id: \.transactionId) { transaction in
                            TransactionRow(transaction: transaction, category: category(for: transaction))
                            .contentShape(Rectangle())
                            .onTapGesture { handleTap(on: transaction) }
                        }
                        .onDelete { offsets in
                            Task { await delete(at: offsets, in: recentTransactions) }
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            NavigationLink {
                                TransactionRegisterView(session: session)
                            } label: {
                                Text("See All")
                            }
                            .textCase(nil)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }

            if let errorMessage = loadErrorMessage ?? reviewActionError {
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
        .task(id: TransactionsLoadKey(token: session.refresh.token, filter: filter)) { await load() }
    }

    // MARK: - Transaction helpers

    private var searchBinding: Binding<String> {
        Binding(get: { filter.search ?? "" }, set: { filter.search = $0.isEmpty ? nil : $0 })
    }

    private var filterIconName: String {
        filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
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
}
