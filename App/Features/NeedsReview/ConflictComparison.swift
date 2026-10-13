import Foundation
import GRDB
import KeepoCore

/// Everything the Sync Conflict sheet draws: the saved version, the version
/// the user's refused write would have made, and the fields where the two
/// disagree — each side as the tile the rest of the app already uses for it
/// (`TransactionRow` for a transaction or transfer, `AccountRowView` for an
/// account), so a conflict looks like the thing it is about.
///
/// "Mine" is built from the write the server kept (`attempted_payload`),
/// never from this device's copy of the row: by the time a conflict reaches
/// the inbox, the pull that delivered it has already replaced that copy with
/// the saved one. That is why an account conflict used to say "nothing looks
/// different" — it compared the saved account with itself.
struct ConflictComparison {
    enum Tile {
        case transaction(TransactionTile)
        case account(AccountTile)
    }

    struct TransactionTile {
        let row: PublicSchema.TransactionsWithDetailsSelect
        /// A transfer's other leg, which turns the row into "From → To".
        let counterpart: PublicSchema.TransactionsWithDetailsSelect?
        let category: PublicSchema.CategoriesSelect?
    }

    struct AccountTile {
        let row: LocalAccountRow
        let includeInTotal: Bool
    }

    struct Side {
        let tile: Tile
        /// This side is "it should be gone" — the refused write was a delete.
        var isDeleted = false
    }

    let detail: SyncConflictDetail
    /// "transaction", "transfer" or "account" — what the sheet calls it.
    let noun: String
    /// `nil` when the thing is no longer on this device at all.
    let saved: Side?
    /// `nil` when the conflict kept no record of what was attempted (one
    /// recorded before its table started keeping them).
    let mine: Side?
    /// The account the refused write was about, for "Keep My Change".
    let account: PublicSchema.AccountsSelect?
    let fields: [ConflictField]

    /// The date each card shows under a transaction tile: the saved one, and
    /// the one the change asked for (the saved one when it left it alone).
    var savedDate: String? {
        guard case .transaction(let tile)? = saved?.tile else { return nil }
        return Self.formattedDate(tile.row.occurredAt)
    }

    var requestedDate: String? {
        fields.first { $0.placement == .date }?.mine ?? savedDate
    }

    /// There is a real choice only when both sides exist and differ. A
    /// delete differs from anything still there, with no field to show it.
    var hasChoice: Bool {
        guard let saved, let mine else { return false }
        return mine.isDeleted != saved.isDeleted || !fields.isEmpty
    }
}

/// One field the two versions disagree on: its saved value, the value the
/// change asked for (`""` when a version has none), and where the "Your
/// change" card draws it — on the tile, struck through and replaced, or on a
/// line of its own when the tile has nowhere to show it (a date, a note).
struct ConflictField: Identifiable {
    let label: String
    let mine: String
    let saved: String
    let placement: Placement
    var id: String { label }

    enum Placement: Hashable {
        case transaction(TransactionRow.Part)
        case account(AccountRowView.Part)
        case line
        /// A transaction's date, which each card shows as its own — never struck.
        case date
    }
}

/// How one field is read off a version, and where it is drawn.
private struct ConflictProbe<Tile> {
    let label: String
    let placement: ConflictField.Placement
    let value: (Tile) -> String

    func field(_ mine: Tile, _ saved: Tile) -> ConflictField? {
        let mineValue = value(mine)
        let savedValue = value(saved)
        guard mineValue != savedValue else { return nil }
        return ConflictField(label: label, mine: mineValue, saved: savedValue, placement: placement)
    }
}

extension ConflictComparison {
    /// Reads both sides from the local mirror. The caller pulls first, so the
    /// saved side is what the server holds.
    static func load(
        _ database: Database, conflictId: String, ownerId: String, baseCurrency: String
    ) throws -> ConflictComparison? {
        guard let detail = try ConflictLocalQueries.detail(database, id: conflictId),
              try Bool.fetchOne(
                  database, sql: "SELECT resolved_at IS NULL FROM sync_conflicts WHERE id = ?", arguments: [conflictId]
              ) == true
        else { return nil }
        if detail.tableName == "accounts" {
            return try accountComparison(database, detail: detail, ownerId: ownerId, baseCurrency: baseCurrency)
        }
        return try transactionComparison(database, detail: detail, ownerId: ownerId, baseCurrency: baseCurrency)
    }

