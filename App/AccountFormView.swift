import KeepoCore
import SwiftUI

/// Create and edit share one form, mirroring `TransactionFormView`. Kind is
/// locked once an account exists — the composite FKs from `transactions`
/// tie a transaction's currency and account_kind to its account's, and
/// changing kind would change which of the two balance formulas applies —
/// so edit mode only ever fetches the raw `accounts` row it needs and never
/// offers a kind picker at all.
struct AccountFormView: View {
    let session: SessionStore
    var mode: Mode = .create
    var onSaved: () -> Void

    enum Mode {
        case create
        case edit(UUID)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var name = ""
    @State private var subtype: PublicSchema.AccountSubtype = .checking
    @State private var currency = ""
    @State private var openingBalanceText = ""
    @State private var includeInTotal = true
    @State private var countsTowardFi = true

    @State private var editingId: UUID?
    @State private var editingVersion: Int?
    @State private var editingKind: PublicSchema.AccountKind?

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showConflictAlert = false

    @State private var currentBalanceText = ""
    @State private var isUpdatingBalance = false
    @State private var balanceUpdateMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Ledger accounts choose among the four ledger subtypes; a valuation
    /// account's subtype is always `investment` — subtype_matches_kind's
    /// CHECK makes any other combination impossible, so the picker never
    /// offers one.
    private var subtypeOptions: [PublicSchema.AccountSubtype] {
        if isEditing {
            return editingKind == .valuation ? [.investment] : [.checking, .cash, .creditCard, .loan]
        }
        return [.checking, .cash, .creditCard, .loan, .investment]
    }

