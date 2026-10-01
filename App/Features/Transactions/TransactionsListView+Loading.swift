import Foundation
import GRDB
import KeepoCore

/// Data loading and mutation for `TransactionsListView` — split out purely
/// for file-length (SwiftLint's `type_body_length`).
extension TransactionsListView {
    func load() async {
        loadErrorMessage = nil
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        let dbQueue = session.dbQueue
        let scope = session.scope
        // The period is folded in here rather than being held on the
        // filter: the panel owns "which slice", the period track owns
        // "which window", and only the query needs them as one value. A
        // nil range is All Time — both bounds simply go unset, which is
        // exactly what an unbounded `TransactionFilter` already means.
        let effectiveFilter: TransactionFilter = {
            var effective = filter
            effective.from = range?.start
            effective.through = range?.end
            return effective
        }()
        let now = Date()
        do {
            let loaded: LoadedTransactionsState = try await dbQueue.read { database in
                let transactions = try LocalTransactionRow.fetchFiltered(
                    database, filter: effectiveFilter, scope: scope, baseCurrency: baseCurrency,
                    ownerId: ownerId.uuidString
                )
                return LoadedTransactionsState(
                    transactions: transactions,
                    categories: try LocalTableQueries.categories(database, ownerId: ownerId.uuidString),
                    accounts: try LocalAccountRow.fetchAll(
                        database, ownerId: ownerId.uuidString, baseCurrency: baseCurrency
                    ),
                    completeTransferGroups: try LocalTransactionRow.completeTransferGroups(
                        database, among: Array(Set(transactions.compactMap { $0.transferGroupId?.uuidString }))
                    ),
                    allAccountsBalance: try Self.allAccountsBalance(
                        database, scope: scope, baseCurrency: baseCurrency, now: now
                    ),
                    availableSources: try LocalTransactionRow.availableSources(
                        database, scope: scope, ownerId: ownerId.uuidString
                    )
                )
            }
            adopt(loaded)
        } catch {
            // A cancelled load is not a failure the user needs told about —
            // it means the task id changed and a newer load is already in
            // flight. That happens routinely here now that another screen can
            // hand this one a filter *and* a period in the same turn: the
            // first load was cancelled mid-flight and surfaced "Something went
            // wrong" under a list that had loaded perfectly.
            if !UserFacingError.isCancellation(error) {
                loadErrorMessage = UserFacingError.describe(error)
            }
        }
        isLoading = false
    }

