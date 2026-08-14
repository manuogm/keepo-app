import KeepoCore
import SwiftUI

/// Split out of TransactionsListView.swift purely to keep that file under
/// the project's file-length lint threshold — no dependency on
/// TransactionsListView's own state beyond the filter binding it's handed.
/// Date range is no longer this sheet's job — the period picker atop
/// TransactionsListView owns that now; this is account/category/kind only.
struct TransactionFilterView: View {
    @Binding var filter: TransactionFilter
    let accounts: [LocalAccountRow]
    let categories: [PublicSchema.CategoriesSelect]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Account", selection: $filter.accountId) {
                        Text("Any").tag(UUID?.none)
                        ForEach(accounts) { account in
                            Text(account.name).tag(UUID?.some(account.id))
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
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        filter = TransactionFilter(search: filter.search)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
