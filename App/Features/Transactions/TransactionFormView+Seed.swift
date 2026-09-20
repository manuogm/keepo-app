import KeepoCore
import SwiftUI

// What a NEW transaction opens on — the create-mode prefill, split out of
// TransactionFormView+Data.swift for the project's file-length lint, same
// precedent as TransactionFormView+Transfer.swift.
//
// The edit-mode prefill stays in +Data.swift beside the load it belongs to.
// These two are not the same job: one fills a form from a row that exists,
// the other from the screen the user was looking at when they tapped Add.

extension TransactionFormView {
    /// A new transaction opens on something rather than on nothing.
    ///
    /// Whatever the presenting screen had narrowed itself to arrives in
    /// `seed`: filtering the ledger to an account, a category, a type or a
    /// period and then adding to it must not mean answering the same
    /// questions again. Everything the seed does not carry falls back to
    /// the form's own defaults — the first account and the first category
    /// of the current kind — so an unfiltered Add is still
    /// amount-then-save, exactly as before.
    ///
    /// **Order is load-bearing.** `kind` decides which categories
    /// `categoriesForKind` offers, so it is settled before a category is
    /// picked out of them.
    ///
    /// Not `private` — called from `load()` in
    /// TransactionFormView+Data.swift.
    func seedCreateDefaults() {
        kind = seededKind ?? kind
        if let occurred = seed.occurredAt { occurredAt = occurred }
        selectedAccountId = seededAccountId ?? accounts.first { $0.archivedAt == nil }?.id
        // Deliberately not falling back to `categoriesForKind.first` here:
        // alphabetical order is not a guess at anything. `adoptContext()`
        // fills an empty selection from the ranked suggestions instead, and
        // only lands on the first category when there is no history at all.
        selectedCategoryId = seededCategoryId
    }

    /// Three, because that is what fits one row beside "More" at the
    /// widths this form is drawn at, and because a fourth guess is not a
    /// guess any more.
    static var suggestionCount: Int { 3 }

    /// Everything the form can work out from "which account, which kind" —
    /// re-run whenever either changes, including once on open.
    ///
    /// The category is **only** replaced when the one held is not valid for
    /// the kind on screen: switching Expense → Income invalidates it, and
    /// leaving a stale expense category selected under income would offer a
    /// save the database's own `sign_matches_category_kind` would reject.
    /// Changing account does not touch a valid choice — the chips
    /// underneath re-rank, but a category the user picked is theirs.
    func adoptContext() async {
        await refreshCategorySuggestions()
        fillSoleTransferDestination()
        if selectedCategoryId == nil || !categoriesForKind.contains(where: { $0.id == selectedCategoryId }) {
            selectedCategoryId = (suggestedCategories.first ?? categoriesForKind.first)?.id
        }
    }

    /// The three chips, from `LocalCategoryRanking` — the same ranking the
    /// capture notification's quick actions use.
    ///
    /// Two passes, because an account with no history still deserves a
    /// sensible answer: this account's own habits first, then the whole
    /// ledger's for the same kind. The second is not a worse guess so much
    /// as a wider one — a first purchase on a new card is still made by
    /// somebody who mostly buys groceries.
    func refreshCategorySuggestions() async {
        guard let ownerId = session.profile?.id else { return }
        let categoryKind = kind == .income ? "income" : "expense"
        let accountId = selectedAccountId?.uuidString
        let ranked = try? await session.dbQueue.read { database in
            (
                try LocalCategoryRanking.mostUsed(
                    database, ownerId: ownerId.uuidString, accountId: accountId,
                    categoryKind: categoryKind, limit: Self.suggestionCount
                ),
                try LocalCategoryRanking.mostUsed(
                    database, ownerId: ownerId.uuidString, categoryKind: categoryKind,
                    limit: Self.suggestionCount
                )
            )
        }
        let ids = ((ranked?.0 ?? []) + (ranked?.1 ?? [])).compactMap { UUID(uuidString: $0.id) }
        let valid = categoriesForKind
        var seen: Set<UUID> = []
        suggestedCategories = ids
            .filter { seen.insert($0).inserted }
            .compactMap { id in valid.first { $0.id == id } }
            .prefix(Self.suggestionCount)
            .map { $0 }
    }