    /// The day grouping and the category lookup the list draws from, built
    /// **once per load** — beside the load that feeds them rather than in the
    /// view, which is at the project's file-length limit.
    func regroup() {
        // Transfer legs are folded into one entry BEFORE the day grouping,
        // not inside it — both legs carry the same `occurred_at`, but the
        // pairing is a property of the transfer, not of the day it landed on.
        let groups = Dictionary(grouping: TransactionEntry.collapsingTransfers(transactions)) { entry -> Date in
            guard
                let occurredAt = entry.transaction.occurredAt,
                let date = PostgresDate.date(fromTimestamp: occurredAt)
            else { return .distantPast }
            return calendar.startOfDay(for: date)
        }
        groupedByDay = groups.keys.sorted(by: >).map { day in DayGroup(day: day, items: groups[day] ?? []) }
        // Same reasoning: the filter list is small but the lookup runs once
        // per row per render, so it is built once here instead.
        categoriesById = Dictionary(filterCategories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func category(
        for transaction: PublicSchema.TransactionsWithDetailsSelect
    ) -> PublicSchema.CategoriesSelect? {
        transaction.categoryId.flatMap { categoriesById[$0] }
    }

    /// Everything one read produced, moved onto the screen together.
    ///
    /// Split from `load()` so that function stays inside the project's
    /// `function_body_length` lint, and because the two halves are genuinely
    /// different work: one asks the database a question, this one is the only
    /// place the answer becomes state.
    private func adopt(_ loaded: LoadedTransactionsState) {
        transactions = loaded.transactions
        completeTransferGroups = Set(loaded.completeTransferGroups.compactMap(UUID.init(uuidString:)))
        filterCategories = loaded.categories
        filterAccounts = loaded.accounts
        allAccountsBalance = loaded.allAccountsBalance
        availableSources = loaded.availableSources
        // A source that has left the ledger — the last capture deleted, say —
        // must not go on filtering from a pill that is now dimmed and inert.
        // Down to one source, the filter can only ever match everything, so
        // it goes too. Same guard `loadAuthors` applies to a dissolved
        // household.
        if let sources = filter.sources {
            let surviving = sources.intersection(loaded.availableSources)
            filter.sources = surviving.isEmpty || loaded.availableSources.count < 2 ? nil : surviving
        }
        // Day grouping and the category lookup are derived here, once, rather
        // than recomputed inside `body` — see `regroup`'s own comment on why
        // that mattered.
        regroup()
    }

    /// The scope's net worth, in the viewer's base currency — what the
    /// account chip and the picker's "All accounts" row show.
    ///
    /// `LocalMoneyConversion.netWorth` rather than a sum of anything on this
    /// screen: the ledger holds one period of one filter, a balance holds every
    /// transaction there has ever been, and the Home hero already asks this
    /// exact question. `nil` when the base currency is unknown to the mirror or
    /// any account's rate cannot be resolved — money rule 5, rendered `—`.
    /// `nonisolated` because it runs **inside** the database read's own
    /// closure, off the main actor: a `View` is `@MainActor`, and a static
    /// member of one would have hopped the `Database` handle across actors to
    /// get there — which is a data race, not a detail (Swift 6 rejects it).
    nonisolated private static func allAccountsBalance(
        _ database: Database, scope: PublicSchema.AccountScope, baseCurrency: String, now: Date
    ) throws -> AccountFilterBalance? {
        guard let currency = try LocalTableQueries.currencyInfo(database, code: baseCurrency) else { return nil }
        let amountE4 = try LocalMoneyConversion.netWorth(
            database, LocalMoneyScope(scope: scope, baseCurrency: baseCurrency),
            asOf: PostgresDate.dateOnlyString(now, calendar: utcCalendar), now: now
        )
        return AccountFilterBalance(amountE4: amountE4, currency: currency)
    }

    /// Who the "Added by" filter may offer, and the one thing that has to
    /// happen when it turns out to be nobody: **clear the filter**. A
    /// household dissolved while this screen held an author filter would
    /// otherwise keep narrowing the list with no pill left to say so — the
    /// funnel's dot would be lit and point at nothing.
    func loadAuthors() async {
        authors = await TransactionAuthors.load(session: session)
        if authors.isEmpty { filter.createdByIds = nil }
    }

    /// A: the local write-through already removes each row from the list
    /// the moment this loop reaches it — the network delivery for each
    /// delete keeps running in the background after this function returns.
    /// A version conflict, if one happens, surfaces later via Needs Review,
    /// not as a reason to make the swipe-to-delete gesture wait.
    func delete(
        at offsets: IndexSet, in list: [PublicSchema.TransactionsWithDetailsSelect]
    ) async {
        for index in offsets {
            let transaction = list[index]
            guard let id = transaction.transactionId, let version = transaction.version else { continue }
            if let groupId = transaction.transferGroupId {
                // Both halves, read from the database — never from the rows
                // on screen, which hold only one half whenever a filter or a
                // scope hides the other. A half with no findable partner is
                // not deleted at all (`canDelete` also withholds the swipe):
                // `delete_transaction` refuses a transfer leg.
                guard let payload = await transferDeletion(groupId: groupId) else { continue }
                await session.outbox.submitDeleteTransfer(payload)
            } else {
                let payload = DeleteTransactionPayload(id: id, expectedVersion: Int(version))
                await session.outbox.submitDeleteTransaction(payload)
            }
        }
        session.refresh.bump()
    }

    /// Whether a ledger entry can be swiped away. Everything can except half
    /// of a transfer this device does not hold the other half of — that
    /// half is on a household member's private account, and only they can
    /// delete the transfer.
    func canDelete(_ entry: TransactionEntry) -> Bool {
        guard let groupId = entry.transaction.transferGroupId, entry.counterpart == nil else { return true }
        return completeTransferGroups.contains(groupId)
    }

    private func transferDeletion(groupId: UUID) async -> DeleteTransferPayload? {
        guard let ownerId = session.profile?.id, let baseCurrency = session.profile?.baseCurrency else { return nil }
        let legs = (try? await session.dbQueue.read { database in
            try LocalTransactionRow.fetchByTransferGroup(
                database, transferGroupId: groupId.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
            )
        }) ?? []
        guard
            let fromVersion = legs.first(where: { ($0.amountE4 ?? 0) < 0 })?.version,
            let toVersion = legs.first(where: { ($0.amountE4 ?? 0) > 0 })?.version
        else { return nil }
        return DeleteTransferPayload(
            transferGroupId: groupId, fromExpectedVersion: Int(fromVersion), toExpectedVersion: Int(toVersion)
        )
    }

    /// The Transactions screen's own quick "Confirm" swipe action — an
    /// alternative to opening the full review form, same local-first outbox
    /// path `NeedsReviewView`'s own swipe action and `TransactionFormView`'s
    /// Save use. `session.refresh.bump()` is what makes the row's "Pending"
    /// badge disappear here AND clears it out of Needs Review, both reading
    /// the same local `status` column this write just flipped.
    func confirmCapture(_ transaction: PublicSchema.TransactionsWithDetailsSelect) async {
        guard let id = transaction.transactionId, let version = transaction.version else { return }
        await session.outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: id, expectedVersion: Int(version))
        )
        session.refresh.bump()
    }
}

private struct LoadedTransactionsState {
    let transactions: [PublicSchema.TransactionsWithDetailsSelect]
    let categories: [PublicSchema.CategoriesSelect]
    let accounts: [LocalAccountRow]
    let completeTransferGroups: Set<String>
    let allAccountsBalance: AccountFilterBalance?
    let availableSources: [PublicSchema.TransactionSource]
}

/// What `load()` re-runs on — the list's `.task(id:)` key. Beside `load()`
/// rather than in TransactionsListView.swift, which is at its file-length limit.
struct TransactionsLoadKey: Equatable {
    let token: Int
    let scope: PublicSchema.AccountScope
    let filter: TransactionFilter
    /// Optional for the same reason `range` is — All Time re-keys the load
    /// exactly like any other change of period.
    let range: DateInterval?
}
