import KeepoCore
import SwiftUI

struct TransactionsListView: View {
    let session: SessionStore

    @State private var transactions: [PublicSchema.TransactionsWithDetailsSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isAddingTransaction = false
    @State private var editingTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State private var showConflictAlert = false

    var body: some View {
        ZStack {
            Color("BGCanvas").ignoresSafeArea()

            if isLoading {
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
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
        .navigationTitle("Transactions")
        .toolbar {
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
                Task { await load() }
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            TransactionFormView(session: session, mode: .edit(transaction, sibling: sibling(of: transaction))) {
                Task { await load() }
            }
        }
        .alert("This transaction changed elsewhere", isPresented: $showConflictAlert) {
            Button("OK") {}
        } message: {
            Text("The list has been refreshed with the latest version.")
        }
        .task { await load() }
    }

    private func sibling(
        of transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.TransactionsWithDetailsSelect? {
        guard let groupId = transaction.transferGroupId else { return nil }
        return transactions.first { $0.transferGroupId == groupId && $0.transactionId != transaction.transactionId }
    }

    private func load() async {
        do {
            transactions = try await TransactionRepository.fetchAll(client: session.client)
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    private func delete(at offsets: IndexSet) async {
        var hadConflict = false
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
                errorMessage = String(describing: error)
            }
        }
        await load()
        if hadConflict { showConflictAlert = true }
    }
}

extension PublicSchema.TransactionsWithDetailsSelect: Identifiable {
    public var id: UUID { transactionId ?? UUID() }
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
            // MoneyFormatter is the one place amounts render (Engineering
            // Principles) — the same call AccountsListView and
            // TransactionFormView use, not a per-screen formatter.
            Text(formattedAmount)
                .monospacedDigit()
                .foregroundStyle(amountColor)
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
