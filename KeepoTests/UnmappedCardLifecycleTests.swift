import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// Two related unmapped-card defects found in device testing (2026-08),
/// split into their own file rather than folded into
/// `OutboxLocalWriteTests.swift`/`CardMappingLocalWriteTests.swift` purely
/// to keep those files under the project's type-body-length lint
/// threshold.
///
/// A. `CaptureLocalWrite`'s account resolution used to ignore `deleted_at`,
///    so a card the user had explicitly unmapped kept silently auto-filing
///    new captures into the account it used to belong to — a real
///    discrepancy between what the Mapped Cards screen showed (nothing)
///    and what a new purchase actually resolved to.
/// B. Deleting the one pending capture on an unmapped card used to leave
///    its placeholder `card_mappings` row behind, where it surfaced on its
///    own as a bare "Unmapped card" Needs Review item with no transaction
///    left to explain it.
@Suite("Unmapped card lifecycle")
@MainActor
struct UnmappedCardLifecycleTests {
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
        _ dbQueue: DatabaseQueue, id: UUID = UUID(), ownerId: UUID, cardIdentifier: String, accountId: UUID?,
        deletedAt: String? = nil
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at,
                    deleted_at, sync_seq)
                VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', ?, 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, cardIdentifier, accountId?.uuidString, deletedAt]
            )
        }
    }

    private func seedPendingCapture(
        _ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, categoryId: UUID, cardIdentifier: String
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO transactions (
                    id, owner_id, created_by, category_id, amount_e4, occurred_at, merchant_raw,
                    merchant_normalized, card_identifier, source, status, external_id, version,
                    created_at, updated_at, sync_seq
                ) VALUES (?, ?, ?, ?, -4500, '2026-01-01T00:00:00.000000+00:00', 'Blue Bottle', 'BLUE BOTTLE', ?,
                    'capture', 'pending', 'ext-delete-test', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 0)
                """,
                arguments: [
                    id.uuidString, ownerId.uuidString, ownerId.uuidString, categoryId.uuidString, cardIdentifier
                ]
            )
        }
    }

    private func mappingDeletedAt(_ dbQueue: DatabaseQueue, id: UUID) async throws -> String? {
        try await dbQueue.read { database in
            let row = try Row.fetchOne(
                database, sql: "SELECT deleted_at FROM card_mappings WHERE id = ?", arguments: [id.uuidString]
            )
            return row?["deleted_at"] as String?
        }
    }

    // MARK: - A: capture resolution respects deleted_at

    @Test("a capture on a card that was explicitly unmapped resolves to no account")
    func captureOnUnmappedCardResolvesToNoAccount() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let defaultCategoryId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedDefaultCategory(dbQueue, id: defaultCategoryId, ownerId: ownerId)
        try await seedCardMapping(
            dbQueue, ownerId: ownerId, cardIdentifier: "card-1", accountId: accountId,
            deletedAt: "2026-06-01T00:00:00.000000+00:00"
        )

        let payload = CaptureTransactionPayload(
            id: UUID(), cardIdentifier: "card-1", merchantRaw: "Blue Bottle", merchantNormalized: "BLUE BOTTLE",
            amountE4: 45000, occurredAt: Date(), externalId: "ext-unmapped-1"
        )

        let result = await outbox.submitCaptureTransaction(payload, ownerId: ownerId)
        guard case .appliedLocally(let resolution) = result else {
            Issue.record("expected .appliedLocally, got \(result)")
            return
        }
        #expect(resolution.accountName == nil)
        #expect(resolution.currency == nil)

        let row = try await dbQueue.read { database in
            try Row.fetchOne(
                database, sql: "SELECT account_id FROM transactions WHERE id = ?", arguments: [payload.id.uuidString]
            )
        }
        #expect(row?["account_id"] == nil)
    }

    // MARK: - B: deleting the last pending capture retires its placeholder mapping

    @Test("deleting the last pending capture on an unmapped card also retires its placeholder mapping")
    func deleteTransactionRetiresOrphanedPlaceholderMapping() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        let mappingId = UUID()
        try await seedDefaultCategory(dbQueue, id: categoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, categoryId: categoryId, cardIdentifier: "card-orphan"
        )
        try await seedCardMapping(
            dbQueue, id: mappingId, ownerId: ownerId, cardIdentifier: "card-orphan", accountId: nil
        )

        _ = await outbox.submitDeleteTransaction(DeleteTransactionPayload(id: transactionId, expectedVersion: 1))

        #expect(try await mappingDeletedAt(dbQueue, id: mappingId) != nil)
    }

    /// A card still routed to a real account is a deliberate user choice —
    /// deleting one capture on it must never touch the mapping.
    @Test("deleting a pending capture never touches a card that's actually mapped to an account")
    func deleteTransactionNeverTouchesARealMapping() async throws {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        let categoryId = UUID()
        let transactionId = UUID()
        let mappingId = UUID()
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId)
        try await seedDefaultCategory(dbQueue, id: categoryId, ownerId: ownerId)
        try await seedPendingCapture(
            dbQueue, id: transactionId, ownerId: ownerId, categoryId: categoryId, cardIdentifier: "card-real"
        )
        try await seedCardMapping(
            dbQueue, id: mappingId, ownerId: ownerId, cardIdentifier: "card-real", accountId: accountId
        )

        _ = await outbox.submitDeleteTransaction(DeleteTransactionPayload(id: transactionId, expectedVersion: 1))

        #expect(try await mappingDeletedAt(dbQueue, id: mappingId) == nil)
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
    func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool {
        throw StubError.alwaysFails
    }
}
