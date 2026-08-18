import Foundation
import GRDB
import KeepoCore

// Split out of Outbox.swift purely to keep that file under the project's
// file-length lint threshold — same precedent as Outbox+Capture.swift.

extension Outbox {
    /// One-time repair (X-02 revisited) for outbox rows already corrupted
    /// by the old `enqueue` behavior its own fix (`Outbox.swift`'s
    /// `enqueue` header comment) prevents going forward: a review/confirm/
    /// update/delete whose row was never actually created server-side,
    /// because the create that belonged under this same id got silently
    /// overwritten before that fix shipped. Left unrepaired, every replay
    /// of that item fails with "not found," forever — no amount of
    /// retrying ever helps, because nothing ever creates the row.
    ///
    /// This used to run reactively, wrapping every single replay attempt
    /// (any kind, not just capture-derived ones) in a catch-and-recover —
    /// permanent runtime machinery for a bug class that can only exist on
    /// a device that already had a corrupted item queued *before*
    /// upgrading to the `enqueue` fix. That design also fired on
    /// genuinely unrelated failures (offline, a real 5xx, a real
    /// conflict), burning an extra `capture_transaction` call — and its
    /// rate-limit budget — on every one of them.
    ///
    /// Converted to a one-time sweep instead: `SessionStore.start()` calls
    /// this once per launch, before the first drain, so a corrupted
    /// create is resent before the dependent write ever gets a chance to
    /// fail on it. Gated by a one-shot flag once every currently-queued
    /// item has been handled — a device that's never had this bug
    /// (everyone from here forward, since `enqueue` can no longer produce
    /// it) pays for one cheap, empty scan and never touches this code
    /// again. `defaults` is injectable for tests, same pattern as
    /// `OutboxMigration`.
    private static let repairDoneKey = "app.keepo.legacyCaptureQueueRepair.done"

    func repairLegacyCaptureQueueIfNeeded(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: Self.repairDoneKey) else { return }

        let targetIds = await targetRowIdsOfQueuedItems()
        guard !targetIds.isEmpty else {
            defaults.set(true, forKey: Self.repairDoneKey)
            return
        }

        var everythingHandled = true
        for id in targetIds where await repairIfLegacyCapture(id: id) == .failed {
            everythingHandled = false
        }
        if everythingHandled {
            defaults.set(true, forKey: Self.repairDoneKey)
        }
    }

    private func targetRowIdsOfQueuedItems() async -> Set<String> {
        let items = (try? await dbQueue.read { database in try OutboxItemRecord.fetchAll(database) }) ?? []
        return Set(items.compactMap(targetRowId(for:)))
    }

    private func targetRowId(for item: OutboxItemRecord) -> String? {
        guard let kind = OutboxKind(rawValue: item.kind) else { return nil }
        switch kind {
        case .updateTransaction:
            return (try? decoder.decode(UpdateTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        case .confirmCaptureTransaction:
            return (try? decoder.decode(ConfirmCaptureTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        case .reviewCapture:
            return (try? decoder.decode(ReviewCaptureTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        case .deleteTransaction:
            return (try? decoder.decode(DeleteTransactionPayload.self, from: item.payloadJSON))?.id.uuidString
        default:
            return nil
        }
    }

    private enum RepairOutcome {
        /// Not a legacy-corrupted capture row — either it isn't a
        /// `source = 'capture'` row at all, or it's already gone. Nothing
        /// to do; counts as handled.
        case notApplicable
        /// The create was resent successfully (or, just as often, the row
        /// already existed server-side and this was a harmless idempotent
        /// no-op — `capture_transaction`'s own `external_id` uniqueness
        /// makes a redundant resend safe either way).
        case recovered
        /// The resend itself failed (offline, a real 5xx) — must retry the
        /// whole sweep on a later launch, not just this one id.
        case failed
    }

    private func repairIfLegacyCapture(id: String) async -> RepairOutcome {
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
        else { return .notApplicable }

        let payload = CaptureTransactionPayload(
            id: uuid, cardIdentifier: cardIdentifier, merchantRaw: merchantRaw,
            merchantNormalized: merchantNormalized, amountE4: abs(amountE4), occurredAt: occurredAt,
            externalId: externalId, notes: row["notes"] as String?
        )
        return (try? await sender.captureTransaction(payload)) != nil ? .recovered : .failed
    }
}
