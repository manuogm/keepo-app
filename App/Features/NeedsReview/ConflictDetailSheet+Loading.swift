import KeepoCore
import SwiftUI

/// Loading, diffing, and resolving — split out of ConflictDetailSheet.swift
/// purely to keep that file under the project's file-length/type-body-
/// length lint thresholds. Reads/writes the `@State` declared there.
extension ConflictDetailSheet {
    /// Captures "my version" — the local mirror's current, still-optimistic
    /// field values — before either action below ever pulls, since a pull
    /// overwrites this same row with the server's authoritative one. Then
    /// fetches the server's row straight over the network (not the local
    /// mirror, which by definition hasn't caught up yet) to build the diff.
    func load() async {
        var loaded = try? await session.dbQueue.read({ database in
            try ConflictLocalQueries.detail(database, id: conflictId.uuidString)
        })
        // A conflict tile is only ever shown once it exists in the local
        // mirror, but a pull that's still in flight at the exact moment the
        // sheet opens (e.g. right after a fresh install) can leave a brief
        // window where the row genuinely isn't there yet — indistinguishable
        // locally from "already resolved." One retry after a pull rules
        // that out before falling back to the empty state.
        if loaded == nil {
            await session.syncEngine?.pull()
            loaded = try? await session.dbQueue.read({ database in
                try ConflictLocalQueries.detail(database, id: conflictId.uuidString)
            })
        }
        guard let loaded else {
            isLoading = false
            return
        }
        detail = loaded

        if loaded.tableName == "accounts" {
            myAccount = try? await session.dbQueue.read { database in
                try LocalTableQueries.account(database, id: loaded.rowId)
            }
            await loadAccountFields(rowId: loaded.rowId)
        } else if let baseCurrency = session.profile?.baseCurrency, let ownerId = session.profile?.id {
            myTransaction = try? await session.dbQueue.read { database in
                try LocalTransactionRow.fetchOne(
                    database, id: loaded.rowId, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                )
            }
            await loadTransactionFields(rowId: loaded.rowId)
        }
        isLoading = false
    }

    func loadAccountFields(rowId: String) async {
        guard let id = UUID(uuidString: rowId) else { return }
        guard let server = try? await AccountRepository.fetchOne(client: session.client, id: id) else {
            couldNotReachServer = true
            return
        }
        guard let mine = myAccount else { return }
        var built: [ConflictField] = []
        if mine.name != server.name {
            built.append(ConflictField(label: "Name", mine: mine.name, server: server.name))
        }
        let mineStatus = mine.archivedAt == nil ? "Active" : "Archived"
        let serverStatus = server.archivedAt == nil ? "Active" : "Archived"
        if mineStatus != serverStatus {
            built.append(ConflictField(label: "Status", mine: mineStatus, server: serverStatus))
        }
        fields = built
    }

    func loadTransactionFields(rowId: String) async {
        guard let id = UUID(uuidString: rowId) else { return }
        guard let server = try? await TransactionRepository.fetchOne(client: session.client, id: id) else {
            couldNotReachServer = true
            return
        }
        // What the rejected write actually said, when the conflict kept it —
        // not this device's copy, which a pull may already have overwritten
        // and which never held a delete at all.
        if let attempted = detail?.attemptedWrite {
            fields = attemptedFields(attempted, server: server)
            return
        }
        guard let mine = myTransaction else { return }
        var built: [ConflictField] = []
        let mineAmount = formattedAmount(mine)
        let serverAmount = formattedAmount(server)
        if mineAmount != serverAmount {
            built.append(ConflictField(label: "Amount", mine: mineAmount, server: serverAmount))
        }
        let mineWho = mine.merchantRaw ?? mine.categoryName ?? "—"
        let serverWho = server.merchantRaw ?? server.categoryName ?? "—"
        if mineWho != serverWho {
            built.append(ConflictField(label: "Merchant / Category", mine: mineWho, server: serverWho))
        }
        let mineDate = formattedDate(mine.occurredAt)
        let serverDate = formattedDate(server.occurredAt)
        if mineDate != serverDate {
            built.append(ConflictField(label: "Date", mine: mineDate, server: serverDate))
        }
        fields = built
    }

    func formattedAmount(_ transaction: PublicSchema.TransactionsWithDetailsSelect) -> String {
        guard let amount = transaction.amountE4, let currency = transaction.currency else { return "—" }
        let info = CurrencyInfo(code: currency, minorUnit: Int(transaction.minorUnit ?? 2))
        return MoneyFormatter.format(amount, currency: info)
    }

