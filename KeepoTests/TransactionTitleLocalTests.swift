import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// The title's on-device half: the memory the form and the capture both read
/// (`LocalTitleMemory`), the capture resolution that consults it, the hint the
/// outbox forwards because of it, and the write-through and search that make a
/// title visible at all.
///
/// The capture cases mirror `48_transaction_titles.sql`'s hint cases on
/// purpose. The device resolves a capture the instant Apple Pay fires and the
/// server resolves the same primary key whenever the network allows, so the
/// two must reach the same category — which is what the hint is for.
@Suite("Transaction titles on device")
@MainActor
struct TransactionTitleLocalTests {
    private struct Fixture {
        let outbox: Outbox
        let sender: StubTransactionSender
        let dbQueue: DatabaseQueue
        let ownerId: UUID
        let accountId: UUID
        let coffee: UUID
        let dining: UUID
        let refunds: UUID
    }

    nonisolated private static let stamp = "2026-01-01T00:00:00.000000+00:00"

    private func makeFixture() async throws -> Fixture {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        let sender = StubTransactionSender()
        let ownerId = UUID()
        let accountId = UUID()
        let coffee = UUID()
        let dining = UUID()
        let refunds = UUID()

        try await dbQueue.write { database in
            try database.execute(sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES ('EUR', 2, 1)")
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Checking', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
                """,
                arguments: [accountId.uuidString, ownerId.uuidString, ownerId.uuidString, Self.stamp, Self.stamp]
            )
            for (id, kind, name, isDefault) in [
                (UUID(), "expense", "Other", true), (coffee, "expense", "Coffee", false),
                (dining, "expense", "Dining", false), (refunds, "income", "Refunds", false)
            ] {
                try database.execute(
                    sql: """
                    INSERT INTO categories (id, owner_id, kind, name, is_default, icon, color, version,
                        created_at, updated_at, sync_seq)
                    VALUES (?, ?, ?, ?, ?, 'cart', '#000', 1, ?, ?, 1)
                    """,
                    arguments: [id.uuidString, ownerId.uuidString, kind, name, isDefault, Self.stamp, Self.stamp]
                )
            }
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at, sync_seq)
                VALUES (?, ?, 'card-1', ?, ?, ?, 1)
                """,
                arguments: [UUID().uuidString, ownerId.uuidString, accountId.uuidString, Self.stamp, Self.stamp]
            )
        }
        return Fixture(
            outbox: Outbox(dbQueue: dbQueue, sender: sender), sender: sender, dbQueue: dbQueue,
            ownerId: ownerId, accountId: accountId, coffee: coffee, dining: dining, refunds: refunds
        )
    }

    private func fileTitled(_ fixture: Fixture, title: String, category: UUID, amountE4: Int64 = -45000) async {
        await fixture.outbox.submitCreateTransaction(
            CreateTransactionPayload(
                id: UUID(), ownerId: fixture.ownerId, accountId: fixture.accountId, categoryId: category,
                amountE4: amountE4, currency: "EUR", occurredAt: Date(), title: title
            )
        )
    }