    // MARK: Transactions

    private static func transactionComparison(
        _ database: Database, detail: SyncConflictDetail, ownerId: String, baseCurrency: String
    ) throws -> ConflictComparison {
        let saved = try LocalTransactionRow.fetchOne(
            database, id: detail.rowId, baseCurrency: baseCurrency, ownerId: ownerId
        )
        let groupId = saved?.transferGroupId?.uuidString
        let savedLegs = try groupId.map {
            try LocalTransactionRow.fetchByTransferGroup(
                database, transferGroupId: $0, baseCurrency: baseCurrency, ownerId: ownerId
            )
        } ?? []
        let savedTile = try saved.map { try tile($0, legs: savedLegs, database) }

        var mineTile: TransactionTile?
        var mineDeletes = false
        if let attempted = detail.attemptedWrite, let saved {
            switch attempted.rpc {
            case "delete_transaction", "delete_transfer":
                mineTile = savedTile
                mineDeletes = true
            case "update_transfer":
                let legs = try transferLegs(attempted, saved: savedLegs, database, ownerId, baseCurrency)
                let row = legs.first { $0.transactionId == saved.transactionId } ?? saved
                mineTile = try tile(row, legs: legs, database)
            default:
                mineTile = try LocalTransactionRow.preview(
                    database, id: detail.rowId, changing: ledgerChanges(attempted, savedStatus: saved.status),
                    baseCurrency: baseCurrency, ownerId: ownerId
                ).map { try tile($0, legs: [], database) }
            }
        }

        let fields = mineDeletes ? [] : both(mineTile, savedTile).map { transactionFields($0.0, $0.1) } ?? []
        return ConflictComparison(
            detail: detail, noun: groupId == nil ? "transaction" : "transfer",
            saved: savedTile.map { Side(tile: .transaction($0)) },
            mine: mineTile.map { Side(tile: .transaction($0), isDeleted: mineDeletes) },
            account: nil, fields: fields
        )
    }

    /// A ledger edit, review or confirm, as the columns it would change. A
    /// review and a confirm both leave the row confirmed; an edit leaves the
    /// status as it was saved.
    private static func ledgerChanges(
        _ attempted: AttemptedTransactionWrite, savedStatus: PublicSchema.TransactionStatus?
    ) -> [String: (any DatabaseValueConvertible)?] {
        guard attempted.rpc != "confirm_capture_transaction" else { return ["status": "confirmed"] }
        var changes = shared(attempted)
        changes["status"] = attempted.rpc == "update_transaction" ? savedStatus?.rawValue : "confirmed"
        changes["account_id"] = attempted.accountId?.uuidString
        changes["category_id"] = attempted.categoryId?.uuidString
        changes["amount_e4"] = attempted.amountE4
        changes["merchant_raw"] = attempted.merchantRaw
        changes["original_amount_e4"] = attempted.originalAmountE4
        changes["original_currency"] = attempted.originalCurrency
        return changes
    }

    /// Both legs of a transfer as the refused edit would have left them.
    private static func transferLegs(
        _ attempted: AttemptedTransactionWrite, saved legs: [PublicSchema.TransactionsWithDetailsSelect],
        _ database: Database, _ ownerId: String, _ baseCurrency: String
    ) throws -> [PublicSchema.TransactionsWithDetailsSelect] {
        try legs.compactMap { leg in
            guard let id = leg.transactionId?.uuidString else { return nil }
            let sending = (leg.amountE4 ?? 0) < 0
            var changes = shared(attempted)
            changes["account_id"] = (sending ? attempted.fromAccountId : attempted.toAccountId)?.uuidString
                ?? leg.accountId?.uuidString
            if let amount = sending ? attempted.fromAmountE4.map({ -$0 }) : attempted.toAmountE4 {
                changes["amount_e4"] = amount
            }
            return try LocalTransactionRow.preview(
                database, id: id, changing: changes, baseCurrency: baseCurrency, ownerId: ownerId
            )
        }
    }