    private var selectedCurrencyMinorUnit: Int {
        Int(currencies.first { $0.code == currency }?.minorUnit ?? 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    ProgressView()
                } else {
                    Section("Name") {
                        TextField("Account name", text: $name)
                    }

                    Section("Type") {
                        Picker("Type", selection: $subtype) {
                            ForEach(subtypeOptions, id: \.self) { option in
                                Text(label(for: option)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(subtypeOptions.count == 1)
                    }

                    Section("Currency") {
                        if isEditing {
                            Text(currency)
                                .foregroundStyle(Color.secondary)
                        } else {
                            Picker("Currency", selection: $currency) {
                                ForEach(currencies, id: \.code) { currencyRow in
                                    Text(currencyRow.code).tag(currencyRow.code)
                                }
                            }
                        }
                    }

                    Section("Opening balance") {
                        TextField("0.00", text: $openingBalanceText)
                            .keyboardType(.decimalPad)
                    }

                    // "What's this account worth right now" — a different
                    // question from the static fields above, and answered
                    // by its own RPC (set_account_balance), so it gets its
                    // own section and its own button rather than folding
                    // into the main Save action. Edit mode only: a new
                    // account's current balance already equals its
                    // opening balance, there's nothing to reconcile yet.
                    if isEditing {
                        Section("Current Balance") {
                            TextField("0.00", text: $currentBalanceText)
                                .keyboardType(.decimalPad)
                            Button {
                                Task { await updateBalance() }
                            } label: {
                                if isUpdatingBalance {
                                    ProgressView()
                                } else {
                                    Text("Update Balance")
                                }
                            }
                            .disabled(isUpdatingBalance || currentBalanceText.isEmpty)
                            if let balanceUpdateMessage {
                                Text(balanceUpdateMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }

                    Section {
                        Toggle("Include in totals", isOn: $includeInTotal)
                        Toggle("Counts toward FI", isOn: $countsTowardFi)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "New Account")
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
            .alert("This account changed elsewhere", isPresented: $showConflictAlert) {
                Button("OK") {}
            } message: {
                Text("Showing the latest version — review it and save again.")
            }
        }
        .task { await load() }
    }

    private func label(for subtype: PublicSchema.AccountSubtype) -> String {
        switch subtype {
        case .checking: return "Checking"
        case .cash: return "Cash"
        case .creditCard: return "Credit Card"
        case .loan: return "Loan"
        case .investment: return "Investment"
        }
    }

    private var isSaveDisabled: Bool {
        isLoading || isSaving
            || name.trimmingCharacters(in: .whitespaces).isEmpty
            || openingBalanceText.isEmpty
            || (!isEditing && currency.isEmpty)
    }

    /// Reads straight off the local GRDB mirror (Phase L6) — `Outbox`'s
    /// write-through means this is always current, including a still-
    /// unsynced edit, so there's no separate cache-fallback chain needed
    /// the way a network fetch used to require.
    private func load() async {
        currencies = (try? await session.dbQueue.read { database in try LocalTableQueries.currencies(database) }) ?? []

        switch mode {
        case .create:
            currency = session.profile?.baseCurrency ?? currencies.first?.code ?? "USD"
            openingBalanceText = AmountFormatter.editableString(0, minorUnit: selectedCurrencyMinorUnit)
        case .edit(let id):
            if let account = try? await session.dbQueue.read({ database in
                try LocalTableQueries.account(database, id: id.uuidString)
            }) {
                apply(account)
            }
            await prefillCurrentBalance(accountId: id)
        }
        isLoading = false
    }

    /// "What does this account look like right now" — the local balance,
    /// which already includes any still-unsynced write (`Outbox`'s
    /// write-through). Falls back to the opening balance already loaded by
    /// `apply` if the account has no computable balance yet.
    private func prefillCurrentBalance(accountId: UUID) async {
        let today = PostgresDate.dateOnlyString(Date(), calendar: utcCalendar)
        let balance = try? await session.dbQueue.read { database in
            try LocalMoneyQueries.accountBalance(database, accountId: accountId.uuidString, asOf: today, now: Date())
        }
        guard let balance = balance ?? nil else {
            currentBalanceText = openingBalanceText
            return
        }
        currentBalanceText = AmountFormatter.editableString(balance, minorUnit: selectedCurrencyMinorUnit)
    }

    /// Shared by the initial edit-mode prefill and by a post-conflict reload.
    private func apply(_ account: PublicSchema.AccountsSelect) {
        editingId = account.id
        editingVersion = Int(account.version)
        editingKind = account.kind
        name = account.name
        subtype = account.subtype
        currency = account.currency
        includeInTotal = account.includeInTotal
        countsTowardFi = account.countsTowardFi
        openingBalanceText = AmountFormatter.editableString(
            account.openingBalanceE4, minorUnit: selectedCurrencyMinorUnit
        )
    }
}

extension AccountFormView {
    fileprivate func save() async {
        guard let openingBalanceE4 = AmountParser.parse(openingBalanceText) else {
            errorMessage = "Enter a valid opening balance."
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            switch mode {
            case .create:
                try await createAccount(openingBalanceE4: openingBalanceE4)
                onSaved()
                dismiss()
            case .edit:
                try await updateAccount(openingBalanceE4: openingBalanceE4)
                if !showConflictAlert {
                    onSaved()
                    dismiss()
                }
            }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }

    /// Goes through `session.outbox`, never `AccountRepository` directly —
    /// same reasoning as TransactionFormView's writes: an offline create
    /// queues instead of erroring.
    fileprivate func createAccount(openingBalanceE4: Int64) async throws {
        guard let userId = session.profile?.id else { return }
        let kind: PublicSchema.AccountKind = subtype == .investment ? .valuation : .ledger
        let payload = CreateAccountPayload(
            id: UUID(), ownerId: userId, kind: kind, subtype: subtype,
            name: name, currency: currency, openingBalanceE4: openingBalanceE4
        )
        await session.outbox.submitCreateAccount(payload)
    }

    fileprivate func updateAccount(openingBalanceE4: Int64) async throws {
        guard let id = editingId, let expectedVersion = editingVersion else {
            errorMessage = "Missing account details."
            return
        }
        let payload = UpdateAccountPayload(
            id: id, expectedVersion: expectedVersion, name: name, subtype: subtype,
            openingBalanceE4: openingBalanceE4, includeInTotal: includeInTotal, countsTowardFi: countsTowardFi
        )
        let result = await session.outbox.submitUpdateAccount(payload)
        if result == .conflict {
            await reloadAfterConflict(id: id)
        }
    }

    /// A separate action from Save, on purpose — "this account is worth X
    /// right now" doesn't touch name/subtype/opening balance, and
    /// `set_account_balance` computes the actual gap server-side (or, for
    /// a valuation account, just writes a new snapshot) rather than this
    /// form guessing one. Offline-capable like every other write here: it
    /// queues through the outbox and the RPC recomputes the true gap
    /// fresh whenever it finally runs, so a queued edit is never stale by
    /// the time it lands.
    fileprivate func updateBalance() async {
        guard
            let id = editingId, let expectedVersion = editingVersion,
            let newBalanceE4 = AmountParser.parse(currentBalanceText)
        else {
            balanceUpdateMessage = "Enter a valid balance."
            return
        }
        isUpdatingBalance = true
        balanceUpdateMessage = nil
        let payload = SetAccountBalancePayload(
            id: UUID(), accountId: id, newBalanceE4: newBalanceE4, expectedVersion: expectedVersion
        )
        let result = await session.outbox.submitSetAccountBalance(payload)
        switch result {
        case .applied:
            balanceUpdateMessage = "Balance updated."
            session.refresh.bump()
        case .queued:
            balanceUpdateMessage = "Saved — will sync once you're back online."
            session.refresh.bump()
        case .conflict:
            balanceUpdateMessage = "Couldn't update the balance — try again."
        }
        isUpdatingBalance = false
    }

    /// A stale version means someone else changed this account since it
    /// loaded. `Outbox`'s write-through already applied OUR attempted edit
    /// to the local mirror optimistically (before the conflict was known),
    /// so a plain local re-read would just show that same wrong guess back
    /// — a sync pull is what actually corrects the local row to the real
    /// server state; only then is a local re-read meaningful.
    fileprivate func reloadAfterConflict(id: UUID) async {
        await session.syncEngine?.pull()
        if let account = try? await session.dbQueue.read({ database in
            try LocalTableQueries.account(database, id: id.uuidString)
        }) {
            apply(account)
        }
        showConflictAlert = true
    }
}
