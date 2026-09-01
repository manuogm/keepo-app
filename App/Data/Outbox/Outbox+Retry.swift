import Foundation
import GRDB

/// The outbox's background retry timer and the three counters that drive
/// the pending-sync banner — split from `Outbox.swift` purely to stay under
/// this project's `file_length`/`type_body_length` lint limits, same
/// convention as `Outbox+Capture.swift`.
extension Outbox {
    /// C-10: every existing drain trigger (cold start, sign-in, foreground,
    /// reconnect, manual banner tap) needs an app-lifecycle or connectivity
    /// *event* to fire. A transient 5xx during an otherwise-online, otherwise
    /// idle session left the write parked for however long the user happened
    /// to keep the app foregrounded, with only `hasStalePending`'s 120s
    /// banner as a symptom. Called once by `SessionStore` — not from `init`,
    /// so the short-lived `Outbox` `CaptureIntent` constructs for a single
    /// capture never starts a retry timer it has no use for.
    ///
    /// Backs off 30s → 5min, capped, starting again from the floor the next
    /// time something is queued — a lingering failure doesn't retry as
    /// eagerly as a fresh one.
    ///
    /// **The timer only exists while the queue does.** It used to be a
    /// single loop that reset its delay to 30s whenever the queue was empty,
    /// so a perfectly healthy session woke the process twice a minute for
    /// its entire foreground lifetime to discover there was nothing to do.
    /// `refreshCounts()` already runs after every enqueue and every drain
    /// and is the one place `pendingCount` changes, so it is also the right
    /// place to start and stop the timer — an idle outbox now schedules
    /// nothing at all.
    public func startRetryLoop() {
        guard !isRetryLoopEnabled else { return }
        isRetryLoopEnabled = true
        scheduleRetryIfNeeded()
    }

    /// Connectivity comes from the app-wide `NetworkMonitor` rather than a
    /// second `NWPathMonitor` of this class's own — same notifications, same
    /// boolean, one subscription. Only touched from inside the loop, so an
    /// `Outbox` that never retries never brings the monitor up.
    func scheduleRetryIfNeeded() {
        guard isRetryLoopEnabled, retryTask == nil, pendingCount > 0 else { return }
        retryTask = Task { [weak self] in
            var delay: Duration = .seconds(30)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                // `drainAll` calls `refreshCounts`, which calls back into
                // `scheduleRetryIfNeeded` — that re-entry is a no-op because
                // `retryTask` is still this task. Clearing it on the way out
                // is what lets the *next* enqueue start a fresh loop.
                if !NetworkMonitor.shared.isOffline {
                    await self.drainAll()
                }
                guard self.pendingCount > 0 else {
                    self.retryTask = nil
                    return
                }
                delay = min(delay * 2, .seconds(300))
            }
        }
    }

    /// Three scalars, three small queries — never `pendingItems()`.
    ///
    /// This used to fetch every queued row (each carrying its full
    /// `payload_json` BLOB) purely to read `.count`, the oldest
    /// `createdAt`, and the first non-nil `lastError`. It runs after every
    /// `enqueue` and every `drainAll`, so a device that spent a while
    /// offline re-materialised and re-decoded its entire queue on each one.
    /// The banner these three back doesn't need a single payload.
    ///
    /// **`createdAt` is decoded through `OutboxItemRecord`, never read off
    /// the row.** This first shipped as `MIN(created_at)` read straight into
    /// a `Double`, which crashed on launch: GRDB's non-throwing `Row`
    /// subscript traps on a failed conversion, and the column does not
    /// actually hold a `Double` — see `OutboxItemRecord`'s own note on why
    /// its date strategy is inert under GRDB 7. Going through the record
    /// means this cannot care what the storage type is, today or after that
    /// is fixed. It costs one row (`ORDER BY created_at LIMIT 1`), not the
    /// queue.
    func refreshCounts() async {
        let summary = try? await dbQueue.read { database -> PendingSummary in
            let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM outbox_items") ?? 0
            let oldest = try OutboxItemRecord.order(Column("created_at")).fetchOne(database)?.createdAt
            let error = try String.fetchOne(
                database,
                sql: """
                SELECT last_error FROM outbox_items
                WHERE last_error IS NOT NULL ORDER BY created_at LIMIT 1
                """
            )
            return PendingSummary(count: count, oldest: oldest, error: error)
        }
        pendingCount = summary?.count ?? 0
        // The one place `pendingCount` changes, and so the one place the
        // retry timer starts and stops — see `scheduleRetryIfNeeded`.
        if pendingCount == 0 {
            retryTask?.cancel()
            retryTask = nil
        } else {
            scheduleRetryIfNeeded()
        }
        oldestPendingAt = summary?.oldest
        lastError = summary?.error
    }

    /// What the pending-sync banner reads, as one row rather than three
    /// queries' worth of loose values.
    private struct PendingSummary {
        let count: Int
        let oldest: Date?
        let error: String?
    }
}