    func formattedDate(_ timestamp: String?) -> String {
        guard let timestamp, let date = PostgresDate.date(fromTimestamp: timestamp) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The pull alone already corrects the local mirror to the server's
    /// row — nothing left to do but mark the conflict resolved.
    func keepServer() async {
        guard let detail else { return }
        isWorking = true
        errorMessage = nil
        await session.syncEngine?.pull()
        await resolve(detail)
        isWorking = false
    }

    func keepMine() async {
        guard let detail else { return }
        isWorking = true
        errorMessage = nil
        await session.syncEngine?.pull()
        let freshVersion = await currentServerVersion(detail)
        if detail.tableName == "accounts", let myAccount {
            _ = await session.outbox.submitArchiveAccount(
                ArchiveAccountPayload(
                    id: myAccount.id, expectedVersion: freshVersion, archived: myAccount.archivedAt != nil
                )
            ).value
        } else if let attempted = detail.attemptedWrite, let rowId = UUID(uuidString: detail.rowId) {
            // Replayed through the same call it was, whatever kind it was —
            // including a transfer, which the rebuild below could never
            // express (it needs a category) and so used to skip before
            // marking the conflict resolved.
            let replayed = await attempted.replay(
                rowId: rowId, rowVersion: await localRowVersion(detail),
                legVersions: await legVersions(attempted.transferGroupId), outbox: session.outbox
            )
            guard replayed else {
                errorMessage = "Your version can't be applied any more — this transaction has since been deleted."
                isWorking = false
                return
            }
        } else if let myTransaction, let id = myTransaction.transactionId, let categoryId = myTransaction.categoryId {
            _ = await session.outbox.submitUpdateTransaction(
                UpdateTransactionPayload(
                    id: id, expectedVersion: freshVersion,
                    accountId: myTransaction.accountId ?? UUID(), categoryId: categoryId,
                    amountE4: myTransaction.amountE4 ?? 0, currency: myTransaction.currency ?? "USD",
                    occurredAt: PostgresDate.date(fromTimestamp: myTransaction.occurredAt ?? "") ?? Date(),
                    merchantRaw: myTransaction.merchantRaw, notes: myTransaction.notes,
                    title: myTransaction.title
                )
            ).value
        }
        await resolve(detail)
        isWorking = false
    }

    /// After the pull above, the local row's own `version` IS the server's
    /// current one — no separate network round trip needed to learn it.
    func currentServerVersion(_ detail: SyncConflictDetail) async -> Int {
        await localRowVersion(detail) ?? detail.serverVersion
    }

    /// `nil` when the row is no longer on this device.
    func localRowVersion(_ detail: SyncConflictDetail) async -> Int? {
        try? await session.dbQueue.read { database in
            if detail.tableName == "accounts" {
                return try LocalTableQueries.account(database, id: detail.rowId).map { Int($0.version) }
            }
            return try LocalTableQueries.transaction(database, id: detail.rowId).map { Int($0.version) }
        }
    }

    /// Both halves' versions as they are now, for replaying a transfer
    /// write. `nil` unless the device holds both.
    func legVersions(_ transferGroupId: UUID?) async -> (from: Int, to: Int)? {
        guard let transferGroupId, let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency else { return nil }
        let legs = (try? await session.dbQueue.read { database in
            try LocalTransactionRow.fetchByTransferGroup(
                database, transferGroupId: transferGroupId.uuidString, baseCurrency: baseCurrency,
                ownerId: ownerId.uuidString
            )
        }) ?? []
        guard
            let from = legs.first(where: { ($0.amountE4 ?? 0) < 0 })?.version,
            let destination = legs.first(where: { ($0.amountE4 ?? 0) > 0 })?.version
        else { return nil }
        return (Int(from), Int(destination))
    }

    /// The diff for a conflict that kept its attempted write: amount and date
    /// against the server's row, and — for a delete, which changes neither —
    /// a line saying that the change was a delete.
    func attemptedFields(
        _ attempted: AttemptedTransactionWrite, server: PublicSchema.TransactionsWithDetailsSelect
    ) -> [ConflictField] {
        if attempted.rpc == "delete_transaction" || attempted.rpc == "delete_transfer" {
            return [ConflictField(label: "Change", mine: "Delete", server: "Keep")]
        }
        var built: [ConflictField] = []
        let serverAmount = formattedAmount(server)
        if let amount = attempted.attemptedAmountE4, let currency = attempted.currency ?? server.currency {
            let mineAmount = MoneyFormatter.format(
                amount, currency: CurrencyInfo(code: currency, minorUnit: Int(server.minorUnit ?? 2))
            )
            if mineAmount != serverAmount {
                built.append(ConflictField(label: "Amount", mine: mineAmount, server: serverAmount))
            }
        }
        if let date = attempted.occurredAtDate {
            let mineDate = date.formatted(date: .abbreviated, time: .shortened)
            let serverDate = formattedDate(server.occurredAt)
            if mineDate != serverDate {
                built.append(ConflictField(label: "Date", mine: mineDate, server: serverDate))
            }
        }
        return built
    }

    func resolve(_ detail: SyncConflictDetail) async {
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: detail.id)
            try? await session.dbQueue.write { database in
                try ConflictLocalQueries.markResolved(id: detail.id.uuidString, in: database)
            }
            session.refresh.bump()
            onResolved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }
}
