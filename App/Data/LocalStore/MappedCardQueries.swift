import Foundation
import GRDB
import KeepoCore

/// Every card the user has linked, across all their accounts, with the
/// account each one belongs to.
///
/// `LocalTableQueries.cardMappings` answers the other question — "which
/// cards are on *this* account?" — which is what the account form needs and
/// is wrong for the automations screen, where the point is to see the whole
/// set at once without opening five accounts to find out.
///
/// The account comes along because a card is drawn in its account's colour
/// (`CreditCardFace`) and tapping one opens that account's form. Fetching
/// the cards and then the accounts separately would be two round trips and
/// a join written in Swift.
struct MappedCardRow: Identifiable, Equatable {
    let id: UUID
    let cardIdentifier: String
    let source: PublicSchema.CardMappingSource
    let accountId: UUID
    let accountName: String
    let accountColor: String
}

enum MappedCardQueries {
    static func all(_ database: Database, ownerId: String) throws -> [MappedCardRow] {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT cm.id AS mapping_id,
                   cm.card_identifier AS card_identifier,
                   cm.source AS source,
                   a.id AS account_id,
                   a.name AS account_name,
                   a.color AS account_color
            FROM card_mappings cm
            JOIN accounts a ON a.id = cm.account_id AND a.owner_id = cm.owner_id
            WHERE cm.owner_id = ?
              AND cm.deleted_at IS NULL
              AND cm.account_id IS NOT NULL
              AND a.deleted_at IS NULL
              AND a.archived_at IS NULL
              -- Onboarding's test purchase is not a card the user owns, and
              -- it is excluded everywhere else it could surface for exactly
              -- the same reason (`LocalMoneyQueries`).
              AND cm.card_identifier <> ?
            ORDER BY a.sort_order, cm.card_identifier
            """,
            arguments: [ownerId, CaptureIdentity.testCardIdentifier]
        )

        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["mapping_id"]),
                  let accountId = UUID(uuidString: row["account_id"]) else { return nil }
            let rawSource: String = row["source"]
            return MappedCardRow(
                id: id,
                cardIdentifier: row["card_identifier"],
                // A row whose source predates the column, or arrives from a
                // newer server that has grown a third value, is still a real
                // card — it just loses the "a machine did this" marker.
                source: PublicSchema.CardMappingSource(rawValue: rawSource) ?? .manual,
                accountId: accountId,
                accountName: row["account_name"],
                accountColor: row["account_color"]
            )
        }
    }
}
