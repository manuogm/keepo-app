import Foundation
import KeepoCore
import Supabase

// Split out of Outbox.swift purely to keep that file under the project's
// file-length lint threshold — same precedent as Outbox+AccountsCategories.swift.
// `renameCardMapping`/`unmapCard`/`mapCard` (Outbox+Cards.swift) and
// `confirmCaptureTransaction` (Outbox+Capture.swift) live in their own
// extensions elsewhere for the same reason.

/// The real, network-backed sender — a thin wrapper around
/// `TransactionRepository`. A retry of `createTransaction`/`createTransfer`
/// that actually already succeeded server-side hits `transactions`'
/// primary key (23505); that specific error is swallowed here rather than
/// surfaced as a failure, since it means the write already landed, not that
/// it failed (migration 20260807140000's whole reason for existing).
public struct LiveOutboxSender: OutboxSending {
    let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func createTransaction(_ payload: CreateTransactionPayload) async throws {
        do {
            try await TransactionRepository.create(
                client: client, id: payload.id, ownerId: payload.ownerId, accountId: payload.accountId,
                categoryId: payload.categoryId, amountE4: payload.amountE4, currency: payload.currency,
                occurredAt: payload.occurredAt, notes: payload.notes
            )
        } catch {
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    public func createTransfer(_ payload: CreateTransferPayload) async throws {
        do {
            try await TransactionRepository.createTransfer(
                client: client, fromAccountId: payload.fromAccountId, toAccountId: payload.toAccountId,
                fromAmountE4: payload.fromAmountE4, toAmountE4: payload.toAmountE4, occurredAt: payload.occurredAt,
                fromId: payload.fromId, toId: payload.toId, notes: payload.notes
            )
        } catch {
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    public func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool {
        let result = try await TransactionRepository.update(
            client: client, id: payload.id, expectedVersion: payload.expectedVersion, accountId: payload.accountId,
            categoryId: payload.categoryId, amountE4: payload.amountE4, currency: payload.currency,
            occurredAt: payload.occurredAt, merchantRaw: payload.merchantRaw, notes: payload.notes
        )
        switch result {
        case .saved: return true
        case .conflict: return false
        }
    }

    public func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool {
        let result = try await TransactionRepository.updateTransfer(
            client: client, transferGroupId: payload.transferGroupId,
            fromExpectedVersion: payload.fromExpectedVersion, toExpectedVersion: payload.toExpectedVersion,
            fromAmountE4: payload.fromAmountE4, toAmountE4: payload.toAmountE4,
            occurredAt: payload.occurredAt, notes: payload.notes
        )
        switch result {
        case .saved: return true
        case .conflict: return false
        }
    }

    public func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool {
        try await TransactionRepository.delete(client: client, id: payload.id, expectedVersion: payload.expectedVersion)
    }

    public func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool {
        try await TransactionRepository.deleteTransfer(
            client: client, transferGroupId: payload.transferGroupId,
            fromExpectedVersion: payload.fromExpectedVersion, toExpectedVersion: payload.toExpectedVersion
        )
    }

    public func captureTransaction(_ payload: CaptureTransactionPayload) async throws {
        do {
            try await CaptureRepository.capture(
                client: client, id: payload.id, cardIdentifier: payload.cardIdentifier,
                merchantRaw: payload.merchantRaw, merchantNormalized: payload.merchantNormalized,
                amountE4: payload.amountE4, occurredAt: payload.occurredAt, externalId: payload.externalId,
                notes: payload.notes
            )
        } catch {
            // A retried capture already landed under this id — the write
            // succeeded, so this is not a failure to re-queue.
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    static func isDuplicateKey(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }
}
