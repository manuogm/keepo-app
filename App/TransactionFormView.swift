import KeepoCore
import SwiftUI

/// One component for all three transaction kinds — per CLAUDE.md's
/// Engineering Principles, screens that handle the same concept share one
/// implementation rather than three near-duplicates. Used for both create
/// and edit (app-architecture.md §2). The received-amount field appears
/// only when the two accounts' currencies differ (spec §Transaction Entry);
/// for a same-currency transfer it's inferred and never shown.
struct TransactionFormView: View {
    let session: SessionStore
    /// `.create` for a new transaction; `.edit` pre-fills every field from
    /// an existing row (plus its sibling leg, for a transfer) and locks the
    /// kind — changing kind is delete-and-recreate, never an in-place edit
    /// (app-architecture.md §2).
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        case edit(PublicSchema.TransactionsWithDetailsSelect, sibling: PublicSchema.TransactionsWithDetailsSelect?)
    }

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
    @State private var occurredAt = Date()
    @State private var merchantRaw: String?

    @State private var selectedToAccountId: UUID?
    @State private var receivedAmountText = ""

    // Populated in edit mode: the version(s) the save call sends back so the
    // DB can detect a lost update. A transfer needs both legs' versions and
    // their shared transfer_group_id.
    @State private var editingId: UUID?
    @State private var editingFromVersion: Int?
    @State private var editingToVersion: Int?
    @State private var editingTransferGroupId: UUID?
    // created_by (who entered it) differs from the viewer on a shared account.
    @State private var addedByHouseholdMember = false

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showConflictAlert = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

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
                .disabled(isEditing)

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

                Section("Date") {
                    DatePicker("Date", selection: $occurredAt, displayedComponents: [.date])
                        .labelsHidden()
                }

                if addedByHouseholdMember {
                    Text("Added by your household member").font(.footnote).foregroundStyle(Color("TextSecondary"))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isEditing ? "Edit \(kind.rawValue)" : "New \(kind.rawValue)")
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
            .alert("This transaction changed elsewhere", isPresented: $showConflictAlert) {
                Button("OK") {}
            } message: {
                Text("Showing the latest version — review it and save again.")
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

        if case .edit(let transaction, let sibling) = mode {
            apply(transaction: transaction, sibling: sibling)
        }
    }

    /// Shared by the initial edit-mode prefill and by a post-conflict
    /// reload — both are "populate the form from a server row."
    private func apply(
        transaction: PublicSchema.TransactionsWithDetailsSelect,
        sibling: PublicSchema.TransactionsWithDetailsSelect?
    ) {
        kind = {
            switch transaction.kind {
            case "income": return .income
            case "transfer": return .transfer
            default: return .expense
            }
        }()

        if let occurredAtString = transaction.occurredAt,
           let date = PostgresDate.date(fromTimestamp: occurredAtString) {
            occurredAt = date
        }

        addedByHouseholdMember = transaction.createdBy != nil && transaction.createdBy != session.profile?.id

        switch kind {
        case .expense, .income:
            editingId = transaction.transactionId
            editingFromVersion = transaction.version.map(Int.init)
            selectedAccountId = transaction.accountId
            selectedCategoryId = transaction.categoryId
            merchantRaw = transaction.merchantRaw
            if let amount = transaction.amount {
                amountText = AmountFormatter.editableString(amount, minorUnit: Int(transaction.minorUnit ?? 2))
            }
        case .transfer:
            let legs = [transaction, sibling].compactMap { $0 }
            guard
                let from = legs.first(where: { ($0.amount ?? 0) < 0 }),
                let destination = legs.first(where: { ($0.amount ?? 0) > 0 })
            else { return }
            editingTransferGroupId = transaction.transferGroupId
            editingFromVersion = from.version.map(Int.init)
            editingToVersion = destination.version.map(Int.init)
            selectedAccountId = from.accountId
            selectedToAccountId = destination.accountId
            if let amount = from.amount {
                amountText = AmountFormatter.editableString(amount, minorUnit: Int(from.minorUnit ?? 2))
            }
            if from.currency != destination.currency, let amount = destination.amount {
                receivedAmountText = AmountFormatter.editableString(amount, minorUnit: Int(destination.minorUnit ?? 2))
            }
        }
    }
}

