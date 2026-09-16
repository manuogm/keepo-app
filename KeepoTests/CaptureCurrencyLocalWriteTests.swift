import Foundation
import GRDB
import KeepoCore
import Testing
@testable import Keepo

/// `CaptureLocalWrite`'s currency arm, which is the on-device half of
/// `capture_transaction` (`20260923100000_transaction_original_currency.sql`).
///
/// **These assertions deliberately mirror `39_transaction_original_currency
/// .sql`'s, case for case, with the same numbers.** The two implementations
/// write the same primary key — one the instant Apple Pay fires, the other
/// whenever the network allows — so a disagreement between them is a row
/// that silently changes under the user at the next pull. Same referee
/// discipline `LocalMoneyRefereeTests` already applies to the money layer.
///
/// €50.00 at a USD factor of 1.0800 is $54.00; at December's 1.2000 it is
/// $60.00. Reading one where the other belongs is what says which date's
/// rate was used.
@Suite("Capture currency local write-through")
@MainActor
struct CaptureCurrencyLocalWriteTests {
    private func makeOutboxAndDatabase() throws -> (Outbox, DatabaseQueue) {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        return (Outbox(dbQueue: dbQueue, sender: AlwaysFailingSender()), dbQueue)
    }

    /// Every currency the detector may name has to exist locally or the
    /// server's own "can Keepo price this?" re-check has no counterpart.
    private func seedReferenceData(_ dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { database in
            for code in ["USD", "EUR", "THB"] {
                try database.execute(
                    sql: "INSERT INTO currencies (code, minor_unit, sync_seq) VALUES (?, 2, 1)", arguments: [code]
                )
            }
            // No THB row, ever, in this file: a currency you are travelling
            // in is one you hold no account in, so "no rate at all" is the
            // ordinary case rather than an exotic one.
            for (date, rate) in [("2025-12-01", "1.2000"), ("2026-01-15", "1.0800")] {
                try database.execute(
                    sql: """
                    INSERT INTO fx_rates (currency, rate_date, units_per_eur, source, fetched_at, sync_seq)
                    VALUES ('USD', ?, ?, 'ecb', '2026-01-15T00:00:00.000000+00:00', 1)
                    """,
                    arguments: [date, rate]
                )
            }
        }
    }

    private func seedAccount(_ dbQueue: DatabaseQueue, id: UUID, ownerId: UUID, currency: String) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO accounts (id, owner_id, created_by, kind, name, currency,
                    opening_balance_e4, opening_balance_at, include_in_total, icon, color, version,
                    created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, 'regular', 'Dollars', ?, 0, '2026-01-01', 1, 'banknote', '#8E8E93', 1,
                    '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [id.uuidString, ownerId.uuidString, ownerId.uuidString, currency]
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
        _ dbQueue: DatabaseQueue, ownerId: UUID, cardIdentifier: String, accountId: UUID
    ) async throws {
        try await dbQueue.write { database in
            try database.execute(
                sql: """
                INSERT INTO card_mappings (id, owner_id, card_identifier, account_id, created_at, updated_at, sync_seq)
                VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000000+00:00', '2026-01-01T00:00:00.000000+00:00', 1)
                """,
                arguments: [UUID().uuidString, ownerId.uuidString, cardIdentifier, accountId.uuidString]
            )
        }
    }

    private struct Written: Equatable {
        let amountE4: Int64
        let currency: String?
        let accountId: String?
        let originalAmountE4: Int64?
        let originalCurrency: String?
    }

