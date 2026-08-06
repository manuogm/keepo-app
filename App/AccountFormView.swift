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
                                .foregroundStyle(Color("TextSecondary"))
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

    private func load() async {
        currencies = (try? await CurrencyRepository.fetchAll(client: session.client)) ?? []

        switch mode {
        case .create:
            currency = session.profile?.baseCurrency ?? currencies.first?.code ?? "USD"
            openingBalanceText = AmountFormatter.editableString(0, minorUnit: selectedCurrencyMinorUnit)
        case .edit(let id):
            if let account = try? await AccountRepository.fetchOne(client: session.client, id: id) {
                apply(account)
            }
        }
        isLoading = false
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
            account.openingBalance, minorUnit: selectedCurrencyMinorUnit
        )
    }
}

extension AccountFormView {
    fileprivate func save() async {
        guard let openingBalance = AmountParser.parse(openingBalanceText) else {
            errorMessage = "Enter a valid opening balance."
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            switch mode {
            case .create:
                try await createAccount(openingBalance: openingBalance)
                onSaved()
                dismiss()
            case .edit:
                try await updateAccount(openingBalance: openingBalance)
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

    fileprivate func createAccount(openingBalance: Decimal) async throws {
        guard let userId = session.profile?.id else { return }
        let kind: PublicSchema.AccountKind = subtype == .investment ? .valuation : .ledger
        try await AccountRepository.create(
            client: session.client,
            ownerId: userId,
            kind: kind,
            subtype: subtype,
            name: name,
            currency: currency,
            openingBalance: openingBalance
        )
    }

    fileprivate func updateAccount(openingBalance: Decimal) async throws {
        guard let id = editingId, let expectedVersion = editingVersion else {
            errorMessage = "Missing account details."
            return
        }
        let result = try await AccountRepository.update(
            client: session.client,
            id: id,
            expectedVersion: expectedVersion,
            name: name,
            subtype: subtype,
            openingBalance: openingBalance,
            includeInTotal: includeInTotal,
            countsTowardFi: countsTowardFi
        )
        switch result {
        case .saved:
            break
        case .conflict:
            await reloadAfterConflict(id: id)
        }
    }

    /// A stale version means someone else changed this account since it
    /// loaded — reload the current row and repopulate the form, same
    /// convention as TransactionFormView.reloadAfterConflict.
    fileprivate func reloadAfterConflict(id: UUID) async {
        if let account = try? await AccountRepository.fetchOne(client: session.client, id: id) {
            apply(account)
        }
        showConflictAlert = true
    }
}
