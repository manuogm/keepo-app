import KeepoCore
import SwiftUI

/// Create and edit share one form, mirroring `TransactionFormView`. Kind is
/// chosen once, up front, by `AddAccountFlowView` (create mode only) and
/// locked forever after — this form never offers a kind picker itself.
struct AccountFormView: View {
    let session: SessionStore
    var mode: Mode = .create(kind: .regular)
    var onSaved: () -> Void

    /// `false` when pushed onto `AddAccountFlowView`'s stack (create) rather
    /// than being the sheet's own root (edit) — skips the nested
    /// `NavigationStack` and the cancellation "x" (back button + swipe cover it).
    var embedInNavigationStack = true

    /// Set only by `AddAccountFlowView`: closes the whole sheet after save,
    /// since a pushed `dismiss()` would only pop back to the chooser.
    var onDismissRequested: (() -> Void)?

    enum Mode {
        case create(kind: PublicSchema.AccountKind)
        case edit(UUID)
    }

    @Environment(\.dismiss) private var dismiss

    private func dismissSelf() {
        if let onDismissRequested {
            onDismissRequested()
        } else {
            dismiss()
        }
    }

    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var name = ""
    @State private var currency = ""
    @State private var openingBalanceText = ""
    @State private var includeInTotal = true
    @State private var icon = AccountAppearance.pickerIcons[0]
    @State private var color = Color(hex: CategoryAppearance.randomColor())

    @State private var editingId: UUID?
    @State private var editingVersion: Int?
    // Not `private` — read from AccountFormView+Cards.swift (a different
    // file, kept there for file-length).
    @State var editingKind: PublicSchema.AccountKind?
    @State private var editingArchivedAt: String?
    @State private var showArchiveConfirm = false

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var currentBalanceText = ""
    @State private var isUpdatingBalance = false
    @State private var balanceUpdateMessage: String?

    // Not `private` — read/written from AccountFormView+Cards.swift (a different file, kept there for file-length).
    @State var cardMappings: [PublicSchema.CardMappingsSelect] = []

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var selectedCurrencyMinorUnit: Int {
        Int(currencies.first { $0.code == currency }?.minorUnit ?? 2)
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
                    Section("Name") {
                        TextField("Account name", text: $name)
                    }

                    if editingKind == .investment {
                        Section {
                            HStack {
                                Text("Type")
                                Spacer()
                                InvestmentBadge()
                            }
                        }
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

                    if isEditing {
                        mappedCardsSection
                    }

                    Section("Icon") {
                        iconGrid
                    }

                    Section("Color") {
                        ColorPicker("Account Color", selection: $color, supportsOpacity: false)
                    }

                    Section {
                        Toggle("Include in totals", isOn: $includeInTotal)
                    }

                    if isEditing {
                        Section {
                            Button(role: .destructive) {
                                if editingArchivedAt == nil {
                                    showArchiveConfirm = true
                                } else {
                                    Task { await setArchived(false) }
                                }
                            } label: {
                                Text(editingArchivedAt == nil ? "Archive Account" : "Unarchive Account")
                            }
                        }
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
                if embedInNavigationStack {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismissSelf() } label: { Image(systemName: "xmark") }
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
            .alert("Archive \"\(name)\"?", isPresented: $showArchiveConfirm) {
                Button("Archive", role: .destructive) {
                    Task { await setArchived(true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Archiving an account will remove it from your total balance but will not delete "
                        + "the account or the transactions associated."
                )
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(AccountAppearance.pickerIcons, id: \.self) { candidate in
                Button {
                    icon = candidate
                } label: {
                    Image(systemName: candidate)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .foregroundStyle(icon == candidate ? Color.white : Color.primary)
                        .background(icon == candidate ? color : Color(.systemGray5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
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
        case .create(let kind):
            editingKind = kind
            icon = AccountAppearance.defaultIcon(forKind: kind)
            currency = session.profile?.baseCurrency ?? currencies.first?.code ?? "USD"
            openingBalanceText = AmountFormatter.editableString(0, minorUnit: selectedCurrencyMinorUnit)
        case .edit(let id):
            if let account = try? await session.dbQueue.read({ database in
                try LocalTableQueries.account(database, id: id.uuidString)
            }) {
                apply(account)
            }
            await prefillCurrentBalance(accountId: id)
            await loadCardMappings()
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
        editingArchivedAt = account.archivedAt
        name = account.name
        currency = account.currency
        includeInTotal = account.includeInTotal
        icon = account.icon
        color = Color(hex: account.color)
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
            case .create(let kind):
                try await createAccount(kind: kind, openingBalanceE4: openingBalanceE4)
            case .edit:
                try await updateAccount(openingBalanceE4: openingBalanceE4)
            }
            // A: the local write already landed by the time submitX
            // returns — the network delivery keeps running in the
            // background, so there's nothing left worth waiting for here.
            // A version conflict, if one happens, surfaces later via
            // Needs Review, not as a reason to keep this sheet open.
            onSaved()
            dismissSelf()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }

    /// Goes through `session.outbox`, never `AccountRepository` directly —
    /// same reasoning as TransactionFormView's writes: an offline create
    /// queues instead of erroring.
    fileprivate func createAccount(kind: PublicSchema.AccountKind, openingBalanceE4: Int64) async throws {
        guard let userId = session.profile?.id else { return }
        let payload = CreateAccountPayload(
            id: UUID(), ownerId: userId, kind: kind,
            name: name, currency: currency, openingBalanceE4: openingBalanceE4,
            icon: icon, color: color.hexString ?? CategoryAppearance.randomColor()
        )
        await session.outbox.submitCreateAccount(payload)
    }

    fileprivate func updateAccount(openingBalanceE4: Int64) async throws {
        guard let id = editingId, let expectedVersion = editingVersion else {
            errorMessage = "Missing account details."
            return
        }
        let payload = UpdateAccountPayload(
            id: id, expectedVersion: expectedVersion, name: name,
            openingBalanceE4: openingBalanceE4, includeInTotal: includeInTotal,
            icon: icon, color: color.hexString ?? CategoryAppearance.randomColor()
        )
        await session.outbox.submitUpdateAccount(payload)
    }

    /// The "twin button" archive/unarchive inside the edit sheet, alongside
    /// the existing swipe action on `AccountsListView` — same
    /// `archive_account` RPC either way, just a second entry point for
    /// users who don't discover swipe gestures.
    fileprivate func setArchived(_ archived: Bool) async {
        guard let id = editingId, let expectedVersion = editingVersion else { return }
        let payload = ArchiveAccountPayload(id: id, expectedVersion: expectedVersion, archived: archived)
        await session.outbox.submitArchiveAccount(payload)
        onSaved()
        dismissSelf()
    }

    /// A separate action from Save, on purpose — "this account is worth X
    /// right now" doesn't touch name/opening balance, and
    /// `set_account_balance` computes the actual gap server-side and files
    /// an adjustment transaction rather than this form guessing one.
    /// Offline-capable like every other write here: it
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
        // A: the local write is already in by the time this returns — the
        // network delivery keeps going in the background, so there's
        // nothing left to distinguish (applied vs. queued) synchronously.
        // A version conflict, if one happens, surfaces later via Needs Review.
        await session.outbox.submitSetAccountBalance(payload)
        balanceUpdateMessage = "Balance updated."
        session.refresh.bump()
        isUpdatingBalance = false
    }
}