    private func written(_ dbQueue: DatabaseQueue, id: UUID) async throws -> Written? {
        try await dbQueue.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                SELECT amount_e4, currency, account_id, original_amount_e4, original_currency
                FROM transactions WHERE id = ?
                """,
                arguments: [id.uuidString]
            ) else { return nil }
            return Written(
                amountE4: row["amount_e4"], currency: row["currency"], accountId: row["account_id"],
                originalAmountE4: row["original_amount_e4"], originalCurrency: row["original_currency"]
            )
        }
    }

    /// Midday UTC so the day the conversion resolves against is the same
    /// one whatever zone the test machine is in.
    private func date(_ iso: String) -> Date {
        PostgresDate.date(fromTimestamp: iso) ?? Date()
    }

    /// One mapped USD card, one owner, all the reference data — the setup
    /// every case below starts from.
    private struct Fixture {
        let outbox: Outbox
        let dbQueue: DatabaseQueue
        let ownerId: UUID
        let accountId: UUID
    }

    private func makeFixture(mapCard: Bool = true, accountCurrency: String = "USD") async throws -> Fixture {
        let (outbox, dbQueue) = try makeOutboxAndDatabase()
        let ownerId = UUID()
        let accountId = UUID()
        try await seedReferenceData(dbQueue)
        try await seedAccount(dbQueue, id: accountId, ownerId: ownerId, currency: accountCurrency)
        try await seedDefaultCategory(dbQueue, id: UUID(), ownerId: ownerId)
        if mapCard {
            try await seedCardMapping(dbQueue, ownerId: ownerId, cardIdentifier: "card-usd", accountId: accountId)
        }
        return Fixture(outbox: outbox, dbQueue: dbQueue, ownerId: ownerId, accountId: accountId)
    }

    private func capture(
        _ outbox: Outbox, ownerId: UUID, id: UUID, detected: String?, amountE4: Int64 = 500_000,
        occurredAt: Date, card: String = "card-usd"
    ) async -> OutboxCaptureResult {
        await outbox.submitCaptureTransaction(
            CaptureTransactionPayload(
                id: id, cardIdentifier: card, merchantRaw: "Cafe Paris", merchantNormalized: "CAFE PARIS",
                amountE4: amountE4, occurredAt: occurredAt, externalId: "ext-\(id.uuidString)",
                detectedCurrency: detected
            ),
            ownerId: ownerId
        )
    }

    // MARK: - The ordinary capture is untouched

    @Test("a capture with no detected currency is unchanged", arguments: [nil, "USD", "  usd "])
    func noConversionRecorded(detected: String?) async throws {
        let fixture = try await makeFixture()
        let id = UUID()
        _ = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: id, detected: detected,
            amountE4: 45000, occurredAt: date("2026-01-15T12:00:00.000000+00:00")
        )

        #expect(try await written(fixture.dbQueue, id: id) == Written(
            amountE4: -45000, currency: "USD", accountId: fixture.accountId.uuidString,
            originalAmountE4: nil, originalCurrency: nil
        ))
    }

    // MARK: - The case the feature exists for

    @Test("a foreign purchase on a known card is converted, and what was paid is kept")
    func convertsAndKeepsTheOriginal() async throws {
        let fixture = try await makeFixture()
        let id = UUID()
        _ = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: id, detected: "EUR",
            occurredAt: date("2026-01-15T12:00:00.000000+00:00")
        )

        #expect(try await written(fixture.dbQueue, id: id) == Written(
            amountE4: -540_000, currency: "USD", accountId: fixture.accountId.uuidString,
            originalAmountE4: -500_000, originalCurrency: "EUR"
        ))
    }

    /// A card mapped three weeks after the purchase must still convert at
    /// the rate on the day it happened — so must one captured then.
    @Test("the conversion uses the rate on the day of the purchase, not today's")
    func usesTheRateOnTheDayOfPurchase() async throws {
        let fixture = try await makeFixture()
        let id = UUID()
        _ = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: id, detected: "EUR",
            occurredAt: date("2025-12-20T12:00:00.000000+00:00")
        )

        let row = try await written(fixture.dbQueue, id: id)
        #expect(row?.amountE4 == -600_000)
    }

    // MARK: - The two ways the account cannot be claimed

    /// Money rule 5: with no resolvable rate there is no number that
    /// belongs in this account's currency, so the row does not claim one.
    @Test("with no resolvable rate the row holds what was paid and claims no account")
    func missingRateHoldsThePaidAmount() async throws {
        let fixture = try await makeFixture()
        let id = UUID()
        _ = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: id, detected: "THB",
            amountE4: 25_000_000, occurredAt: date("2026-01-15T12:00:00.000000+00:00")
        )

        #expect(try await written(fixture.dbQueue, id: id) == Written(
            amountE4: -25_000_000, currency: nil, accountId: nil,
            originalAmountE4: -25_000_000, originalCurrency: "THB"
        ))
    }

    @Test("an unmapped card holds the detected currency instead of discarding it")
    func unmappedCardHoldsTheCurrency() async throws {
        let fixture = try await makeFixture(mapCard: false)
        let id = UUID()
        _ = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: id, detected: "EUR",
            amountE4: 300_000, occurredAt: date("2026-01-15T12:00:00.000000+00:00"), card: "card-new"
        )

        #expect(try await written(fixture.dbQueue, id: id) == Written(
            amountE4: -300_000, currency: nil, accountId: nil,
            originalAmountE4: -300_000, originalCurrency: "EUR"
        ))
    }

    @Test("a currency the mirror cannot price is ignored, not stored")
    func unsupportedCurrencyIsIgnored() async throws {
        let fixture = try await makeFixture()
        let id = UUID()
        _ = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: id, detected: "ZZZ",
            amountE4: 45000, occurredAt: date("2026-01-15T12:00:00.000000+00:00")
        )

        #expect(try await written(fixture.dbQueue, id: id) == Written(
            amountE4: -45000, currency: "USD", accountId: fixture.accountId.uuidString,
            originalAmountE4: nil, originalCurrency: nil
        ))
    }

    // MARK: - What the notification says

    /// The held row's `amount_e4` IS what was paid, so the notification
    /// labels it in the currency it was paid in — while still saying the
    /// account is unknown, which is `accountName`'s job, not the currency's.
    @Test("a held capture still names the currency it was paid in")
    func heldCaptureNamesThePaidCurrency() async throws {
        let fixture = try await makeFixture(mapCard: false)
        let result = await capture(
            fixture.outbox, ownerId: fixture.ownerId, id: UUID(), detected: "EUR",
            occurredAt: date("2026-01-15T12:00:00.000000+00:00"), card: "card-new"
        )

        guard case .appliedLocally(let resolution) = result else {
            Issue.record("expected .appliedLocally, got \(result)")
            return
        }
        #expect(resolution.currency == "EUR")
        #expect(resolution.accountName == nil)
    }
}
