import KeepoCore
import SwiftUI

/// Loading and resolving — split out of ConflictDetailSheet.swift purely to
/// keep that file under the project's file-length/type-body-length lint
/// thresholds. Reads/writes the `@State` declared there.
extension ConflictDetailSheet {
    /// Pulls first, so the saved card is what the server holds now — and so a
    /// conflict a deletion or another device has since closed opens as
    /// settled rather than as a choice. Then everything is read locally;
    /// "your change" comes from the write the conflict kept, not from the
    /// network.
    func load() async {
        await session.syncEngine?.pull()
        guard let ownerId = session.profile?.id.uuidString, let baseCurrency = session.profile?.baseCurrency else {
            isLoading = false
            return
        }
        comparison = try? await session.dbQueue.read { database in
            try ConflictComparison.load(
                database, conflictId: conflictId.uuidString, ownerId: ownerId, baseCurrency: baseCurrency
            )
        }
        isLoading = false
    }

    /// The pull `load` made already left the saved version on this device —
    /// nothing to do but mark the conflict resolved.
    func keepSaved() async {
        guard let comparison else { return }
        isWorking = true
        await resolve(comparison.detail)
        isWorking = false
    }

    /// Sends the refused write again through the same call that made it,
    /// against the versions the rows are at now.
    func keepMine() async {
        guard let comparison else { return }
        let detail = comparison.detail
        isWorking = true
        defer { isWorking = false }
        await session.syncEngine?.pull()
        do {
            let applied: Bool
            if let attempted = detail.attemptedAccountWrite {
                if let account = try await session.dbQueue.read({ database in
                    try LocalTableQueries.account(database, id: detail.rowId)
                }) {
                    applied = try await attempted.replay(account: account, session: session)
                } else {
                    applied = false
                }
            } else if let attempted = detail.attemptedWrite, let rowId = UUID(uuidString: detail.rowId) {
                applied = await attempted.replay(
                    rowId: rowId, rowVersion: await localRowVersion(detail),
                    legVersions: await legVersions(attempted.transferGroupId), outbox: session.outbox
                )
            } else {
                applied = false
            }
            guard applied else {
                actionError = ActionError(
                    title: "Couldn't Use Your Change",
                    message: "This \(comparison.noun) has changed again or is no longer in Keepo. "
                        + "Close this and open it again to see the latest version."
                )
                return
            }
            await resolve(detail)
        } catch {
            actionError = ActionError("Couldn't Use Your Change", error)
        }
    }

    /// `nil` when the row is no longer on this device.
    func localRowVersion(_ detail: SyncConflictDetail) async -> Int? {
        try? await session.dbQueue.read { database in
            try LocalTableQueries.transaction(database, id: detail.rowId).map { Int($0.version) }
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
            actionError = ActionError("Couldn't Save Your Choice", error)
        }
    }
}