    private func learn(_ fixture: Fixture, merchant: String, category: UUID) async throws {
        try await fixture.dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO merchant_category_map (owner_id, merchant_pattern, category_id, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, 1)
                """,
                arguments: [fixture.ownerId.uuidString, merchant, category.uuidString, Self.stamp]
            )
        }
    }

    private func capture(_ fixture: Fixture, merchant: String) async -> OutboxCaptureResult {
        let id = UUID()
        return await fixture.outbox.submitCaptureTransaction(
            CaptureTransactionPayload(
                id: id, cardIdentifier: "card-1", merchantRaw: merchant,
                merchantNormalized: MerchantNormalizer.normalize(merchant), amountE4: 45000, occurredAt: Date(),
                externalId: "ext-\(id.uuidString)"
            ),
            ownerId: fixture.ownerId
        )
    }

    /// The network attempt runs detached from the submit, so the payload it
    /// sent is only observable a moment later.
    private func sentCapture(_ sender: StubTransactionSender) async -> CaptureTransactionPayload? {
        for _ in 0..<100 {
            if let payload = sender.lastCapturePayload { return payload }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    // MARK: - Capture: an unlearned merchant meets a title

    @Test("an unlearned merchant matching a title exactly is filed under that title's category, and says so")
    func unlearnedMerchantUsesTitle() async throws {
        let fixture = try await makeFixture()
        await fileTitled(fixture, title: "Blue Bottle", category: fixture.coffee)

        guard case .appliedLocally(let resolution) = await capture(fixture, merchant: "SQ *BLUE BOTTLE") else {
            Issue.record("the capture did not resolve locally")
            return
        }
        #expect(resolution.categoryId == fixture.coffee.uuidString)
        #expect(resolution.categoryFromTitle)
        #expect(!resolution.categoryIsDefault)

        let sent = await sentCapture(fixture.sender)
        #expect(sent?.categoryHint == fixture.coffee, "the server must be told, or the next pull flips the row")
    }

    @Test("a learned merchant outranks a title, and sends no hint")
    func learnedMerchantWins() async throws {
        let fixture = try await makeFixture()
        await fileTitled(fixture, title: "Blue Bottle", category: fixture.coffee)
        try await learn(fixture, merchant: "BLUE BOTTLE", category: fixture.dining)

        guard case .appliedLocally(let resolution) = await capture(fixture, merchant: "BLUE BOTTLE") else {
            Issue.record("the capture did not resolve locally")
            return
        }
        #expect(resolution.categoryId == fixture.dining.uuidString)
        #expect(!resolution.categoryFromTitle)
        let sent = await sentCapture(fixture.sender)
        #expect(sent != nil)
        #expect(sent?.categoryHint == nil)
    }

    @Test("a capture never matches a title loosely — only the whole key")
    func captureMatchesExactlyOnly() async throws {
        let fixture = try await makeFixture()
        await fileTitled(fixture, title: "Apple pie for mom", category: fixture.dining)

        guard case .appliedLocally(let resolution) = await capture(fixture, merchant: "APPLE") else {
            Issue.record("the capture did not resolve locally")
            return
        }
        #expect(resolution.categoryIsDefault)
        #expect(!resolution.categoryFromTitle)
    }

    // MARK: - The form: a typed title suggests a category

    @Test("a typed title finds the category that exact title was filed under")
    func formMatchesTitleHistory() async throws {
        let fixture = try await makeFixture()
        await fileTitled(fixture, title: "Coffee with Beth", category: fixture.coffee)

        let suggested = try await fixture.dbQueue.read { database in
            try LocalTitleMemory.suggestedCategory(
                forTitle: "coffee with beth ", ownerId: fixture.ownerId.uuidString, categoryKind: "expense",
                in: database
            )
        }
        #expect(suggested == fixture.coffee.uuidString)
    }

    @Test("a first-ever title finds a learned merchant by its leading words")
    func formFallsBackToMerchantPrefix() async throws {
        let fixture = try await makeFixture()
        try await learn(fixture, merchant: "STARBUCKS", category: fixture.coffee)

        let suggested = try await fixture.dbQueue.read { database in
            try LocalTitleMemory.suggestedCategory(
                forTitle: "Starbucks coffee", ownerId: fixture.ownerId.uuidString, categoryKind: "expense",
                in: database
            )
        }
        #expect(suggested == fixture.coffee.uuidString)
    }

    @Test("the user's own history with a title outranks the merchant map")
    func historyBeatsMerchant() async throws {
        let fixture = try await makeFixture()
        try await learn(fixture, merchant: "STARBUCKS", category: fixture.coffee)
        await fileTitled(fixture, title: "Starbucks", category: fixture.dining)

        let suggested = try await fixture.dbQueue.read { database in
            try LocalTitleMemory.suggestedCategory(
                forTitle: "Starbucks", ownerId: fixture.ownerId.uuidString, categoryKind: "expense", in: database
            )
        }
        #expect(suggested == fixture.dining.uuidString)
    }

    @Test("a suggestion never crosses kinds — an income form gets no expense category")
    func suggestionRespectsKind() async throws {
        let fixture = try await makeFixture()
        await fileTitled(fixture, title: "Refund", category: fixture.coffee)

        let suggested = try await fixture.dbQueue.read { database in
            try LocalTitleMemory.suggestedCategory(
                forTitle: "Refund", ownerId: fixture.ownerId.uuidString, categoryKind: "income", in: database
            )
        }
        #expect(suggested == nil)
    }

    // MARK: - Write-through and search

    @Test("a transfer's title lands on both legs locally, and an edit rewrites both")
    func transferTitleOnBothLegs() async throws {
        let fixture = try await makeFixture()
        let savings = UUID()
        try await fixture.dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Savings', 'EUR', 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1, ?, ?, 1)
                """,
                arguments: [
                    savings.uuidString, fixture.ownerId.uuidString, fixture.ownerId.uuidString, Self.stamp, Self.stamp
                ]
            )
        }
        let fromId = UUID()
        await fixture.outbox.submitCreateTransfer(
            CreateTransferPayload(
                fromId: fromId, toId: UUID(), fromAccountId: fixture.accountId, toAccountId: savings,
                fromAmountE4: 10000, toAmountE4: nil, occurredAt: Date(), title: "Rainy day"
            )
        )
        let groupId = fromId
        await fixture.outbox.submitUpdateTransfer(
            UpdateTransferPayload(
                transferGroupId: groupId, fromExpectedVersion: 1, toExpectedVersion: 1,
                fromAmountE4: 10000, toAmountE4: 10000, occurredAt: Date(), title: "Holiday fund"
            )
        )
        let titles = try await fixture.dbQueue.read { database in
            try String?.fetchAll(database, sql: "SELECT title FROM transactions WHERE transfer_group_id IS NOT NULL")
        }
        #expect(titles == ["Holiday fund", "Holiday fund"])
    }

    @Test("the ledger's search finds a transaction by its title")
    func searchMatchesTitle() async throws {
        let fixture = try await makeFixture()
        await fileTitled(fixture, title: "Anniversary dinner", category: fixture.dining)
        await fileTitled(fixture, title: "Gym", category: fixture.dining)

        let found = try await fixture.dbQueue.read { database in
            try LocalTransactionRow.fetchFiltered(
                database, filter: TransactionFilter(search: "anniversary"), scope: .me,
                baseCurrency: "EUR", ownerId: fixture.ownerId.uuidString
            )
        }
        #expect(found.map(\.title) == ["Anniversary dinner"])
    }
}
