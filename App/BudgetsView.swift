import KeepoCore
import SwiftUI

/// Reached from Settings, not a tab (same precedent as Recurring/
/// Household). Always shows the current calendar month — no rollover, no
/// month picker, matching the spec's own "calendar month, no rollover"
/// framing and `BudgetFormView`'s create-only-for-this-month scope.
struct BudgetsView: View {
    let session: SessionStore

    @State private var progress: [BudgetProgress] = []
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
        do {
            progress = try await BudgetRepository.fetchProgress(client: session.client, periodMonth: Date())
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }

    private func openForEdit(_ entry: BudgetProgress) async {
        let budgets = (try? await BudgetRepository.fetchAll(client: session.client)) ?? []
        editingBudget = budgets.first { $0.id == entry.budgetId }
    }
}

extension PublicSchema.BudgetsSelect: Identifiable {}

private struct BudgetRow: View {
    let entry: BudgetProgress

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
        guard let spent = entry.spent, let budgeted = entry.budgeted else { return "—" }
        let spentText = MoneyFormatter.format(spent, currency: currencyInfo)
        let budgetedText = MoneyFormatter.format(budgeted, currency: currencyInfo)
        return "\(spentText) of \(budgetedText)"
    }

    private var fraction: Double {
        guard let spent = entry.spent, let budgeted = entry.budgeted, budgeted > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: spent / budgeted).doubleValue, 1)
    }

    private var isOverBudget: Bool {
        guard let spent = entry.spent, let budgeted = entry.budgeted else { return false }
        return spent > budgeted
    }
}
