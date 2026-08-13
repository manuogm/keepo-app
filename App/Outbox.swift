import Foundation
import GRDB
import KeepoCore
import Supabase

// MARK: - The testable seam

/// Everything the outbox needs to actually deliver a write. `Bool` returns
/// mean applied (`true`)/conflict (`false`) — conflict-as-data, never
/// thrown, exactly like the RPCs themselves (a thrown error here means a
/// real failure — offline, a 5xx, ... — and leaves the item queued).
public protocol OutboxSending: Sendable {
    func createTransaction(_ payload: CreateTransactionPayload) async throws
    func createTransfer(_ payload: CreateTransferPayload) async throws
    func updateTransaction(_ payload: UpdateTransactionPayload) async throws -> Bool
    func updateTransfer(_ payload: UpdateTransferPayload) async throws -> Bool
    func deleteTransaction(_ payload: DeleteTransactionPayload) async throws -> Bool
    func deleteTransfer(_ payload: DeleteTransferPayload) async throws -> Bool
    /// No conflict/applied distinction — a capture is an insert-or-noop
    /// keyed by `externalId`, never an edit of an existing row. `mapped`
    /// tells the caller (the App Intent, composing its local notification)
    /// whether the card was already known; it is not a retry signal.
    func captureTransaction(_ payload: CaptureTransactionPayload) async throws -> CaptureResult
    func createAccount(_ payload: CreateAccountPayload) async throws
    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool
    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool
    func createCategory(_ payload: CreateCategoryPayload) async throws
    /// No applied/conflict distinction — see `UpdateCategoryPayload`'s own
    /// header comment on why a rename has nothing to conflict against.
    func updateCategory(_ payload: UpdateCategoryPayload) async throws
}

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
                occurredAt: payload.occurredAt
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
                fromId: payload.fromId, toId: payload.toId
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
            occurredAt: payload.occurredAt, merchantRaw: payload.merchantRaw
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
            fromAmountE4: payload.fromAmountE4, toAmountE4: payload.toAmountE4, occurredAt: payload.occurredAt
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

    public func captureTransaction(_ payload: CaptureTransactionPayload) async throws -> CaptureResult {
        do {
            return try await CaptureRepository.capture(
                client: client, id: payload.id, cardIdentifier: payload.cardIdentifier,
                merchantRaw: payload.merchantRaw, merchantNormalized: payload.merchantNormalized,
                amountE4: payload.amountE4, occurredAt: payload.occurredAt, externalId: payload.externalId
            )
        } catch {
            // A retried capture already landed under this id — we don't know
            // whether it was mapped without a re-fetch, and nothing reads
            // this result on the drain path (see Outbox.replay below), so a
            // placeholder is fine here; only the immediate, non-retry call
            // from CaptureIntent ever surfaces `mapped` to a human.
            if Self.isDuplicateKey(error) { return CaptureResult(mapped: true, accountId: nil) }
            throw error
        }
    }

    static func isDuplicateKey(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }
}

// MARK: - Outbox

public enum OutboxSubmitResult: Equatable {
    case applied
    case conflict
    case queued
}

public enum OutboxCaptureResult: Equatable, Sendable {
    case applied(mapped: Bool)
    case queued
}

enum OutboxKind: String {
    case createTransaction, createTransfer, updateTransaction, updateTransfer, deleteTransaction, deleteTransfer
    case captureTransaction
    case createAccount, updateAccount, setAccountBalance, createCategory, updateCategory
}

/// Every write attempts to send immediately; only a thrown error (offline,
/// a real server failure) falls back to queuing. `conflict = true` is a
/// successful delivery — the server already logged it to `sync_conflicts`
/// — so it's treated exactly like `.applied` for queuing purposes: nothing
/// left to retry. Repeated offline edits to the SAME row collapse into one
/// queued entry (keyed by the row's own id) rather than piling up — the
/// whole point of "whole-row payloads, never per-field merge" is that only
/// the latest desired state needs to reach the server at all.
@Observable
@MainActor
public final class Outbox {
    public private(set) var pendingCount = 0
    public private(set) var oldestPendingAt: Date?

