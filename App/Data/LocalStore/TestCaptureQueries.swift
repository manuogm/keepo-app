import Foundation
import GRDB
import KeepoCore

/// Finding and removing onboarding's test capture.
///
/// It is a real row in the local mirror — that is the whole point of the
/// test, and an in-app fake would have proved nothing — so it needs a real
/// way to be found and a real way to go away. Both key on
/// `CaptureIdentity.testCardIdentifier`, the same value
/// `LocalMoneyQueries.needsReviewPendingCaptures` excludes.
///
/// **Two screens read this, deliberately.** The setup step shows the row it
/// just produced with Delete as its primary action, and Profile → My
/// Automations keeps offering the delete for as long as one exists —
/// because backgrounding the app mid-flow would otherwise strand a fake
/// purchase in the ledger with nothing left pointing at it.
enum TestCaptureQueries {
    struct TestCapture: Equatable, Sendable {
        let id: UUID
        let merchant: String
        let amountE4: Int64
        let currency: String?
        let minorUnit: Int
        let categoryName: String
        /// So the card can draw the same `CategoryIconView` every other
        /// transaction row draws, rather than a stand-in that happens to
        /// look similar.
        let categoryIcon: String
        let categoryColor: String
        let accountName: String?
        let occurredAt: Date
    }

    static func fetch(_ database: Database) throws -> TestCapture? {
        guard let row = try Row.fetchOne(
            database,
            sql: """
            SELECT t.id, t.merchant_raw, t.amount_e4, t.occurred_at,
                   COALESCE(t.currency, t.original_currency) AS currency,
                   cur.minor_unit, c.name AS category_name,
                   c.icon AS category_icon, c.color AS category_color, a.name AS account_name
            FROM transactions t
            JOIN categories c ON c.id = t.category_id
            LEFT JOIN accounts a ON a.id = t.account_id
            LEFT JOIN currencies cur ON cur.code = COALESCE(t.currency, t.original_currency)
            WHERE t.card_identifier = ? AND t.deleted_at IS NULL
            ORDER BY t.occurred_at DESC LIMIT 1
            """,
            arguments: [CaptureIdentity.testCardIdentifier]
        ) else { return nil }

        let occurredAt: String = row["occurred_at"]
        return TestCapture(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            merchant: (row["merchant_raw"] as String?) ?? CaptureIdentity.testMerchant,
            amountE4: row["amount_e4"],
            currency: row["currency"],
            // 2 when the capture is held for an unmapped card and has no
            // currency yet — which is the normal case for the test, since
            // its card is by construction mapped to nothing.
            minorUnit: (row["minor_unit"] as Int?) ?? 2,
            categoryName: row["category_name"],
            categoryIcon: row["category_icon"],
            categoryColor: row["category_color"],
            accountName: row["account_name"],
            occurredAt: PostgresDate.date(fromTimestamp: occurredAt) ?? Date()
        )
    }

    /// A hard delete, not the soft `deleted_at` every real transaction
    /// gets. Nothing on the server knows this row exists — it was never
    /// pushed — so there is no tombstone for a sync to carry, and leaving
    /// one behind would only give a future query something to trip over.
    static func delete(_ database: Database) throws {
        try database.execute(
            sql: "DELETE FROM transactions WHERE card_identifier = ?",
            arguments: [CaptureIdentity.testCardIdentifier]
        )
    }

    static func exists(_ database: Database) throws -> Bool {
        try Int.fetchOne(
            database,
            sql: "SELECT COUNT(*) FROM transactions WHERE card_identifier = ? AND deleted_at IS NULL",
            arguments: [CaptureIdentity.testCardIdentifier]
        ).map { $0 > 0 } ?? false
    }
}
