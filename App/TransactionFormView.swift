import KeepoCore
import SwiftUI

/// One component for all three transaction kinds (CLAUDE.md's reuse
/// principle), for both create and edit. The received-amount field appears
/// only when the two accounts' currencies differ; inferred and hidden
/// otherwise.
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

    // Edit-mode versions the save call sends back for lost-update detection.
    @State private var editingId: UUID?
    @State private var editingFromVersion: Int?
    @State private var editingToVersion: Int?
    @State private var editingTransferGroupId: UUID?
    // created_by (who entered it) differs from the viewer on a shared account.
    @State private var addedByHouseholdMember = false

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showConflictAlert = false
    @State private var divergenceWarning: RateDivergence?
    @State private var transferDivergenceConfirmed = false

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
                    Text("Added by your household member").font(.footnote).foregroundStyle(Color.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isEditing ? "Edit \(kind.rawValue)" : "New \(kind.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { Image(systemName: "checkmark") }
                        .disabled(isSaveDisabled)
                }
            }
            .alert("This transaction changed elsewhere", isPresented: $showConflictAlert) {
                Button("OK") {}
            } message: {
                Text("Showing the latest version — review it and save again.")
            }
            .transferDivergenceAlert($divergenceWarning) {
                transferDivergenceConfirmed = true
                Task { await save() }
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

    /// Falls back to `TransactionFormCache` when the live fetch fails — an
    /// offline create otherwise has no way to populate its own pickers.
    private func load() async {
        async let accountsResult = withTimeout(seconds: 3) {
            try await AccountRepository.fetchAllWithBalances(client: session.client)
        }
        async let categoriesResult = withTimeout(seconds: 3) {
            try await CategoryRepository.fetchAll(client: session.client)
        }
        accounts = (try? await accountsResult) ?? TransactionFormCache.accounts(session: session)
        categories = (try? await categoriesResult) ?? TransactionFormCache.categories(session: session)

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
            if !showConflictAlert && divergenceWarning == nil {
                onSaved()
                dismiss()
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }

    /// Every write below goes through `session.outbox` (Phase 11), never
    /// `TransactionRepository` directly — an offline save queues instead of
    /// erroring; the app-wide stale-pending banner surfaces that, not this.
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
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: userId, accountId: accountId, categoryId: categoryId,
            amount: signedAmount, currency: account.currency ?? "USD", occurredAt: occurredAt
        )
        await session.outbox.submitCreateTransaction(payload)
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

        if !transferDivergenceConfirmed, needsReceivedAmount, let toAmount = receivedAmount,
           let source = fromAccount, let destination = toAccount,
           let sourceCurrency = source.currency, let destinationCurrency = destination.currency {
            divergenceWarning = await TransferDivergenceCheck.evaluate(
                client: session.client, sourceCurrency: sourceCurrency, destinationCurrency: destinationCurrency,
                fromAmount: magnitude, toAmount: toAmount, occurredAt: occurredAt
            )
            if divergenceWarning != nil { return }
        }
        transferDivergenceConfirmed = false

        let payload = CreateTransferPayload(
            fromId: UUID(), toId: UUID(), fromAccountId: accountId, toAccountId: toAccountId,
            fromAmount: magnitude, toAmount: receivedAmount, occurredAt: occurredAt
        )
        await session.outbox.submitCreateTransfer(payload)
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
        let payload = UpdateTransactionPayload(
            id: id, expectedVersion: expectedVersion, accountId: accountId, categoryId: categoryId,
            amount: signedAmount, currency: account.currency ?? "USD", occurredAt: occurredAt, merchantRaw: merchantRaw
        )
        let result = await session.outbox.submitUpdateTransaction(payload)
        if result == .conflict {
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
        let payload = UpdateTransferPayload(
            transferGroupId: transferGroupId, fromExpectedVersion: fromExpectedVersion,
            toExpectedVersion: toExpectedVersion, fromAmount: magnitude, toAmount: toAmount, occurredAt: occurredAt
        )
        let result = await session.outbox.submitUpdateTransfer(payload)
        if result == .conflict {
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
