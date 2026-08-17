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

    // Not `private` — read from TransactionFormView+Delete.swift, an
    // extension in a different file (kept there purely for file-length).
    @Environment(\.dismiss) var dismiss

    @State private var kind: Kind = .expense
    @State private var accounts: [LocalAccountRow] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []

    @State private var selectedAccountId: UUID?
    @State private var selectedCategoryId: UUID?
    @State private var amountText = ""
    // Not `private` — read from TransactionFormView+Transfer.swift.
    @State var occurredAt = Date()
    @State private var merchantRaw: String?
    @State private var notes = ""

    // Not `private` — read from TransactionFormView+Transfer.swift.
    @State var selectedToAccountId: UUID?
    // Not `private` — read from TransactionFormView+Transfer.swift.
    @State var receivedAmountText = ""

    // Edit-mode versions the save call sends back for lost-update detection.
    @State var editingId: UUID?
    @State var editingFromVersion: Int?
    @State var editingToVersion: Int?
    @State var editingTransferGroupId: UUID?
    // created_by (who entered it) differs from the viewer on a shared account.
    @State private var addedByHouseholdMember = false

    // Set from the row being reviewed — a pending, captured transaction —
    // so Save both applies any edit and confirms it in one tap, per the
    // Needs Review flow's "review, then it's gone" contract.
    @State private var isConfirmingCapture = false

    @State var isSaving = false
    @State var errorMessage: String?
    // Not `private` — read/written from TransactionFormView+Transfer.swift.
    @State var divergenceWarning: RateDivergence?
    @State var transferDivergenceConfirmed = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    // Not `private` — read from TransactionFormView+Transfer.swift.
    var fromAccount: LocalAccountRow? {
        accounts.first { $0.id == selectedAccountId }
    }

    var toAccount: LocalAccountRow? {
        accounts.first { $0.id == selectedToAccountId }
    }

    // Not `private` — read from TransactionFormView+Transfer.swift.
    var needsReceivedAmount: Bool {
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

                if kind != .transfer {
                    Section("Notes") {
                        TextField("Add a note…", text: $notes, axis: .vertical)
                    }
                }

                if addedByHouseholdMember {
                    Text("Added by your household member").font(.footnote).foregroundStyle(Color.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                // Standard practice whenever a swipe-action exists elsewhere
                // for the same object (the list's swipe-to-delete) — not
                // every user discovers the gesture.
                if isEditing {
                    Section {
                        Button("Delete Transaction", role: .destructive) {
                            Task { await deleteTransaction() }
                        }
                        .disabled(isSaving)
                    }
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
            ForEach(accounts.filter { $0.id != excluding }) { account in
                Text(account.name).tag(UUID?.some(account.id))
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

    /// Reads straight off the local GRDB mirror (Phase L6) — always
    /// current, never needs a cache-fallback chain the way a network fetch
    /// used to.
    private func load() async {
        if let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency {
            let loaded = try? await session.dbQueue.read { database in
                (
                    try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency),
                    try LocalTableQueries.categories(database)
                )
            }
            accounts = loaded?.0 ?? []
            categories = loaded?.1 ?? []
        }

        if case .edit(let transaction, let sibling) = mode {
            apply(transaction: transaction, sibling: sibling)
        }
    }

    /// Populates the form from a server row — the initial edit-mode prefill.
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
            notes = transaction.notes ?? ""
            isConfirmingCapture = transaction.status == .pending && transaction.source == .capture
            if let amount = transaction.amountE4 {
                amountText = AmountFormatter.editableString(amount, minorUnit: Int(transaction.minorUnit ?? 2))
            }
        case .transfer:
            let legs = [transaction, sibling].compactMap { $0 }
            guard
                let from = legs.first(where: { ($0.amountE4 ?? 0) < 0 }),
                let destination = legs.first(where: { ($0.amountE4 ?? 0) > 0 })
            else { return }
            editingTransferGroupId = transaction.transferGroupId
            editingFromVersion = from.version.map(Int.init)
            editingToVersion = destination.version.map(Int.init)
            selectedAccountId = from.accountId
            selectedToAccountId = destination.accountId
            if let amount = from.amountE4 {
                amountText = AmountFormatter.editableString(amount, minorUnit: Int(from.minorUnit ?? 2))
            }
            if from.currency != destination.currency, let amount = destination.amountE4 {
                receivedAmountText = AmountFormatter.editableString(amount, minorUnit: Int(destination.minorUnit ?? 2))
            }
        }
    }
}

extension TransactionFormView {
    fileprivate func save() async {
        guard let accountId = selectedAccountId else {
            errorMessage = "Choose an account."
            return
        }
        guard let magnitude = AmountParser.parse(amountText), magnitude > 0 else {
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
            // The update above already bumped the local version by one —
            // confirm against that new version, not the one this screen
            // was opened with, or a stale-version conflict would log for
            // no reason on every single review.
            if isConfirmingCapture, let id = editingId, let expectedVersion = editingFromVersion {
                await session.outbox.submitConfirmCaptureTransaction(
                    ConfirmCaptureTransactionPayload(id: id, expectedVersion: expectedVersion + 1)
                )
            }
            // A: the local write already landed by the time submitX
            // returns — the network delivery keeps running in the
            // background. A version conflict, if one happens, surfaces
            // later via Needs Review, not as a reason to keep this sheet
            // open; `divergenceWarning` is the one remaining pre-write gate.
            if divergenceWarning == nil {
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
    fileprivate func saveLedgerTransaction(accountId: UUID, magnitude: Int64) async throws {
        guard let userId = session.profile?.id, let categoryId = selectedCategoryId, let account = fromAccount else {
            errorMessage = "Choose a category."
            return
        }
        // Sign applied here, once, from the kind the user picked — never
        // re-derived elsewhere (money rule: never re-sign in application
        // code beyond this single point; the DB's sign_matches_category_kind
        // CHECK is the actual backstop).
        let signedAmountE4 = kind == .expense ? -magnitude : magnitude
        let payload = CreateTransactionPayload(
            id: UUID(), ownerId: userId, accountId: accountId, categoryId: categoryId,
            amountE4: signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            notes: notes.isEmpty ? nil : notes
        )
        await session.outbox.submitCreateTransaction(payload)
    }

    fileprivate func updateLedgerTransaction(accountId: UUID, magnitude: Int64) async throws {
        guard
            let categoryId = selectedCategoryId,
            let account = fromAccount,
            let id = editingId,
            let expectedVersion = editingFromVersion
        else {
            errorMessage = "Choose a category."
            return
        }
        let signedAmountE4 = kind == .expense ? -magnitude : magnitude
        let payload = UpdateTransactionPayload(
            id: id, expectedVersion: expectedVersion, accountId: accountId, categoryId: categoryId,
            amountE4: signedAmountE4, currency: account.currency, occurredAt: occurredAt,
            merchantRaw: merchantRaw, notes: notes.isEmpty ? nil : notes
        )
        await session.outbox.submitUpdateTransaction(payload)
    }
}
