import KeepoCore
import SwiftUI

// Load and save for AccountFormView, split out purely to keep that file
// under the project's file-length lint threshold — same precedent as
// TransactionFormView+Transfer.swift.

extension AccountFormView {
    /// Reads straight off the local GRDB mirror (Phase L6) — `Outbox`'s
    /// write-through means this is always current, including a still-
    /// unsynced edit, so there's no separate cache-fallback chain needed
    /// the way a network fetch used to require.
    func load() async {
        let ownerId = session.profile?.id.uuidString
        currencies = (try? await session.dbQueue.read { database in
            try LocalTableQueries.currencies(database)
        }) ?? []
        hasHousehold = ownerId.flatMap { id in
            try? session.dbQueue.read { database in try LocalTableQueries.myHousehold(database, userId: id) }
        } != nil

        switch mode {
        case .create(let kind):
            editingKind = kind
            icon = AccountAppearance.defaultIcon(forKind: kind)
            currency = session.profile?.baseCurrency ?? currencies.first?.code ?? "USD"
        case .edit(let id):
            if let account = try? await session.dbQueue.read({ database in
                try LocalTableQueries.account(database, id: id.uuidString)
            }) {
                apply(account)
            }
            await prefillCurrentBalance(accountId: id)
            await loadSharedState(accountId: id)
            await loadCardMappings()
        }
        isLoading = false
    }

    /// Edit mode's balance field is "what is this worth right now", read
    /// from the local mirror (which already includes any still-unsynced
    /// write). Falls back to the opening balance when the account has no
    /// computable balance yet — never to zero, which would read as a real
    /// balance the user could accidentally save (money rule 5's spirit).
    private func prefillCurrentBalance(accountId: UUID) async {
        let today = PostgresDate.dateOnlyString(Date(), calendar: utcCalendar)
        let balance = try? await session.dbQueue.read { database in
            try LocalMoneyQueries.accountBalance(database, accountId: accountId.uuidString, asOf: today, now: Date())
        }
        let minorUnit = selectedCurrencyInfo?.minorUnit ?? 2
        // `signed: true` — an account balance carries a real sign. A credit
        // card at -840.00 prefilled as "840.00" would be saved back as a
        // positive balance the moment the user touched anything else on this
        // form, since the field round-trips through `AmountParser`.
        balanceText = AmountFormatter.editableString(
            (balance ?? nil) ?? loadedOpeningBalanceE4, minorUnit: minorUnit, signed: true
        )
        loadedBalanceText = balanceText
    }

    private func loadSharedState(accountId: UUID) async {
        guard let ownerId = session.profile?.id.uuidString else { return }
        let row = (try? await session.dbQueue.read { database -> PublicSchema.HouseholdAccountsSelect? in
            guard let household = try LocalTableQueries.myHousehold(database, userId: ownerId) else { return nil }
            return try LocalTableQueries.sharedAccountRow(
                database, householdId: household.id.uuidString, accountId: accountId.uuidString
            )
        }) ?? nil
        isShared = row != nil
        sharedAt = row?.sharedAt
    }

    /// Shared by the initial edit-mode prefill and by a post-conflict reload.
    /// Note what it does NOT do: put `openingBalanceE4` into `balanceText`.
    /// That number is held aside and replayed verbatim on save — see the
    /// type's own header comment.
    private func apply(_ account: PublicSchema.AccountsSelect) {
        editingId = account.id
        editingVersion = Int(account.version)
        editingKind = account.kind
        editingArchivedAt = account.archivedAt
        createdAt = account.createdAt
        name = account.name
        currency = account.currency
        includeInTotal = account.includeInTotal
        icon = account.icon
        color = Color(hex: account.color)
        loadedOpeningBalanceE4 = account.openingBalanceE4
    }
}

// MARK: - Writes