    /// A transfer out of an account when the user owns exactly one other
    /// one has a single possible answer, and asking for it is asking them
    /// to agree with the app. Only ever fills a destination that is empty
    /// or has just become the source — a choice already made is never
    /// overwritten.
    func fillSoleTransferDestination() {
        guard kind == .transfer else { return }
        if let destination = selectedToAccountId, destination != selectedAccountId { return }
        selectedToAccountId = Self.soleDestination(among: accounts, excluding: selectedAccountId)
    }

    /// Exactly one live account that is not the source, or nothing.
    /// Static and pure so the rule can be pinned by a test rather than
    /// only by opening the form on a two-account ledger — which is what it
    /// took to notice it could not be checked at all on a ledger with
    /// thirteen.
    ///
    /// Archived accounts are excluded because the picker excludes them:
    /// prefilling one would put a destination in the field that its own
    /// menu does not offer.
    static func soleDestination(among accounts: [LocalAccountRow], excluding source: UUID?) -> UUID? {
        let candidates = accounts.filter { $0.archivedAt == nil && $0.id != source }
        return candidates.count == 1 ? candidates.first?.id : nil
    }

    /// What "Save and Add Another" leaves behind.
    ///
    /// The context of the run stays — account, category, date, kind — and
    /// only what belonged to the one purchase clears. A note or a tag
    /// silently carried onto the next transaction is a wrong record the
    /// user has to notice before they can undo it, and the amount is the
    /// one field that is different every time.
    ///
    /// The foreign half clears with the purchase, not with the session:
    /// the next entry is in the account's own currency until the user says
    /// otherwise, which is also what stops a charge they corrected off
    /// their bank app (money rule 6) from being inherited by a transaction
    /// nobody corrected.
    func resetForNextEntry() {
        amountText = ""
        receivedAmountText = ""
        notes = ""
        selectedTagIds = []
        originalTagIds = []
        merchantRaw = nil
        errorMessage = nil
        paidCurrencyCode = nil
        chargedAmountText = ""
        chargedAmountEdited = false
        conversionRateDate = nil
        transferDivergenceConfirmed = false
        pendingDelivery = nil
        savedCount += 1
    }

    /// Which tab the form opens on: the type filter when there is one, and
    /// otherwise whatever the seeded category itself is. A ledger narrowed
    /// to "Salary" says income as plainly as the type pill would, and
    /// opening that on the Expense tab would then throw the category away.
    private var seededKind: Kind? {
        if let kind = seed.kind { return Kind(ledgerKind: kind) }
        guard let id = seed.categoryId, let category = categories.first(where: { $0.id == id }) else { return nil }
        return category.kind == .income ? .income : .expense
    }

    /// Seeded only when the account is one the picker would itself offer.
    /// An archived account can still be filtered on — it has history — but
    /// it cannot take a new transaction, and prefilling one would hand the
    /// user a form whose account row shows something its own menu does not
    /// contain.
    private var seededAccountId: UUID? {
        guard let id = seed.accountId else { return nil }
        return accounts.first { $0.id == id && $0.archivedAt == nil }?.id
    }

    /// The same rule against the categories valid for the kind now chosen.
    /// A category filter that belongs to the other kind is not an answer to
    /// "which category" here, so it falls through to the default.
    private var seededCategoryId: UUID? {
        guard let id = seed.categoryId else { return nil }
        return categoriesForKind.first { $0.id == id }?.id
    }
}

extension TransactionFormView.Kind {
    /// From the ledger's own vocabulary — the strings `transactions.kind`
    /// carries, which `TransactionFilter.kind` and `TransactionSeed.kind`
    /// both match on. Anything else is an expense, which is what this form
    /// has always defaulted to.
    ///
    /// One mapping for both prefills: the edit-mode one reads it off the
    /// row, the create-mode one off the filter, and two copies of a
    /// three-case switch is exactly how those two drift apart.
    init(ledgerKind: String?) {
        switch ledgerKind {
        case "income": self = .income
        case "transfer": self = .transfer
        default: self = .expense
        }
    }
}

extension TransactionFormView {
    /// The two answers everything `adoptContext()` works out depends on,
    /// as one `Equatable` value — the key `.task(id:)` re-runs on. Same
    /// shape and same reason as `ConversionInputs`.
    struct EntryContext: Equatable {
        let accountId: UUID?
        let kind: Kind
    }
}