    private let dbQueue: DatabaseQueue
    let sender: OutboxSending
    private let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    public init(dbQueue: DatabaseQueue, sender: OutboxSending) {
        self.dbQueue = dbQueue
        self.sender = sender
        refreshCounts()
    }

    public func hasStalePending(threshold: TimeInterval) -> Bool {
        guard let oldestPendingAt else { return false }
        return Date().timeIntervalSince(oldestPendingAt) > threshold
    }

    @discardableResult
    public func submitCreateTransaction(_ payload: CreateTransactionPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.createTransaction(payload, in: $0) }
        return await attempt(id: payload.id, kind: .createTransaction, payload: payload) {
            try await self.sender.createTransaction(payload)
            return true
        }
    }

    @discardableResult
    public func submitCreateTransfer(_ payload: CreateTransferPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.createTransfer(payload, in: $0) }
        return await attempt(id: payload.fromId, kind: .createTransfer, payload: payload) {
            try await self.sender.createTransfer(payload)
            return true
        }
    }

    @discardableResult
    public func submitUpdateTransaction(_ payload: UpdateTransactionPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.updateTransaction(payload, in: $0) }
        return await attempt(
            id: payload.id, kind: .updateTransaction, payload: payload, expectedVersion: payload.expectedVersion
        ) {
            try await self.sender.updateTransaction(payload)
        }
    }

    @discardableResult
    public func submitUpdateTransfer(_ payload: UpdateTransferPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.updateTransfer(payload, in: $0) }
        return await attempt(
            id: payload.transferGroupId, kind: .updateTransfer, payload: payload,
            expectedVersion: payload.fromExpectedVersion
        ) {
            try await self.sender.updateTransfer(payload)
        }
    }

    @discardableResult
    public func submitDeleteTransaction(_ payload: DeleteTransactionPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.deleteTransaction(payload, in: $0) }
        return await attempt(
            id: payload.id, kind: .deleteTransaction, payload: payload, expectedVersion: payload.expectedVersion
        ) {
            try await self.sender.deleteTransaction(payload)
        }
    }

    @discardableResult
    public func submitDeleteTransfer(_ payload: DeleteTransferPayload) async -> OutboxSubmitResult {
        applyLocally { try OutboxLocalWrite.deleteTransfer(payload, in: $0) }
        return await attempt(
            id: payload.transferGroupId, kind: .deleteTransfer, payload: payload,
            expectedVersion: payload.fromExpectedVersion
        ) {
            try await self.sender.deleteTransfer(payload)
        }
    }

    /// The App Intent's write. Not routed through the generic `attempt`
    /// helper — a capture's success has a third piece of information
    /// (`mapped`) the intent needs for its notification text, which the
    /// applied/conflict `Bool` every other write shares can't carry.
    public func submitCaptureTransaction(_ payload: CaptureTransactionPayload) async -> OutboxCaptureResult {
        do {
            let result = try await sender.captureTransaction(payload)
            return .applied(mapped: result.mapped)
        } catch {
            enqueue(
                id: payload.id, kind: .captureTransaction, payload: payload, expectedVersion: nil,
                lastError: String(describing: error)
            )
            return .queued
        }
    }

    /// FIFO by `createdAt` — the order rows first needed syncing, not the
    /// order they were last edited.
    public func drainAll() async {
        for item in pendingItems() {
            await drain(item)
        }
        refreshCounts()
    }

    /// Best-effort optimistic write into the local GRDB mirror — see
    /// `OutboxLocalWrite`'s own header for why this exists and why it's
    /// `try?`, never a thrown failure the caller has to handle. Internal,
    /// not private: `Outbox+AccountsCategories.swift`'s submit methods call
    /// it too.
    func applyLocally(_ apply: @escaping (Database) throws -> Void) {
        try? dbQueue.write { database in try apply(database) }
    }

    func attempt<P: Encodable>(
        id: UUID, kind: OutboxKind, payload: P, expectedVersion: Int? = nil, send: () async throws -> Bool
    ) async -> OutboxSubmitResult {
        do {
            let applied = try await send()
            return applied ? .applied : .conflict
        } catch {
            enqueue(
                id: id, kind: kind, payload: payload, expectedVersion: expectedVersion,
                lastError: String(describing: error)
            )
            return .queued
        }
    }

    private func enqueue<P: Encodable>(
        id: UUID, kind: OutboxKind, payload: P, expectedVersion: Int?, lastError: String?
    ) {
        guard let data = try? encoder.encode(payload) else { return }
        try? dbQueue.write { database in
            if var existing = try OutboxItemRecord.fetchOne(database, key: id) {
                existing.kind = kind.rawValue
                existing.payloadJSON = data
                existing.expectedVersion = expectedVersion
                existing.attempts += 1
                existing.lastError = lastError
                try existing.update(database)
            } else {
                try OutboxItemRecord(
                    id: id, kind: kind.rawValue, payloadJSON: data, expectedVersion: expectedVersion,
                    createdAt: Date(), attempts: 1, lastError: lastError
                ).insert(database)
            }
        }
        refreshCounts()
    }

    private func drain(_ item: OutboxItemRecord) async {
        do {
            _ = try await replay(item)
            try? await dbQueue.write { database in _ = try item.delete(database) }
        } catch {
            try? await dbQueue.write { database in
                if var current = try OutboxItemRecord.fetchOne(database, key: item.id) {
                    current.attempts += 1
                    current.lastError = String(describing: error)
                    try current.update(database)
                }
            }
        }
    }

    /// Returns applied/conflict — both mean "delivered," so `drain(_:)`
    /// dequeues either way. An unrecognized `kind` (should never happen;
    /// nothing removes cases from `OutboxKind`) is dropped rather than
    /// retried forever against a decoder that can never succeed.
    private func replay(_ item: OutboxItemRecord) async throws -> Bool {
        guard let kind = OutboxKind(rawValue: item.kind) else { return true }
        switch kind {
        case .createTransaction:
            try await sender.createTransaction(decoder.decode(CreateTransactionPayload.self, from: item.payloadJSON))
            return true
        case .createTransfer:
            try await sender.createTransfer(decoder.decode(CreateTransferPayload.self, from: item.payloadJSON))
            return true
        case .updateTransaction:
            let payload = try decoder.decode(UpdateTransactionPayload.self, from: item.payloadJSON)
            return try await sender.updateTransaction(payload)
        case .updateTransfer:
            return try await sender.updateTransfer(decoder.decode(UpdateTransferPayload.self, from: item.payloadJSON))
        case .deleteTransaction:
            let payload = try decoder.decode(DeleteTransactionPayload.self, from: item.payloadJSON)
            return try await sender.deleteTransaction(payload)
        case .deleteTransfer:
            return try await sender.deleteTransfer(decoder.decode(DeleteTransferPayload.self, from: item.payloadJSON))
        case .captureTransaction:
            let payload = try decoder.decode(CaptureTransactionPayload.self, from: item.payloadJSON)
            _ = try await sender.captureTransaction(payload)
            return true
        case .createAccount, .updateAccount, .setAccountBalance, .createCategory, .updateCategory:
            return try await replayAccountOrCategory(kind, data: item.payloadJSON)
        }
    }

    private func pendingItems() -> [OutboxItemRecord] {
        (try? dbQueue.read { database in
            try OutboxItemRecord.order(Column("created_at")).fetchAll(database)
        }) ?? []
    }

    private func refreshCounts() {
        let items = pendingItems()
        pendingCount = items.count
        oldestPendingAt = items.first?.createdAt
    }
}