    /// The fields a ledger edit and a transfer edit share.
    private static func shared(_ attempted: AttemptedTransactionWrite) -> [String: (any DatabaseValueConvertible)?] {
        var changes: [String: (any DatabaseValueConvertible)?] = [
            "notes": attempted.notes, "title": attempted.title
        ]
        if let date = attempted.occurredAtDate {
            changes["occurred_at"] = PostgresDate.sqliteTimestampBoundaryString(date)
        }
        return changes
    }

    /// The row the ledger would draw: one leg folded with its partner for a
    /// transfer, the sending leg first, as `TransactionEntry` does.
    private static func tile(
        _ row: PublicSchema.TransactionsWithDetailsSelect, legs: [PublicSchema.TransactionsWithDetailsSelect],
        _ database: Database
    ) throws -> TransactionTile {
        let partner = legs.first { $0.transactionId != row.transactionId }
        let category = try row.categoryId.flatMap { try LocalTableQueries.category(database, id: $0.uuidString) }
        return TransactionTile(row: row, counterpart: partner, category: category)
    }

    private typealias TransactionProbe = ConflictProbe<TransactionTile>

    private static func transactionFields(_ mine: TransactionTile, _ saved: TransactionTile) -> [ConflictField] {
        let probes = (saved.counterpart != nil ? transferProbes : ledgerProbes) + sharedProbes
        return probes.compactMap { $0.field(mine, saved) }
    }

    private static var transferProbes: [TransactionProbe] { [
        TransactionProbe(label: "From", placement: .transaction(.fromAccount)) { sending($0).accountName ?? "" },
        TransactionProbe(label: "To", placement: .transaction(.toAccount)) { receiving($0)?.accountName ?? "" },
        TransactionProbe(label: "Amount", placement: .transaction(.amount)) {
            amount(sending($0), style: .magnitude)
        },
        // Only a transfer between two currencies has a second amount; for
        // the rest this is empty on both sides, so it never shows.
        TransactionProbe(label: "Received", placement: .line, value: received)
    ] }

    private static var ledgerProbes: [TransactionProbe] { [
        TransactionProbe(label: "Amount", placement: .transaction(.amount)) { amount($0.row, style: .ledger) },
        TransactionProbe(label: "Category", placement: .transaction(.category)) { $0.row.categoryName ?? "" },
        TransactionProbe(label: "Account", placement: .transaction(.account)) { $0.row.accountName ?? "" },
        TransactionProbe(label: "Merchant", placement: .transaction(.merchant)) { $0.row.merchantRaw ?? "" },
        TransactionProbe(label: "Status", placement: .transaction(.status)) {
            $0.row.status == .pending ? "Pending" : "Confirmed"
        },
        TransactionProbe(label: "Paid", placement: .line) { paid($0.row) }
    ] }

    private static var sharedProbes: [TransactionProbe] { [
        TransactionProbe(label: "Title", placement: .transaction(.headline)) { $0.row.title ?? "" },
        TransactionProbe(label: "Date", placement: .date) { formattedDate($0.row.occurredAt) },
        TransactionProbe(label: "Note", placement: .line) { $0.row.notes ?? "" }
    ] }

    /// What a transfer delivered, when it crossed currencies — empty otherwise.
    private static func received(_ tile: TransactionTile) -> String {
        guard let arriving = receiving(tile), arriving.currency != sending(tile).currency else { return "" }
        return amount(arriving, style: .magnitude)
    }

    private static func sending(_ tile: TransactionTile) -> PublicSchema.TransactionsWithDetailsSelect {
        guard let counterpart = tile.counterpart, (tile.row.amountE4 ?? 0) > 0 else { return tile.row }
        return counterpart
    }

    private static func receiving(_ tile: TransactionTile) -> PublicSchema.TransactionsWithDetailsSelect? {
        guard let counterpart = tile.counterpart else { return nil }
        return (tile.row.amountE4 ?? 0) > 0 ? tile.row : counterpart
    }