extension AccountFormView {
    func save() async {
        guard let balanceE4 = AmountParser.parse(balanceText) else {
            errorMessage = "Enter a valid balance."
            return
        }

        isSaving = true
        errorMessage = nil
        switch mode {
        case .create(let kind):
            await createAccount(kind: kind, openingBalanceE4: balanceE4)
        case .edit:
            await updateAccount(currentBalanceE4: balanceE4)
        }
        // A: the local write already landed by the time submitX returns —
        // the network delivery keeps running in the background, so there's
        // nothing left worth waiting for here. A version conflict, if one
        // happens, surfaces later via Needs Review, not as a reason to keep
        // this sheet open.
        onSaved()
        dismissSelf()
        isSaving = false
    }

    /// Goes through `session.outbox`, never `AccountRepository` directly —
    /// same reasoning as TransactionFormView's writes: an offline create
    /// queues instead of erroring.
    private func createAccount(kind: PublicSchema.AccountKind, openingBalanceE4: Int64) async {
        guard let userId = session.profile?.id else { return }
        let payload = CreateAccountPayload(
            id: UUID(), ownerId: userId, kind: kind,
            name: name, currency: currency, openingBalanceE4: openingBalanceE4,
            icon: icon, color: color.hexString ?? CategoryAppearance.randomColor()
        )
        await session.outbox.submitCreateAccount(payload)
    }

    /// Two writes, not one, because the form's two halves answer different
    /// questions and the schema answers them with different RPCs:
    /// `update_account` for the account's own fields, and
    /// `set_account_balance` for "it is worth X right now" (which computes
    /// the gap server-side and files an adjustment transaction rather than
    /// this form guessing one).
    ///
    /// The balance write is skipped entirely when the field was not
    /// touched — otherwise saving a pure rename would file a zero-gap
    /// adjustment, or worse, a real one against a balance that drifted
    /// between load and save.
    private func updateAccount(currentBalanceE4: Int64) async {
        guard let id = editingId, let expectedVersion = editingVersion else {
            errorMessage = "Missing account details."
            return
        }
        await session.outbox.submitUpdateAccount(
            UpdateAccountPayload(
                id: id, expectedVersion: expectedVersion, name: name,
                openingBalanceE4: loadedOpeningBalanceE4, includeInTotal: includeInTotal,
                icon: icon, color: color.hexString ?? CategoryAppearance.randomColor()
            )
        )

        guard balanceText != loadedBalanceText else { return }
        // +1: the update above already bumped the row's version locally, and
        // will bump it server-side too. Sending the pre-update version here
        // would conflict against our own immediately-preceding write.
        await session.outbox.submitSetAccountBalance(
            SetAccountBalancePayload(
                id: UUID(), accountId: id, newBalanceE4: currentBalanceE4, expectedVersion: expectedVersion + 1
            )
        )
    }

    func setArchived(_ archived: Bool) async {
        guard let id = editingId, let expectedVersion = editingVersion else { return }
        await session.outbox.submitArchiveAccount(
            ArchiveAccountPayload(id: id, expectedVersion: expectedVersion, archived: archived)
        )
        onSaved()
        dismissSelf()
    }

    /// Permanent. The DB refuses (raises, never a silent conflict) while the
    /// account still has transactions, which is exactly why the confirmation
    /// offers archiving alongside it.
    func deletePermanently() async {
        guard let id = editingId, let expectedVersion = editingVersion else { return }
        isSaving = true
        errorMessage = nil
        do {
            _ = try await AccountRepository.delete(client: session.client, id: id, expectedVersion: expectedVersion)
            onSaved()
            dismissSelf()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }

    /// Online-only, and deliberately not routed through the outbox: both
    /// RPCs re-derive household membership server-side at the moment they
    /// run, and `unshare_account` forks the account for the other member —
    /// neither is something a queued write should replay days later against
    /// a household that may have changed underneath it.
    func setShared(_ shared: Bool) async {
        isSaving = true
        errorMessage = nil
        do {
            if shared {
                try await HouseholdRepository.share(client: session.client, accountId: editingId ?? UUID())
            } else {
                try await HouseholdRepository.unshare(client: session.client, accountId: editingId ?? UUID())
            }
            isShared = shared
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }
}
