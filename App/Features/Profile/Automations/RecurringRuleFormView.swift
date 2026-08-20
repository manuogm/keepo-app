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
        /// "Make recurring", pushed from a transaction the user is already
        /// looking at. Identical to `.create` in every way that reaches the
        /// server — it only spares them retyping the account, category and
        /// amount that are on screen one view back.
        case createSeeded(
            accountId: UUID?, categoryId: UUID?, amountText: String, isIncome: Bool, startingOn: Date
        )
        case edit(PublicSchema.RecurringRulesSelect)
    }

    /// `false` when pushed onto an existing `NavigationStack` (the
    /// transaction form's "Make recurring") rather than presented as its
    /// own sheet — nesting a second stack inside one breaks the back button
    /// and the swipe-to-go-back gesture alike. Same pattern as
    /// `AccountFormView`.
    var embedInNavigationStack = true

    private enum Kind: String, CaseIterable {
        case expense = "Expense"
        case income = "Income"
    }

    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .expense
    @State private var accounts: [LocalAccountRow] = []
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

    private var selectedAccount: LocalAccountRow? {
        accounts.first { $0.id == selectedAccountId }
    }

    private var categoriesForKind: [PublicSchema.CategoriesSelect] {
        let categoryKind: PublicSchema.CategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.kind == categoryKind }
    }

    private var minorUnit: Int {
        selectedAccount?.currencyInfo.minorUnit ?? 2
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack { formContent }
        } else {
            formContent
        }
    }

    @ViewBuilder
    private var formContent: some View {
        Group {
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
                            ForEach(accounts) { account in
                                Text(account.name).tag(UUID?.some(account.id))
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
                    .tint(.green)
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
                if embedInNavigationStack {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
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
        if let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency {
            let loaded = try? await session.dbQueue.read { database in
                (
                    try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency),
                    try LocalTableQueries.categories(database, ownerId: ownerId.uuidString)
                )
            }
            accounts = loaded?.0 ?? []
            categories = loaded?.1 ?? []
        }

        switch mode {
        case .edit(let rule):
            apply(rule)
        case .createSeeded(let accountId, let categoryId, let amountText, let isIncome, let startingOn):
            selectedAccountId = accountId
            selectedCategoryId = categoryId
            // `minorUnit` reads through `selectedAccount`, so this has to
            // come after the account is set — the amount is already a
            // locale-correct editable string from the transaction form, so
            // it is carried across verbatim rather than re-formatted.
            self.amountText = amountText
            kind = isIncome ? .income : .expense
            nextDueAt = startingOn
        case .create:
            break
        }
        isLoading = false
    }

    private func apply(_ rule: PublicSchema.RecurringRulesSelect) {
        editingId = rule.id
        selectedAccountId = rule.accountId
        selectedCategoryId = rule.categoryId
        kind = rule.amountE4 < 0 ? .expense : .income
        amountText = AmountFormatter.editableString(rule.amountE4, minorUnit: minorUnit)
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
        let unsignedMagnitude = abs(magnitude)
        let signedAmountE4 = kind == .expense ? -unsignedMagnitude : unsignedMagnitude

        isSaving = true
        errorMessage = nil
        do {
            switch mode {
            case .create, .createSeeded:
                guard let ownerId = session.profile?.id else { return }
                try await RecurringRuleRepository.create(
                    client: session.client, ownerId: ownerId, accountId: accountId, categoryId: categoryId,
                    amountE4: signedAmountE4, currency: selectedAccount?.currency ?? "EUR", frequency: frequency,
                    nextDueAt: nextDueAt
                )
            case .edit:
                guard let id = editingId else { return }
                try await RecurringRuleRepository.update(
                    client: session.client, id: id, accountId: accountId, categoryId: categoryId,
                    amountE4: signedAmountE4, currency: selectedAccount?.currency ?? "EUR", frequency: frequency,
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
