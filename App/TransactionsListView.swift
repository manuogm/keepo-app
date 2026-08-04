import KeepoCore
import SwiftUI

struct TransactionsListView: View {
    let session: SessionStore

    @State private var transactions: [PublicSchema.TransactionsWithDetailsSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isAddingTransaction = false

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
        .task { await load() }
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
        for index in offsets {
            guard let id = transactions[index].transactionId else { continue }
            do {
                try await TransactionRepository.softDelete(client: session.client, transactionId: id)
            } catch {
                errorMessage = String(describing: error)
            }
        }
        await load()
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
