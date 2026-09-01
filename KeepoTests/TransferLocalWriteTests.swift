import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `Outbox.submitCreateTransfer`'s local write-through — split into its own
/// file following the same precedent as `ConfirmCaptureLocalWriteTests.swift`
/// and `CardMappingLocalWriteTests.swift`.
///
/// A transfer is the one write where the mirror has to reproduce a decision
/// the server makes rather than just copy a payload: `create_transfer` takes
/// a positive magnitude, applies the signs itself, and derives the receiving
/// amount when the two accounts share a currency. Everything here pins that
/// this file makes the same three decisions the function does.
@Suite("Transfer local write-through")
@MainActor
struct TransferLocalWriteTests {
    private func makeOutboxAndDatabase() throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender()), dbQueue)
    }

    private func seedAccount(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, currency: String = "EUR"
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Test', ?, 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString, currency]
            )
        }
    }

    /// Opening balance plus the sum of the account's own rows — money rule
    /// 1's single balance formula, read straight rather than through a view,
    /// so a wrongly-signed leg shows up as a wrong balance here.
    private func balance(_ dbQueue: DatabaseQueue, accountId: UUID) async throws -> Int64 {
        try await dbQueue.read { database in
            try Int64.fetchOne(
                database,
                sql: """
                SELECT COALESCE((SELECT opening_balance_e4 FROM accounts WHERE id = ?), 0)
                     + COALESCE((SELECT SUM(amount_e4) FROM transactions
                                 WHERE account_id = ? AND deleted_at IS NULL), 0)
                """,
                arguments: [accountId.uuidString, accountId.uuidString]
            ) ?? 0
        }
    }

    /// The payload carries a positive MAGNITUDE, the same thing
    /// `create_transfer` takes — this used to hand the write-through an
    /// already-negative `fromAmountE4`, which no caller produces
    /// (`saveTransfer` passes `magnitude`) and which is precisely why the
    /// sign bug below could live here unnoticed.
    @Test("both legs of a created transfer move both accounts' local balances")
    func createTransferAppliesBothLegsLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let fromAccountId = UUID()
        let toAccountId = UUID()
        try await seedAccount(dbQueue, id: fromAccountId, ownerId: ownerId)
        try await seedAccount(dbQueue, id: toAccountId, ownerId: ownerId)

        _ = await outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: UUID(), toId: UUID(), fromAccountId: fromAccountId, toAccountId: toAccountId,
                fromAmountE4: 30000, toAmountE4: 30000, occurredAt: Date()
            )
        )

        #expect(try await balance(dbQueue, accountId: fromAccountId) == -30000)
        #expect(try await balance(dbQueue, accountId: toAccountId) == 30000)
    }

    /// The real same-currency path: the form sends no received amount,
    /// because the two accounts already agree on the figure. Both legs must
    /// still land, and the sending one must be NEGATIVE — this wrote a lone
    /// positive leg, so a just-created transfer showed as green income on
    /// the account the money had left, and moved that balance upwards.
    @Test("a same-currency transfer sends no received amount and still writes both legs, correctly signed")
    func sameCurrencyTransferMirrorsTheAmountAndSigns() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let fromAccountId = UUID()
        let toAccountId = UUID()
        try await seedAccount(dbQueue, id: fromAccountId, ownerId: ownerId, currency: "EUR")
        try await seedAccount(dbQueue, id: toAccountId, ownerId: ownerId, currency: "EUR")

        _ = await outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: UUID(), toId: UUID(), fromAccountId: fromAccountId, toAccountId: toAccountId,
                fromAmountE4: 140_000, toAmountE4: nil, occurredAt: Date()
            )
        )

        #expect(try await balance(dbQueue, accountId: fromAccountId) == -140_000)
        #expect(try await balance(dbQueue, accountId: toAccountId) == 140_000)
    }

    /// Both legs have to carry the SAME `transfer_group_id`, or the ledger
    /// cannot pair them into one row and an offline edit or delete — both
    /// of which match by group — reaches only half the transfer.
    @Test("both legs share one transfer group id")
    func bothLegsShareAGroupId() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let fromAccountId = UUID()
        let toAccountId = UUID()
        try await seedAccount(dbQueue, id: fromAccountId, ownerId: ownerId)
        try await seedAccount(dbQueue, id: toAccountId, ownerId: ownerId)

        _ = await outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: UUID(), toId: UUID(), fromAccountId: fromAccountId, toAccountId: toAccountId,
                fromAmountE4: 50000, toAmountE4: nil, occurredAt: Date()
            )
        )

        let groups = try await dbQueue.read { database in
            try String.fetchAll(
                database, sql: "SELECT DISTINCT transfer_group_id FROM transactions WHERE deleted_at IS NULL"
            )
        }
        #expect(groups.count == 1)
    }

    /// `create_transfer` RAISES for a cross-currency transfer with no
    /// received amount, so the mirror must not describe one. It used to
    /// write the sending leg and bail, leaving a permanent half-transfer
    /// the server had no row to correct.
    @Test("a cross-currency transfer with no received amount writes neither leg")
    func crossCurrencyWithoutReceivedAmountWritesNothing() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let fromAccountId = UUID()
        let toAccountId = UUID()
        try await seedAccount(dbQueue, id: fromAccountId, ownerId: ownerId, currency: "EUR")
        try await seedAccount(dbQueue, id: toAccountId, ownerId: ownerId, currency: "USD")

        _ = await outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: UUID(), toId: UUID(), fromAccountId: fromAccountId, toAccountId: toAccountId,
                fromAmountE4: 90000, toAmountE4: nil, occurredAt: Date()
            )
        )

        #expect(try await balance(dbQueue, accountId: fromAccountId) == 0)
        #expect(try await balance(dbQueue, accountId: toAccountId) == 0)
    }

    @Test("a cross-currency transfer with a received amount writes each leg in its own currency")
    func crossCurrencyKeepsEachLegsOwnAmount() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let fromAccountId = UUID()
        let toAccountId = UUID()
        try await seedAccount(dbQueue, id: fromAccountId, ownerId: ownerId, currency: "EUR")
        try await seedAccount(dbQueue, id: toAccountId, ownerId: ownerId, currency: "USD")

        _ = await outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: UUID(), toId: UUID(), fromAccountId: fromAccountId, toAccountId: toAccountId,
                fromAmountE4: 1_000_000, toAmountE4: 1_100_000, occurredAt: Date()
            )
        )

        #expect(try await balance(dbQueue, accountId: fromAccountId) == -1_000_000)
        #expect(try await balance(dbQueue, accountId: toAccountId) == 1_100_000)
    }
}
