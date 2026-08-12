import KeepoCore
import SwiftUI

/// Create and edit share one form, mirroring `AccountFormView`/
/// `TransactionFormView`. No transfer kind — `recurring_rules` has a single
/// `account_id`/`category_id` pair, matching app-architecture.md §3;
/// recurring transfers aren't in the spec.
struct RecurringRuleFormView: View {
    let session: SessionStore
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        case edit(PublicSchema.RecurringRulesSelect)
    }

    private enum Kind: String, CaseIterable {
        case expense = "Expense"
        case income = "Income"
    }

    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .expense
    @State private var accounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []

    @State private var selectedAccountId: UUID?
    @State private var selectedCategoryId: UUID?
    @State private var amountText = ""
    @State private var frequency: PublicSchema.RecurringFrequency = .monthly
    @State private var nextDueAt = Date()
    @State private var active = true

    @State private var editingId: UUID?

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var selectedAccount: PublicSchema.AccountsWithBalancesSelect? {
        accounts.first { $0.accountId == selectedAccountId }
    }

    private var categoriesForKind: [PublicSchema.CategoriesSelect] {
        let categoryKind: PublicSchema.CategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.kind == categoryKind }
    }

    private var minorUnit: Int {
        Int(selectedAccount?.minorUnit ?? 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView()
                } else {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Section("Account") {
                        Picker("Account", selection: $selectedAccountId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(accounts.filter { $0.kind == .ledger }, id: \.accountId) { account in
                                Text(account.name ?? "—").tag(account.accountId)
                            }
                        }
                    }

                    Section("Category") {
                        Picker("Category", selection: $selectedCategoryId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(categoriesForKind, id: \.id) { category in
                                Text(category.name).tag(category.id as UUID?)
                            }
                        }
                    }

                    Section("Amount") {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                    }

                    Section("Frequency") {
                        Picker("Frequency", selection: $frequency) {
                            Text("Weekly").tag(PublicSchema.RecurringFrequency.weekly)
                            Text("Monthly").tag(PublicSchema.RecurringFrequency.monthly)
                            Text("Yearly").tag(PublicSchema.RecurringFrequency.yearly)
                        }
                    }

                    Section("Next due") {
                        DatePicker("Next due", selection: $nextDueAt, displayedComponents: [.date])
                            .labelsHidden()
                    }

                    if isEditing {
                        Toggle("Active", isOn: $active)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Recurring Rule" : "New Recurring Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
        .task { await load() }
    }

    private var isSaveDisabled: Bool {
        isLoading || isSaving || selectedAccountId == nil || selectedCategoryId == nil || amountText.isEmpty
    }

    private func load() async {
        async let accountsResult = AccountRepository.fetchAllWithBalances(client: session.client)
        async let categoriesResult = CategoryRepository.fetchAll(client: session.client)
        accounts = (try? await accountsResult) ?? []
        categories = (try? await categoriesResult) ?? []

        if case .edit(let rule) = mode {
            apply(rule)
        }
        isLoading = false
    }

    private func apply(_ rule: PublicSchema.RecurringRulesSelect) {
        editingId = rule.id
        selectedAccountId = rule.accountId
        selectedCategoryId = rule.categoryId
        kind = rule.amount < 0 ? .expense : .income
        amountText = AmountFormatter.editableString(rule.amount, minorUnit: minorUnit)
        frequency = rule.frequency
        nextDueAt = PostgresDate.dateOnly(from: rule.nextDueAt) ?? Date()
        active = rule.active
    }

    private func save() async {
        guard let magnitude = AmountParser.parse(amountText), let accountId = selectedAccountId,
              let categoryId = selectedCategoryId else {
            errorMessage = "Fill in every field."
            return
        }
        let signedAmount = kind == .expense ? -magnitude.magnitude : magnitude.magnitude

        isSaving = true
        errorMessage = nil
        do {
            switch mode {
            case .create:
                guard let ownerId = session.profile?.id else { return }
                try await RecurringRuleRepository.create(
                    client: session.client, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                    amount: signedAmount, currency: selectedAccount?.currency ?? "EUR", frequency: frequency,
                    nextDueAt: nextDueAt
                )
            case .edit:
                guard let id = editingId else { return }
                try await RecurringRuleRepository.update(
                    client: session.client, id: id, accountId: accountId, categoryId: categoryId,
                    amount: signedAmount, currency: selectedAccount?.currency ?? "EUR", frequency: frequency,
                    nextDueAt: nextDueAt, active: active
                )
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }
}