    private static func amount(_ row: PublicSchema.TransactionsWithDetailsSelect, style: MoneySignStyle) -> String {
        guard let code = row.currency, let minorUnit = row.minorUnit else { return "—" }
        let currency = CurrencyInfo(code: code, minorUnit: Int(minorUnit))
        return MoneyFormatter.format(row.amountE4, currency: currency, signStyle: style, exact: true)
    }

    private static func paid(_ row: PublicSchema.TransactionsWithDetailsSelect) -> String {
        guard let code = row.originalCurrency else { return "" }
        let currency = CurrencyInfo(code: code, minorUnit: Int(row.originalMinorUnit ?? 2))
        return MoneyFormatter.format(row.originalAmountE4, currency: currency, signStyle: .magnitude, exact: true)
    }

    static func formattedDate(_ timestamp: String?) -> String {
        guard let timestamp, let date = PostgresDate.date(fromTimestamp: timestamp) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Accounts

    private static func accountComparison(
        _ database: Database, detail: SyncConflictDetail, ownerId: String, baseCurrency: String
    ) throws -> ConflictComparison {
        let account = try LocalTableQueries.account(database, id: detail.rowId)
        let savedRow = try LocalAccountRow.fetchOne(
            database, id: detail.rowId, ownerId: ownerId, baseCurrency: baseCurrency
        )
        let saved = both(savedRow, account).map { AccountTile(row: $0.0, includeInTotal: $0.1.includeInTotal) }

        var mine: AccountTile?
        if let attempted = detail.attemptedAccountWrite, let saved {
            let row = saved.row
            switch attempted.rpc {
            case "update_account":
                mine = AccountTile(
                    row: try row.changing(
                        name: attempted.name, icon: attempted.icon, color: attempted.color, in: database
                    ),
                    includeInTotal: attempted.includeInTotal ?? saved.includeInTotal
                )
            case "set_account_balance":
                mine = AccountTile(
                    row: try row.changing(balanceE4: attempted.newBalanceE4, in: database),
                    includeInTotal: saved.includeInTotal
                )
            case "archive_account":
                mine = AccountTile(
                    row: try row.changing(archived: attempted.archived, in: database),
                    includeInTotal: saved.includeInTotal
                )
            case "set_account_kind":
                mine = AccountTile(
                    row: try row.changing(kind: attempted.kind, in: database), includeInTotal: saved.includeInTotal
                )
            case "delete_account":
                mine = saved
            default:
                mine = nil
            }
        }
        let deletes = detail.attemptedAccountWrite?.isDelete == true
        let fields = deletes ? [] : both(mine, saved).map { accountFields($0.0, $0.1) } ?? []
        return ConflictComparison(
            detail: detail, noun: "account",
            saved: saved.map { Side(tile: .account($0)) },
            mine: mine.map { Side(tile: .account($0), isDeleted: deletes) },
            account: account, fields: fields
        )
    }

    private static func accountFields(_ mine: AccountTile, _ saved: AccountTile) -> [ConflictField] {
        typealias Probe = ConflictProbe<AccountTile>
        let probes: [Probe] = [
            Probe(label: "Name", placement: .account(.name)) { $0.row.name },
            Probe(label: "Type", placement: .account(.kind)) { $0.row.kind == .investment ? "Investment" : "" },
            Probe(label: "Balance", placement: .account(.balance)) {
                MoneyFormatter.format($0.row.balanceE4, currency: $0.row.currencyInfo, exact: true)
            },
            Probe(label: "Status", placement: .line) { $0.row.archivedAt == nil ? "Active" : "Archived" },
            Probe(label: "Counts in totals", placement: .line) { $0.includeInTotal ? "Yes" : "No" },
            Probe(label: "Icon and colour", placement: .line) { "\($0.row.icon) \($0.row.color)" }
        ]
        return probes.compactMap { $0.field(mine, saved) }.map { field in
            // An icon name and a hex colour mean nothing written down.
            guard field.label == "Icon and colour" else { return field }
            return ConflictField(label: field.label, mine: "New", saved: "Previous", placement: .line)
        }
    }
}

/// Both values, or neither.
private func both<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
