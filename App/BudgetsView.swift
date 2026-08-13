import KeepoCore
import SwiftUI

/// Reached from Settings, not a tab (same precedent as Recurring/
/// Household). Always shows the current calendar month — no rollover, no
/// month picker, matching the spec's own "calendar month, no rollover"
/// framing and `BudgetFormView`'s create-only-for-this-month scope.
struct BudgetsView: View {
    let session: SessionStore

    @State private var progress: [BudgetProgressLocal] = []
    @State private var isLoading = true
    @State private var isAddingBudget = false
    @State private var editingBudget: PublicSchema.BudgetsSelect?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if progress.isEmpty {
                Text("No budgets set for this month")
                    .foregroundStyle(Color.secondary)
            } else {
                List {
                    ForEach(progress, id: \.budgetId) { entry in
                        BudgetRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await openForEdit(entry) } }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
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
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingBudget = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingBudget) {
            BudgetFormView(session: session) {
                Task { await load() }
            }
        }
        .sheet(item: $editingBudget) { budget in
            BudgetFormView(session: session, mode: .edit(budget)) {
                Task { await load() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        errorMessage = nil
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        do {
            progress = try await session.dbQueue.read { database in
                try LocalMoneyConversion.budgetProgress(
                    database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency, periodMonth: Date()
                )
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    private func openForEdit(_ entry: BudgetProgressLocal) async {
        guard let ownerId = session.profile?.id else { return }
        let budgets = (try? await session.dbQueue.read { database in
            try LocalTableQueries.budgets(database, ownerId: ownerId.uuidString)
        }) ?? []
        editingBudget = budgets.first { $0.id.uuidString.lowercased() == entry.budgetId.lowercased() }
    }
}

extension PublicSchema.BudgetsSelect: Identifiable {}

private struct BudgetRow: View {
    let entry: BudgetProgressLocal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.categoryName ?? "Overall")
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(spentOfBudgetedText)
                    .monospacedDigit()
                    .foregroundStyle(isOverBudget ? Color.primary : Color.secondary)
            }
            ProgressView(value: fraction)
                .tint(isOverBudget ? Color.primary : Color.secondary)
        }
    }

    private var currencyInfo: CurrencyInfo { CurrencyInfo(code: entry.currency, minorUnit: 2) }

    private var spentOfBudgetedText: String {
        guard let spent = entry.spentE4, let budgeted = entry.budgetedE4 else { return "—" }
        let spentText = MoneyFormatter.format(spent, currency: currencyInfo)
        let budgetedText = MoneyFormatter.format(budgeted, currency: currencyInfo)
        return "\(spentText) of \(budgetedText)"
    }

    private var fraction: Double {
        guard let spent = entry.spentE4, let budgeted = entry.budgetedE4, budgeted > 0 else { return 0 }
        return min(Double(spent) / Double(budgeted), 1)
    }

    private var isOverBudget: Bool {
        guard let spent = entry.spentE4, let budgeted = entry.budgetedE4 else { return false }
        return spent > budgeted
    }
}
