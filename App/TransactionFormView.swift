import KeepoCore
import SwiftUI

/// One component for all three transaction kinds — per CLAUDE.md's
/// Engineering Principles, screens that handle the same concept share one
/// implementation rather than three near-duplicates. The received-amount
/// field appears only when the two accounts' currencies differ (spec
/// §Transaction Entry); for a same-currency transfer it's inferred and
/// never shown.
struct TransactionFormView: View {
    let session: SessionStore
    var onSaved: () -> Void

    private enum Kind: String, CaseIterable {
        case expense = "Expense"
        case income = "Income"
        case transfer = "Transfer"
    }

    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .expense
    @State private var accounts: [PublicSchema.AccountsWithBalancesSelect] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []

    @State private var selectedAccountId: UUID?
    @State private var selectedCategoryId: UUID?
    @State private var amountText = ""

    @State private var selectedToAccountId: UUID?
    @State private var receivedAmountText = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    private var fromAccount: PublicSchema.AccountsWithBalancesSelect? {
        accounts.first { $0.accountId == selectedAccountId }
    }

    private var toAccount: PublicSchema.AccountsWithBalancesSelect? {
        accounts.first { $0.accountId == selectedToAccountId }
    }

    private var needsReceivedAmount: Bool {
        guard kind == .transfer, let source = fromAccount, let destination = toAccount else { return false }
        return source.currency != destination.currency
    }

    private var categoriesForKind: [PublicSchema.CategoriesSelect] {
        let categoryKind: PublicSchema.CategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.kind == categoryKind }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Section(kind == .transfer ? "From" : "Account") {
                    accountPicker(selection: $selectedAccountId, excluding: nil)
                }

                if kind == .transfer {
                    Section("To") {
                        accountPicker(selection: $selectedToAccountId, excluding: selectedAccountId)
                    }
                } else {
                    Section("Category") {
                        Picker("Category", selection: $selectedCategoryId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(categoriesForKind, id: \.id) { category in
                                Text(category.name).tag(category.id as UUID?)
                            }
                        }
                    }
                }

                Section(kind == .transfer ? "Amount sent" : "Amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                }

                if needsReceivedAmount {
                    Section("Amount received") {
                        TextField("0.00", text: $receivedAmountText)
                            .keyboardType(.decimalPad)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("New \(kind.rawValue)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaveDisabled)
                }
            }
        }
        .task { await load() }
    }

    private func accountPicker(selection: Binding<UUID?>, excluding: UUID?) -> some View {
        Picker("Account", selection: selection) {
            Text("Select…").tag(UUID?.none)
            ForEach(accounts.filter { $0.accountId != excluding }, id: \.accountId) { account in
                Text(account.name ?? "—").tag(account.accountId)
            }
        }
    }

    private var isSaveDisabled: Bool {
        if isSaving || selectedAccountId == nil || amountText.isEmpty { return true }
        if kind == .transfer {
            if selectedToAccountId == nil { return true }
            if needsReceivedAmount && receivedAmountText.isEmpty { return true }
        } else if selectedCategoryId == nil {
            return true
        }
        return false
    }

    private func load() async {
        async let accountsResult = AccountRepository.fetchAllWithBalances(client: session.client)
        async let categoriesResult = CategoryRepository.fetchAll(client: session.client)
        accounts = (try? await accountsResult) ?? []
        categories = (try? await categoriesResult) ?? []
    }

    private func save() async {
        guard
            let userId = session.profile?.id,
            let accountId = selectedAccountId,
            let magnitude = AmountParser.parse(amountText),
            magnitude > 0
        else {
            errorMessage = "Enter a valid amount."
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            switch kind {
            case .expense, .income:
                try await saveLedgerTransaction(userId: userId, accountId: accountId, magnitude: magnitude)
            case .transfer:
                try await saveTransfer(accountId: accountId, magnitude: magnitude)
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = String(describing: error)
        }
        isSaving = false
    }

    private func saveLedgerTransaction(userId: UUID, accountId: UUID, magnitude: Decimal) async throws {
        guard let categoryId = selectedCategoryId, let account = fromAccount else {
            errorMessage = "Choose a category."
            return
        }
        // Sign applied here, once, from the kind the user picked — never
        // re-derived elsewhere (money rule: never re-sign in application
        // code beyond this single point; the DB's sign_matches_category_kind
        // CHECK is the actual backstop).
        let signedAmount = kind == .expense ? -magnitude : magnitude
        try await TransactionRepository.create(
            client: session.client,
            ownerId: userId,
            accountId: accountId,
            categoryId: categoryId,
            amount: signedAmount,
            currency: account.currency ?? "USD"
        )
    }

    private func saveTransfer(accountId: UUID, magnitude: Decimal) async throws {
        guard let toAccountId = selectedToAccountId else {
            errorMessage = "Choose a destination account."
            return
        }
        let receivedAmount = needsReceivedAmount ? AmountParser.parse(receivedAmountText) : nil
        if needsReceivedAmount && receivedAmount == nil {
            errorMessage = "Enter a valid received amount."
            return
        }
        try await TransactionRepository.createTransfer(
            client: session.client,
            fromAccountId: accountId,
            toAccountId: toAccountId,
            fromAmount: magnitude,
            toAmount: receivedAmount
        )
    }
}
