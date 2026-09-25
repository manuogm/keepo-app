import KeepoCore
import SwiftUI

// Everything the recurring-rule form reads and writes: the initial load, the
// prefill for each mode, which destinations a transfer may actually reach,
// and the save. Split out of RecurringRuleFormView.swift for the project's
// file-length and type-body-length lints, same precedent as
// TransactionFormView+Data.swift.
//
// Nothing here is `private`, for that reason alone.

extension RecurringRuleFormView {
    /// Paired with `kind` so one `.task(id:)` re-reads the category ranking
    /// whenever either input to it changes. Same shape and same reasoning as
    /// `TransactionFormView.EntryContext`.
    struct EntryContext: Equatable {
        let accountId: UUID?
        let kind: Kind
    }

    static var suggestionCount: Int { 3 }

    // MARK: - Destinations

    /// Where a recurring transfer out of `selectedAccount` may actually go.
    ///
    /// Filtered rather than validated-after-the-fact, because every exclusion
    /// here is something the server will refuse outright (migration
    /// 20260927100000) — offering an account that cannot be saved is offering
    /// a dead end. What the user loses by filtering is the explanation, which
    /// `destinationRestriction` puts back, and only when something was
    /// actually hidden.
    ///
    /// - same owner: the materialized destination leg has to be stampable
    ///   with the rule that created it, and that foreign key is composite.
    /// - same currency: there is no honest destination amount to store for a
    ///   rule that fires unattended.
    /// - not archived: a standing instruction into an archived account is
    ///   not one the user still means.
    var eligibleDestinations: [LocalAccountRow] {
        guard let source = selectedAccount else { return [] }
        return accounts.filter { candidate in
            candidate.id != source.id
                && candidate.ownerId == source.ownerId
                && candidate.currency == source.currency
                && candidate.archivedAt == nil
        }
    }

    /// Whether anything was left out of the destination list for a reason
    /// worth explaining — a live account the user can see elsewhere in the
    /// app but not here.
    ///
    /// The source account itself does not count: leaving it out needs no
    /// explanation, and counting it would print the caption for every user
    /// with exactly two accounts.
    var hasHiddenDestinations: Bool {
        guard let source = selectedAccount else { return false }
        let visible = accounts.filter { $0.id != source.id && $0.archivedAt == nil }
        return visible.count > eligibleDestinations.count
    }

    // MARK: - Kind

    /// Switching kind clears whatever the other shape had chosen.
    ///
    /// A rule is a category OR a destination, never both — the server says so
    /// as a CHECK and `RecurringRuleRepository.Target` says so as an enum.
    /// Carrying a stale category into the transfer tab would leave it sitting
    /// in state, invisible, waiting to be written the moment the user
    /// switched back; `adoptContext` then picks the right one on the way in.
    var kindBinding: Binding<Kind> {
        Binding(
            get: { kind },
            set: { chosen in
                guard chosen != kind else { return }
                if chosen == .transfer {
                    selectedCategoryId = nil
                } else {
                    selectedToAccountId = nil
                }
                kind = chosen
            }
        )
    }

    // MARK: - Loading

