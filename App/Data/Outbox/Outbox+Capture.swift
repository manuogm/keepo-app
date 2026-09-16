import Foundation
import KeepoCore

// The App Intent's write, split out of Outbox.swift purely to keep that
// file under the project's file-length lint threshold — same precedent as
// Outbox+AccountsCategories.swift.
//
// The two "a capture was resolved" writes below also call
// `ReviewPrompter.recordCaptureResolved`. This is the choke point every
// path already funnels through — the Needs Review panel, the transactions
// list, the transaction form, and `CaptureQuickActionHandler`'s two
// notification actions — which is exactly why the rating rule is armed
// here rather than by a screen watching a count: two of those five call
// sites run with the app backgrounded, where no screen is evaluating
// anything (see `ReviewPolicy.shouldArm`).

extension LiveOutboxSender {
    public func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool {
        let result = try await CaptureRepository.confirmCapture(
            client: client, id: payload.id, expectedVersion: payload.expectedVersion
        )
        switch result {
        case .saved: return true
        case .conflict: return false
        }
    }

    public func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool {
        let result = try await CaptureRepository.reviewCapture(
            client: client, id: payload.id, expectedVersion: payload.expectedVersion, accountId: payload.accountId,
            categoryId: payload.categoryId, amountE4: payload.amountE4, currency: payload.currency,
            occurredAt: payload.occurredAt, merchantRaw: payload.merchantRaw, notes: payload.notes,
            original: payload.original
        )
        switch result {
        case .saved: return true
        case .conflict: return false
        }
    }
}

extension Outbox {
    /// The Needs Review "review, then confirm" write — local-first exactly
    /// like every other transaction edit, so the item disappears from the
    /// inbox the instant this returns, not after a network round trip (the
    /// direct-RPC path this replaced awaited the server before anything
    /// visually changed, the actual cause of the inbox feeling laggy).
    @discardableResult
    public func submitConfirmCaptureTransaction(
        _ payload: ConfirmCaptureTransactionPayload
    ) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.confirmCaptureTransaction(payload, in: $0) }
        await ReviewPrompter.recordCaptureResolved(id: payload.id, dbQueue: dbQueue)
        return Task {
            await self.attempt(
                id: payload.id, kind: .confirmCaptureTransaction, payload: payload,
                expectedVersion: payload.expectedVersion
            ) {
                try await self.sender.confirmCaptureTransaction(payload)
            }
        }
    }

    /// The single-write replacement for what used to be a
    /// `submitUpdateTransaction` + `submitConfirmCaptureTransaction` pair —
    /// see `ReviewCaptureTransactionPayload`'s own header for why sending
    /// them separately was a real bug (a race, and an offline data-loss
    /// hazard), not just a style preference. One outbox item, one queued
    /// write, exactly like every other edit here.
    @discardableResult
    public func submitReviewCaptureTransaction(
        _ payload: ReviewCaptureTransactionPayload
    ) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.reviewCaptureTransaction(payload, in: $0) }
        await ReviewPrompter.recordCaptureResolved(id: payload.id, dbQueue: dbQueue)
        return Task {
            await self.attempt(
                id: payload.id, kind: .reviewCapture, payload: payload, expectedVersion: payload.expectedVersion
            ) {
                try await self.sender.reviewCaptureTransaction(payload)
            }
        }
    }

    /// The onboarding test capture: written to the local mirror and
    /// **never pushed**.
    ///
    /// Staying local is not squeamishness about fake data, it closes a real
    /// failure. `capture_transaction` unconditionally upserts a
    /// `card_mappings` placeholder for every identifier it sees
    /// (`20260822100000_unmapped_capture_lands_locally.sql`), and
    /// `needs_review`'s `ambiguous_card` branch reads exactly those
    /// placeholders — suppressed only *while* a matching pending capture
    /// exists. So a server-bound test capture would sit quietly in the
    /// inbox and then, **the moment the user deleted it as instructed**,
    /// resurface as "Unmapped card" asking them to map fake data to a real
    /// account. The delete would appear to have caused it.
    ///
    /// `CaptureLocalWrite` deliberately never creates that placeholder, so
    /// the local path was already right; this just declines to take the
    /// other one. Three more things follow for free: the fake merchant and
    /// card never reach Supabase at all, `resolve_category_for_merchant`
    /// never learns from them, and nothing enters the server's inbox.
    ///
    /// - Returns: `nil` when the local write could not resolve a category —
    ///   the owner's `is_default` "Other" has not synced down yet — which
    ///   the caller reports rather than retrying against the network,
    ///   because there is no network path for this write by design.
    public func submitTestCaptureTransaction(
        _ payload: CaptureTransactionPayload, ownerId: UUID
    ) async -> CaptureLocalWrite.Resolution? {
        await resolveAndApplyCaptureLocally(payload, ownerId: ownerId)
    }

    /// Not routed through the generic `attempt` helper — a capture's
    /// success has richer information (the resolved account/category) the
    /// intent needs for its notification text, which the applied/conflict
    /// `Bool` every other write shares can't carry.
    ///
    /// `ownerId` defaults to `nil` for callers with no session-scoped id to
    /// hand in (some tests) — without it, `CaptureLocalWrite` has nothing to
    /// scope its local reads to, so this falls straight through to the
    /// RPC-or-queue path below. In production that's still reachable in two
    /// cases: the owner's "Other" category hasn't synced down locally yet
    /// (a capture firing before the very first post-signup sync pull
    /// completes), or the device is genuinely signed out at capture time —
    /// there is no local owner id to scope a write to until sign-in.
    public func submitCaptureTransaction(
        _ payload: CaptureTransactionPayload, ownerId: UUID? = nil
    ) async -> OutboxCaptureResult {
        if let ownerId, let resolution = await resolveAndApplyCaptureLocally(payload, ownerId: ownerId) {
            Task {
                await self.attempt(id: payload.id, kind: .captureTransaction, payload: payload) {
                    try await self.sender.captureTransaction(payload)
                    return true
                }
            }
            return .appliedLocally(resolution)
        }

        do {
            try await sender.captureTransaction(payload)
            return .applied
        } catch {
            await enqueue(
                id: payload.id, kind: .captureTransaction, payload: payload, expectedVersion: nil,
                lastError: String(describing: error)
            )
            return .queued
        }
    }
}