extension TransactionFormView {
    fileprivate func save() async {
        guard
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
            switch (isEditing, kind) {
            case (false, .expense), (false, .income):
                try await saveLedgerTransaction(accountId: accountId, magnitude: magnitude)
            case (false, .transfer):
                try await saveTransfer(accountId: accountId, magnitude: magnitude)
            case (true, .expense), (true, .income):
                try await updateLedgerTransaction(accountId: accountId, magnitude: magnitude)
            case (true, .transfer):
                try await updateTransfer(magnitude: magnitude)
            }
            if !showConflictAlert {
                onSaved()
                dismiss()
            }
        } catch {
            errorMessage = String(describing: error)
        }
        isSaving = false
    }

    fileprivate func saveLedgerTransaction(accountId: UUID, magnitude: Decimal) async throws {
        guard let userId = session.profile?.id, let categoryId = selectedCategoryId, let account = fromAccount else {
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
            currency: account.currency ?? "USD",
            occurredAt: occurredAt
        )
    }

    fileprivate func saveTransfer(accountId: UUID, magnitude: Decimal) async throws {
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
            toAmount: receivedAmount,
            occurredAt: occurredAt
        )
    }

    fileprivate func updateLedgerTransaction(accountId: UUID, magnitude: Decimal) async throws {
        guard
            let categoryId = selectedCategoryId,
            let account = fromAccount,
            let id = editingId,
            let expectedVersion = editingFromVersion
        else {
            errorMessage = "Choose a category."
            return
        }
        let signedAmount = kind == .expense ? -magnitude : magnitude
        let result = try await TransactionRepository.update(
            client: session.client,
            id: id,
            expectedVersion: expectedVersion,
            accountId: accountId,
            categoryId: categoryId,
            amount: signedAmount,
            currency: account.currency ?? "USD",
            occurredAt: occurredAt,
            merchantRaw: merchantRaw
        )
        switch result {
        case .saved:
            break
        case .conflict:
            await reloadAfterConflict()
        }
    }

    fileprivate func updateTransfer(magnitude: Decimal) async throws {
        guard
            let transferGroupId = editingTransferGroupId,
            let fromExpectedVersion = editingFromVersion,
            let toExpectedVersion = editingToVersion
        else {
            errorMessage = "Missing transfer details."
            return
        }
        let receivedAmount = needsReceivedAmount ? AmountParser.parse(receivedAmountText) : magnitude
        guard let toAmount = receivedAmount, toAmount > 0 else {
            errorMessage = "Enter a valid received amount."
            return
        }
        let result = try await TransactionRepository.updateTransfer(
            client: session.client,
            transferGroupId: transferGroupId,
            fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion,
            fromAmount: magnitude,
            toAmount: toAmount,
            occurredAt: occurredAt
        )
        switch result {
        case .saved:
            break
        case .conflict:
            await reloadAfterConflict()
        }
    }

    /// A stale version means someone else changed this transaction since it
    /// loaded — reload the current row from the server, repopulate the
    /// form with it, and let the user decide whether to reapply their edit,
    /// rather than silently discarding what they typed or clobbering the
    /// newer data.
    fileprivate func reloadAfterConflict() async {
        guard let all = try? await TransactionRepository.fetchAll(client: session.client) else {
            showConflictAlert = true
            return
        }
        let groupId = editingTransferGroupId
        let id = editingId
        let transaction = all.first {
            $0.transactionId == id || ($0.transferGroupId != nil && $0.transferGroupId == groupId)
        }
        let sibling = groupId.flatMap { group in
            all.first { $0.transferGroupId == group && $0.transactionId != transaction?.transactionId }
        }
        if let transaction {
            apply(transaction: transaction, sibling: sibling)
        }
        showConflictAlert = true
    }
}
