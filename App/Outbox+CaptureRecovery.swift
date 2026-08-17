import Foundation
import GRDB
import KeepoCore

// Split out of Outbox.swift purely to keep that file under the project's
// file-length lint threshold — same precedent as Outbox+Capture.swift.

extension Outbox {
    /// Recovers items that were already corrupted by the old `enqueue`
    /// behavior its own fix (`Outbox.swift`'s own header comment on
    /// `enqueue`) prevents going forward: a confirm/update/delete whose
    /// row was never actually created server-side — because the create
    /// that belonged under this same id got silently overwritten before
    /// that fix existed — fails every replay with "not found," permanently.
    /// No amount of retrying ever helps, because nothing ever creates the
    /// row. If the local mirror still has the row (`source = 'capture'`,
    /// exactly the only case this can happen), one recovery attempt
    /// reconstructs and resends the original create from its still-present
    /// local fields — `external_id` keeps this idempotent against a
    /// second, unrelated failure that isn't this bug — then retries the
    /// write that actually failed. If the row is gone or isn't a capture,
    /// there is nothing to recover and the original error propagates
    /// unchanged.
    func replayWithRecovery(_ item: OutboxItemRecord) async throws {
        do {
            _ = try await replay(item)
        } catch {
            guard let rowId = targetRowId(for: item), await recreateMissingCapture(id: rowId) else {
                throw error
            }
            _ = try await replay(item)
        }
    }

    private func targetRowId(for item: OutboxItemRecord) -> String? {
        guard let kind = OutboxKind(rawValue: item.kind) else { return nil }
        switch kind {
        case .updateTransaction:
            return (try? decoder.decode(UpdateTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        case .confirmCaptureTransaction:
            return (try? decoder.decode(ConfirmCaptureTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        case .deleteTransaction:
            return (try? decoder.decode(DeleteTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        default:
            return nil
        }
    }

    private func recreateMissingCapture(id: String) async -> Bool {
        guard let row = try? await dbQueue.read({ database -> Row? in
            try Row.fetchOne(
                database,
                sql: """
                SELECT card_identifier, merchant_raw, merchant_normalized, amount_e4, occurred_at, external_id, notes
                FROM transactions WHERE id = ? AND source = 'capture' AND card_identifier IS NOT NULL
                """,
                arguments: [id]
            )
        }),
        let cardIdentifier = row["card_identifier"] as String?,
        let merchantRaw = row["merchant_raw"] as String?,
        let merchantNormalized = row["merchant_normalized"] as String?,
        let amountE4 = row["amount_e4"] as Int64?,
        let occurredAtString = row["occurred_at"] as String?,
        let occurredAt = PostgresDate.date(fromTimestamp: occurredAtString),
        let externalId = row["external_id"] as String?,
        let uuid = UUID(uuidString: id)
        else { return false }

        let payload = CaptureTransactionPayload(
            id: uuid, cardIdentifier: cardIdentifier, merchantRaw: merchantRaw,
            merchantNormalized: merchantNormalized, amountE4: abs(amountE4), occurredAt: occurredAt,
            externalId: externalId, notes: row["notes"] as String?
        )
        return (try? await sender.captureTransaction(payload)) != nil
    }
}
