import Foundation
import KeepoCore

// The App Intent's write, split out of Outbox.swift purely to keep that
// file under the project's file-length lint threshold — same precedent as
// Outbox+AccountsCategories.swift.

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
            occurredAt: payload.occurredAt, merchantRaw: payload.merchantRaw, notes: payload.notes
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
        return Task {
            await self.attempt(
                id: payload.id, kind: .reviewCapture, payload: payload, expectedVersion: payload.expectedVersion
            ) {
                try await self.sender.reviewCaptureTransaction(payload)
            }
        }
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
            return .appliedLocally(
                accountName: resolution.accountName, categoryName: resolution.categoryName,
                currency: resolution.currency, minorUnit: resolution.minorUnit
            )
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
