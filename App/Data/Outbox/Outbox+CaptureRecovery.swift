import Foundation
import GRDB
import KeepoCore

// Split out of Outbox.swift purely to keep that file under the project's
// file-length lint threshold — same precedent as Outbox+Capture.swift.

extension Outbox {
    /// Repairs a queued review/confirm/update/delete whose row was never
    /// actually created server-side, by resending its `capture_transaction`
    /// create — `capture_transaction`'s own `external_id` uniqueness makes a
    /// redundant resend safe even when the create landed fine. Left
    /// unrepaired, every replay of that item fails "transaction not found or
    /// not accessible," forever — no amount of retrying ever helps, because
    /// nothing ever creates the row.
    ///
    /// Originally written (X-02) for one specific, closed bug: an old
    /// `enqueue` that could silently drop an already-queued create when a
    /// dependent write collapsed onto it. That bug can no longer occur
    /// (`enqueue`'s own header explains the fix), which is why this used to
    /// gate on a single boolean — "done" meant "this device's one possible
    /// wound has been checked."
    ///
    /// Quick actions (`CaptureQuickActionHandler`) reopened the same failure
    /// *shape* through a different door: they build a fresh `Outbox` via
    /// `CaptureEnvironment.makeOutbox()` and attempt their write immediately,
    /// with no drain first — so a capture whose create is still sitting
    /// queued (device briefly offline moments earlier, say) races a
    /// same-second quick action and loses, landing in exactly this "not
    /// found" state. That's a new row hitting an old symptom, on a device
    /// where the one-shot flag was long since tripped — which is why a
    /// device-testing capture kept failing "not found" forever with no
    /// automatic recovery, even after this repair already existed.
    ///
    /// So the gate is per-row now, not per-device: each target id gets at
    /// most one repair attempt ever (a `.recovered` or `.notApplicable`
    /// outcome is permanent — resending or re-checking it later can't
    /// change the answer), tracked as a persisted set rather than a single
    /// flag. That keeps the cost this was reduced to guard against (an
    /// unpushed migration or a real 5xx turning into a `capture_transaction`
    /// call, and its rate-limit budget, on every single replay) while still
    /// giving a genuinely new corruption a chance to self-heal instead of
    /// being silently permanent. `defaults` is injectable for tests, same
    /// pattern as `OutboxMigration`.
    ///
    /// Called from both `SessionStore.start()` (before the first drain) and
    /// `CaptureEnvironment.makeOutbox()` (before a quick action's own write
    /// attempt) — the second call site is what actually closes the race
    /// above, since it runs in the same background process that's about to
    /// need the row to exist.
    private static let repairedIdsKey = "app.keepo.legacyCaptureQueueRepair.repairedIds"

    func repairLegacyCaptureQueueIfNeeded(defaults: UserDefaults = .standard) async {
        let targetIds = await targetRowIdsOfQueuedItems()
        guard !targetIds.isEmpty else { return }

        var repairedIds = Set(defaults.stringArray(forKey: Self.repairedIdsKey) ?? [])
        let unattempted = targetIds.subtracting(repairedIds)
        guard !unattempted.isEmpty else { return }

        for id in unattempted where await repairIfLegacyCapture(id: id) != .failed {
            repairedIds.insert(id)
        }
        defaults.set(Array(repairedIds), forKey: Self.repairedIdsKey)
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
        /// to do; counts as handled — permanently, since neither fact can
        /// later become false.
        case notApplicable
        /// The create was resent successfully (or, just as often, the row
        /// already existed server-side and this was a harmless idempotent
        /// no-op). Permanent — the same id will never need trying again.
        case recovered
        /// The resend itself failed (offline, a real 5xx) — must retry this
        /// specific id on a later call, not just the whole sweep.
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