    func load() async {
        var heldCategory: PublicSchema.CategoriesSelect?
        if let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency {
            let editedCategoryId: UUID? = {
                guard case .edit(let rule) = mode else { return nil }
                return rule.categoryId
            }()
            let loaded = try? await session.dbQueue.read { database in
                (
                    try LocalAccountRow.fetchAll(database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency),
                    try LocalTableQueries.categories(database, ownerId: ownerId.uuidString),
                    try LocalTableQueries.tags(database),
                    try editedCategoryId.flatMap { try LocalTableQueries.category(database, id: $0.uuidString) }
                )
            }
            accounts = loaded?.0 ?? []
            categories = loaded?.1 ?? []
            tagsById = Dictionary(
                (loaded?.2 ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            heldCategory = loaded?.3 ?? nil
        }

        switch mode {
        case .edit(let rule):
            apply(rule)
            // Synchronous and straight after `apply`, for the reason
            // `TransactionFormView.adoptEditedCategory` gives.
            if let heldCategory, heldCategory.id == selectedCategoryId {
                let resolved = AccountCategories.editing(held: heldCategory, among: categories)
                categories = resolved.categories
                selectedCategoryId = resolved.selection
            }
            await loadAppliedTags(ruleId: rule.id)
        case .createSeeded(
            let accountId, let toAccountId, let categoryId, let seededAmount, let seededKind, let start,
            let seededTitle, let seededNotes, let seededTagIds
        ):
            kind = seededKind
            selectedAccountId = accountId
            selectedToAccountId = toAccountId
            selectedCategoryId = categoryId
            // The amount arrives as a locale-correct editable string from the
            // transaction form, so it is carried across verbatim rather than
            // parsed and re-formatted.
            amountText = seededAmount
            nextDueAt = start
            // Carried across so "Make recurring" on "Gym" makes a rule called
            // "Gym" — which is also what every occurrence will be called.
            title = seededTitle
            // The note and tags too, since a rule carries both onto every
            // occurrence (20260930100000). The tags land as a *selection*
            // over an empty baseline, so Save writes them as links of the
            // new rule exactly as if they had been picked here.
            notes = seededNotes
            selectedTagIds = seededTagIds
        case .create:
            // The account the user reaches for most is a guess; the account
            // they have is not. One account means no question to ask.
            if accounts.count == 1 { selectedAccountId = accounts.first?.id }
        }
        isLoading = false

        // Explicitly, rather than leaving it to the `.task(id:)` observer —
        // the same reason `TransactionFormView.load` calls it by hand. That
        // observer fires before this load has accounts to rank against, and
        // whether it fires a second time depends on whether the prefill
        // happened to change the value it keys on: for a fresh Expense with
        // no account chosen, it does not, so the form opened with no
        // category selected and a row showing nothing but "More".
        await adoptContext()
    }

    /// The rule's current tags, read after `apply(_:)`. `originalTagIds` is
    /// the baseline Save diffs against, so re-saving a rule nobody re-tagged
    /// writes nothing at all — the same contract
    /// `TransactionFormView.loadAppliedTags` follows.
    func loadAppliedTags(ruleId: UUID) async {
        let ids = (try? await session.dbQueue.read { database in
            try LocalTableQueries.recurringRuleTagIds(database, ruleId: ruleId.uuidString)
        }) ?? []
        originalTagIds = Set(ids.compactMap(UUID.init(uuidString:)))
        selectedTagIds = originalTagIds
    }

    /// Re-reads what this account and kind imply — the ranked category chips,
    /// and whether the transfer destination on screen is still reachable.
    func adoptContext() async {
        guard !isLoading else { return }
        await refreshCategorySuggestions()

        if kind == .transfer {
            // The source account can change under a chosen destination —
            // switching to a USD account strands a EUR one. Dropping it is
            // the honest outcome: the picker below no longer offers it, so
            // leaving it selected would show a value the list disagrees with.
            if let destination = selectedToAccountId,
               !eligibleDestinations.contains(where: { $0.id == destination }) {
                selectedToAccountId = nil
            }
            if selectedToAccountId == nil, eligibleDestinations.count == 1 {
                selectedToAccountId = eligibleDestinations.first?.id
            }
        } else if selectedCategoryId == nil
                    || !categoriesForKind.contains(where: { $0.id == selectedCategoryId }) {
            selectedCategoryId = (suggestedCategories.first ?? categoriesForKind.first)?.id
        }
    }

    /// The three chips, from `LocalCategoryRanking` — the same ranking the
    /// transaction form's chips and the capture notification's quick actions
    /// read. Two passes for the same reason that form gives: this account's
    /// own habits first, then the whole ledger's for the same kind, so an
    /// account with no history still gets a sensible answer.
    func refreshCategorySuggestions() async {
        guard kind != .transfer, let ownerId = session.profile?.id else {
            suggestedCategories = []
            return
        }
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

    /// Prefills every field from an existing rule.
    ///
    /// **The amount goes in as a magnitude.** It used to be written straight
    /// from the signed column, so opening an expense rule showed "-45.00" in
    /// the big figure while the Expense tab beside it already said which
    /// direction this went — the minus stated twice, and `AmountField` draws
    /// one specially, in front of the currency symbol. It round-tripped
    /// correctly (`save` takes `abs`), so nothing was ever wrong in the
    /// database; it just read as though the user had typed a negative number.
    func apply(_ rule: PublicSchema.RecurringRulesSelect) {
        editingId = rule.id
        selectedAccountId = rule.accountId
        selectedToAccountId = rule.toAccountId
        selectedCategoryId = rule.categoryId

        if rule.toAccountId != nil {
            kind = .transfer
        } else {
            kind = rule.amountE4 < 0 ? .expense : .income
        }

        // Read AFTER the account is set: `minorUnit` resolves through it.
        amountText = AmountFormatter.editableString(abs(rule.amountE4), minorUnit: minorUnit)
        notes = rule.notes ?? ""
        title = rule.title ?? ""
        frequency = rule.frequency
        nextDueAt = PostgresDate.dateOnly(from: rule.nextDueAt) ?? Date()
        active = rule.active
    }

    var minorUnit: Int {
        selectedAccount?.currencyInfo.minorUnit ?? 2
    }

    // MARK: - Saving

    var isSaveDisabled: Bool {
        isLoading || isSaving || selectedAccountId == nil || amountText.isEmpty || target == nil
    }

    /// Which shape this form currently describes, or `nil` while the answer
    /// is incomplete. One place decides it, so the Save button's enabled
    /// state and what Save actually writes can never disagree.
    var target: RecurringRuleRepository.Target? {
        if kind == .transfer {
            return selectedToAccountId.map { .transfer(toAccountId: $0) }
        }
        return selectedCategoryId.map { .category($0) }
    }

    func save() async {
        guard let magnitude = AmountParser.parse(amountText), magnitude != 0,
              let accountId = selectedAccountId, let target, let currency = selectedAccount?.currency else {
            errorMessage = "Fill in every field."
            return
        }

        // **Signed here, once, and never again** (money rule 1). A transfer
        // stores its OUTFLOW, the same leg `create_transfer` writes and the
        // same one `materialize_recurring` mirrors into the destination — so
        // it is negative, like an expense, and for the same reason.
        let unsigned = abs(magnitude)
        let signedAmountE4 = kind == .income ? unsigned : -unsigned

        isSaving = true
        errorMessage = nil
        do {
            // Each branch mirrors its write into the local store the moment
            // the server accepts it. `RecurringRuleRepository` is not an
            // outbox path, and `RefreshCoordinator.bump()` only invalidates
            // screens — it does not pull — so without this the rule the user
            // just saved is missing from the list they land back on. See
            // `RecurringRuleLocalWrite`.
            switch mode {
            case .create, .createSeeded:
                guard let ownerId = session.profile?.id else { return }
                let id = try await RecurringRuleRepository.create(
                    client: session.client, ownerId: ownerId, accountId: accountId, target: target,
                    amountE4: signedAmountE4, currency: currency, frequency: frequency,
                    nextDueAt: nextDueAt, notes: trimmedNotes, title: storedTitle
                )
                try await session.dbQueue.write { database in
                    try RecurringRuleLocalWrite.insert(
                        id: id, createdBy: ownerId, accountId: accountId, target: target,
                        amountE4: signedAmountE4, currency: currency, frequency: frequency,
                        nextDueAt: nextDueAt, notes: trimmedNotes, title: storedTitle, in: database
                    )
                }
                try await applyTagChanges(ruleId: id, ownerId: ownerId)
            case .edit:
                guard let id = editingId else { return }
                try await RecurringRuleRepository.update(
                    client: session.client, id: id, accountId: accountId, target: target,
                    amountE4: signedAmountE4, currency: currency, frequency: frequency,
                    nextDueAt: nextDueAt, active: active, notes: trimmedNotes, title: storedTitle
                )
                try await session.dbQueue.write { database in
                    try RecurringRuleLocalWrite.update(
                        id: id, accountId: accountId, target: target, amountE4: signedAmountE4,
                        currency: currency, frequency: frequency, nextDueAt: nextDueAt,
                        active: active, notes: trimmedNotes, title: storedTitle, in: database
                    )
                }
                guard let ownerId = session.profile?.id else { return }
                try await applyTagChanges(ruleId: id, ownerId: ownerId)
            }
            onSaved()
            dismiss()
        } catch {
            actionError = ActionError(isEditing ? "Couldn't Save Changes" : "Couldn't Create Recurring", error)
        }
        isSaving = false
    }

    /// An empty note is `nil`, not `""` — the column is nullable and a blank
    /// string would be a note that renders as an empty line on every
    /// transaction the rule ever mints.
    var trimmedNotes: String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The same rule the transaction form stores its title by, because every
    /// occurrence this rule mints carries it into that column.
    var storedTitle: String? {
        TransactionTitle.stored(title)
    }

    /// Writes only the difference, server first then the mirror — the same
    /// order every other write on this screen uses, and for the same reason:
    /// the list reads the mirror and `RefreshCoordinator.bump()` does not pull.
    func applyTagChanges(ruleId: UUID, ownerId: UUID) async throws {
        guard selectedTagIds != originalTagIds else { return }
        try await RecurringRuleRepository.setTags(
            client: session.client, ruleId: ruleId, ownerId: ownerId,
            tagIds: selectedTagIds, previous: originalTagIds
        )
        try await session.dbQueue.write { database in
            try RecurringRuleLocalWrite.setTags(
                ruleId: ruleId, ownerId: ownerId,
                tagIds: selectedTagIds, previous: originalTagIds, in: database
            )
        }
    }
}
