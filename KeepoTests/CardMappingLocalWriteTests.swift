import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// Card-mapping local write-through — split out of `OutboxLocalWriteTests.swift`
/// purely to keep that file under the project's file-length lint threshold.
/// Covers both the auto-link `OutboxLocalWrite.updateTransaction` performs
/// when a previously-unmapped capture's account is finally assigned, and
/// the Account edit sheet's own rename/unmap writes.
@Suite("Card mapping local write-through")
@MainActor
struct CardMappingLocalWriteTests {
    private func makeOutboxAndDatabase() throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender()), dbQueue)
    }

    private func seedAccount(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, subtype, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'ledger', 'checking', 'Test', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString]
            )
        }
    }

    private func seedDefaultCategory(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, 'expense', 'Other', 1, 'cart', '#000', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString]
            )
        }
    }

    private func seedCardMapping(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, cardIdentifier: String, accountId: UUID
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, cardIdentifier, accountId.uuidString]
            )
        }
    }

    @Test("resolving a previously-unmapped capture's account via update also auto-links the card locally")
    func updateTransactionAutoLinksCardLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let defaultCategoryId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedDefaultCategory(dbQueue, id: defaultCategoryId, ownerId: ownerId)

        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-to-link", merchantRaw: "Burger King", merchantNormalized: "BURGER KING",
            amountE4: 1066, occurredAt: Date(), externalId: "ext-3"
        )
        _ = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)

        _ = await outbox.submitUpdateTransaction(
            UpdateTransactionPayload(
                id: payload.id, expectedVersion: 1, accountId: accountId, categoryId: defaultCategoryId,
                amountE4: -1066, currency: "EUR", occurredAt: Date(), merchantRaw: "Burger King"
            )
        )

        let transactionAccountId = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT account_id FROM transactions WHERE id = ?", arguments: [payload.id.uuidString]
            )
        }
        #expect(transactionAccountId == accountId.uuidString)

        let mappedAccountId = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT account_id FROM card_mappings WHERE owner_id = ? AND card_identifier = ?",
                arguments: [ownerId.uuidString, "card-to-link"]
            )
        }
        #expect(mappedAccountId == accountId.uuidString)
    }

    @Test("confirming a capture flips its status to confirmed locally, version-checked")
    func confirmCaptureTransactionAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let defaultCategoryId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedDefaultCategory(dbQueue, id: defaultCategoryId, ownerId: ownerId)
        try await seedCardMapping(
            dbQueue, id: UUID(), ownerId: ownerId, cardIdentifier: "card-to-confirm", accountId: accountId
        )

        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-to-confirm", merchantRaw: "Coffee", merchantNormalized: "COFFEE",
            amountE4: 500, occurredAt: Date(), externalId: "ext-4"
        )
        _ = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)

        _ = await outbox.submitConfirmCaptureTransaction(
            ConfirmCaptureTransactionPayload(id: payload.id, expectedVersion: 1)
        )

        let status = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT status FROM transactions WHERE id = ?", arguments: [payload.id.uuidString]
            )
        }
        #expect(status == "confirmed")
    }

    @Test("manually mapping a card upserts it locally by the (owner, card) natural key")
    func mapCardAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)

        _ = await outbox.submitMapCard(
            MapCardPayload(id: UUID(), ownerId: ownerId, cardIdentifier: "Amex", accountId: accountId)
        )

        let mappedAccountId = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT account_id FROM card_mappings WHERE owner_id = ? AND card_identifier = ?",
                arguments: [ownerId.uuidString, "Amex"]
            )
        }
        #expect(mappedAccountId == accountId.uuidString)
    }

    @Test("renaming a card mapping updates its identifier locally, keyed by its own id")
    func renameCardMappingAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let mappingId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCardMapping(
            dbQueue, id: mappingId, ownerId: ownerId, cardIdentifier: "Old Name", accountId: accountId
        )

        _ = await outbox.submitRenameCardMapping(RenameCardMappingPayload(id: mappingId, cardIdentifier: "Revolut"))

        let identifier = try await dbQueue.read { database in
            try String.fetchOne(
                database, sql: "SELECT card_identifier FROM card_mappings WHERE id = ?",
                arguments: [mappingId.uuidString]
            )
        }
        #expect(identifier == "Revolut")
    }

    @Test("unmapping a card sets deleted_at locally, not account_id back to null")
    func unmapCardAppliesLocally() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let mappingId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedCardMapping(
            dbQueue, id: mappingId, ownerId: ownerId, cardIdentifier: "Revolut", accountId: accountId
        )

        _ = await outbox.submitUnmapCard(UnmapCardPayload(id: mappingId))

        let row = try await dbQueue.read { database in
            try Row.fetchOne(
                database, sql: "SELECT deleted_at, account_id FROM card_mappings WHERE id = ?",
                arguments: [mappingId.uuidString]
            )
        }
        #expect((row?["deleted_at"] as String?) != nil)
        #expect(row?["account_id"] == accountId.uuidString)
    }
}

private enum StubError: Error { case alwaysFails }

private final class AlwaysFailingSender: OutboxSending, @unchecked Sendable {
    func createTransaction(_ payload: CreateTransactionPayload) async throws { throw StubError.alwaysFails }
    func createTransfer(_ payload: CreateTransferPayload) async throws { throw StubError.alwaysFails }
    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool { throw StubError.alwaysFails }
    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool { throw StubError.alwaysFails }
    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool { throw StubError.alwaysFails }
    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool { throw StubError.alwaysFails }
    func captureTransaction(_ payload: CaptureTransactionPayload) async throws {
        throw StubError.alwaysFails
    }
    func createAccount(_ payload: CreateAccountPayload) async throws { throw StubError.alwaysFails }
    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool { throw StubError.alwaysFails }
    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool { throw StubError.alwaysFails }
    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool { throw StubError.alwaysFails }
    func createCategory(_ payload: CreateCategoryPayload) async throws { throw StubError.alwaysFails }
    func updateCategory(_ payload: UpdateCategoryPayload) async throws { throw StubError.alwaysFails }
    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws { throw StubError.alwaysFails }
    func unmapCard(_ payload: UnmapCardPayload) async throws { throw StubError.alwaysFails }
    func mapCard(_ payload: MapCardPayload) async throws { throw StubError.alwaysFails }
    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool {
        throw StubError.alwaysFails
    }
}
