import Foundation
import GRDB
import KeepoCore
import Network
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
    /// keyed by `externalId`, never an edit of an existing row, and since
    /// migration 20260822100000 the RPC always inserts, so there is no
    /// per-outcome data left for a caller to branch on either.
    func captureTransaction(_ payload: CaptureTransactionPayload) async throws
    func createAccount(_ payload: CreateAccountPayload) async throws
    func updateAccount(_ payload: UpdateAccountPayload) async throws -> Bool
    func setAccountBalance(_ payload: SetAccountBalancePayload) async throws -> Bool
    func archiveAccount(_ payload: ArchiveAccountPayload) async throws -> Bool
    func createCategory(_ payload: CreateCategoryPayload) async throws
    /// No applied/conflict distinction — see `UpdateCategoryPayload`'s own
    /// header comment on why a rename has nothing to conflict against.
    func updateCategory(_ payload: UpdateCategoryPayload) async throws
    /// Neither has a conflict concept — see `RenameCardMappingPayload`/`UnmapCardPayload`'s own comments why.
    func renameCardMapping(_ payload: RenameCardMappingPayload) async throws
    func unmapCard(_ payload: UnmapCardPayload) async throws
    /// No conflict concept either — `map_card` is an upsert keyed by
    /// (owner, card_identifier), same "last write wins" reasoning as rename/unmap.
    func mapCard(_ payload: MapCardPayload) async throws
    func confirmCaptureTransaction(_ payload: ConfirmCaptureTransactionPayload) async throws -> Bool
    func reviewCaptureTransaction(_ payload: ReviewCaptureTransactionPayload) async throws -> Bool
}

// MARK: - Outbox

public enum OutboxSubmitResult: Equatable, Sendable {
    case applied
    case conflict
    case queued
}

public enum OutboxCaptureResult: Equatable, Sendable {
    /// The local-first fast path — always taken as long as a category was
    /// resolvable locally (an unmapped card no longer falls through: the
    /// pending row is written either way, `accountName`/`currency`/
    /// `minorUnit` are simply `nil` when the card isn't resolved yet).
    /// Written and visible in Needs Review — online or offline — before
    /// the background sync attempt that follows even starts; that attempt
    /// never revises what's already here.
    case appliedLocally(CaptureLocalWrite.Resolution)
    /// The rare fallback: the local mirror doesn't even have the owner's
    /// "Other" category synced down yet — an immediate RPC attempt,
    /// exactly as before local-first capture existed. Carries no payload:
    /// the row landed server-side, so nothing about it is on this device
    /// to describe until the next sync pull brings it down.
    case applied
    case queued
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
    /// Why the oldest queued write keeps failing — recorded by `enqueue`
    /// on every failed attempt since the outbox existed, but surfaced
    /// nowhere until a real bug made that gap expensive: a server-side RPC
    /// signature mismatch (an unpushed migration) failed every capture
    /// silently, so the queue simply grew with no visible reason, and the
    /// symptom looked identical to a client sync bug. A write that cannot
    /// reach the server must always be able to say why.
    public private(set) var lastError: String?

    let dbQueue: DatabaseQueue
    let sender: OutboxSending
    private let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    // `deinit` runs in a nonisolated context even on a `@MainActor` class,
    // so it can't otherwise touch actor-isolated state. `pathMonitor` is
    // `Sendable` itself so no annotation is needed; `retryTask` is a
    // mutable `@Observable`-tracked property, which `nonisolated` (without
    // `(unsafe)`) can't be applied to — `(unsafe)` is still required here.
    private let pathMonitor = NWPathMonitor()
    private var isOnline = false
    nonisolated(unsafe) private var retryTask: Task<Void, Never>?

    public init(dbQueue: DatabaseQueue, sender: OutboxSending) {
        self.dbQueue = dbQueue
        self.sender = sender
        Task { await refreshCounts() }
    }

    deinit {
        pathMonitor.cancel()
        retryTask?.cancel()
    }

    public func hasStalePending(threshold: TimeInterval) -> Bool {
        guard let oldestPendingAt else { return false }
        return Date().timeIntervalSince(oldestPendingAt) > threshold
    }

    /// C-10: every existing drain trigger (cold start, sign-in, foreground,
    /// reconnect, manual banner tap) needs an app-lifecycle or connectivity
    /// *event* to fire. A transient 5xx during an otherwise-online, otherwise
    /// idle session left the write parked for however long the user happened
    /// to keep the app foregrounded, with only `hasStalePending`'s 120s
    /// banner as a symptom. Called once by `SessionStore` — not from `init`,
    /// so the short-lived `Outbox` `CaptureIntent` constructs for a single
    /// capture never starts a network monitor it has no use for.
    ///
    /// Backs off 30s → 5min, capped, resetting to the floor once the queue
    /// actually drains — a lingering failure doesn't retry as eagerly as a
    /// fresh one.
    public func startRetryLoop() {
        guard retryTask == nil else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.keepo.outbox-retry-monitor"))
        retryTask = Task { [weak self] in
            var delay: Duration = .seconds(30)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                if self.pendingCount > 0 && self.isOnline {
                    await self.drainAll()
                }
                delay = self.pendingCount > 0 ? min(delay * 2, .seconds(300)) : .seconds(30)
            }
        }
    }

    /// A: every submit* here awaits only the local write-through before
    /// returning — a caller that just wants the UI to be correct immediately
    /// (every screen today) never waits on the network. The delivery attempt
    /// itself (`attempt`, unchanged) still runs to completion and still
    /// drives `pendingCount`/conflict bookkeeping exactly as before; it just
    /// runs in a detached-from-the-caller `Task` instead of being awaited
    /// inline. Callers that genuinely need the outcome (tests, mainly) can
    /// `await` the returned `Task`'s `.value`; every UI call site simply
    /// discards it. A version conflict is no longer knowable synchronously
    /// by the caller — it always surfaces later via `sync_conflicts` / Needs
    /// Review (see NeedsReviewView's conflict-resolution modal), whether the
    /// background attempt resolves it immediately or a later drain does.
    @discardableResult
    public func submitCreateTransaction(_ payload: CreateTransactionPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.createTransaction(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.id, kind: .createTransaction, payload: payload) {
                try await self.sender.createTransaction(payload)
                return true
            }
        }
    }

    @discardableResult
    public func submitCreateTransfer(_ payload: CreateTransferPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.createTransfer(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.fromId, kind: .createTransfer, payload: payload) {
                try await self.sender.createTransfer(payload)
                return true
            }
        }
    }

    @discardableResult
    public func submitUpdateTransaction(_ payload: UpdateTransactionPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.updateTransaction(payload, in: $0) }
        return Task {
            await self.attempt(
                id: payload.id, kind: .updateTransaction, payload: payload, expectedVersion: payload.expectedVersion
            ) {
                try await self.sender.updateTransaction(payload)
            }
        }
    }

    @discardableResult
    public func submitUpdateTransfer(_ payload: UpdateTransferPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.updateTransfer(payload, in: $0) }
        return Task {
            await self.attempt(
                id: payload.transferGroupId, kind: .updateTransfer, payload: payload,
                expectedVersion: payload.fromExpectedVersion
            ) {
                try await self.sender.updateTransfer(payload)
            }
        }
    }

    @discardableResult
    public func submitDeleteTransaction(_ payload: DeleteTransactionPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.deleteTransaction(payload, in: $0) }
        return Task {
            await self.attempt(
                id: payload.id, kind: .deleteTransaction, payload: payload, expectedVersion: payload.expectedVersion
            ) {
                try await self.sender.deleteTransaction(payload)
            }
        }
    }

    @discardableResult
    public func submitDeleteTransfer(_ payload: DeleteTransferPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.deleteTransfer(payload, in: $0) }
        return Task {
            await self.attempt(
                id: payload.transferGroupId, kind: .deleteTransfer, payload: payload,
                expectedVersion: payload.fromExpectedVersion
            ) {
                try await self.sender.deleteTransfer(payload)
            }
        }
    }

    /// See `Outbox+Capture.swift` — split out purely to keep this file
    /// under the project's file-length lint threshold, same precedent as
    /// `Outbox+AccountsCategories.swift`.
    func resolveAndApplyCaptureLocally(
        _ payload: CaptureTransactionPayload, ownerId: UUID
    ) async -> CaptureLocalWrite.Resolution? {
        try? await dbQueue.write { database in
            try CaptureLocalWrite.resolveAndWrite(payload, ownerId: ownerId.uuidString, in: database)
        }
    }

    /// FIFO by `createdAt` — the order rows first needed syncing, not the
    /// order they were last edited.
    public func drainAll() async {
        for item in await pendingItems() {
            await drain(item)
        }
        await refreshCounts()
    }

    /// Best-effort optimistic write into the local GRDB mirror — see
    /// `OutboxLocalWrite`'s own header for why this exists and why it's
    /// `try?`, never a thrown failure the caller has to handle. Internal,
    /// not private: `Outbox+AccountsCategories.swift`'s submit methods call
    /// it too.
    func applyLocally(_ apply: @escaping @Sendable (Database) throws -> Void) async {
        try? await dbQueue.write { database in try apply(database) }
    }

    func attempt<P: Encodable>(
        id: UUID, kind: OutboxKind, payload: P, expectedVersion: Int? = nil, send: () async throws -> Bool
    ) async -> OutboxSubmitResult {
        do {
            let applied = try await send()
            return applied ? .applied : .conflict
        } catch {
            await enqueue(
                id: id, kind: kind, payload: payload, expectedVersion: expectedVersion,
                lastError: String(describing: error)
            )
            return .queued
        }
    }

    /// Found chasing a real bug: this used to always overwrite whatever was
    /// already queued under `id`, on the reasoning that only the latest
    /// desired state ever needs to reach the server — correct for two
    /// edits to the same *already-existing* row, but wrong when the
    /// existing item is a still-undelivered `.captureTransaction` (the
    /// row's own create). Overwriting it discards the create entirely: the
    /// row never exists server-side, so the write that replaced it
    /// (confirm/update/delete) fails forever with "not found," retrying an
    /// operation that can never succeed. A dependent write for a row whose
    /// create hasn't landed yet is queued as its own new item instead —
    /// its `createdAt` sorts after the create's, so `drainAll`'s FIFO order
    /// replays the create first and this write second, same outcome as if
    /// both had gone out over the wire in the order the user made them.
    func enqueue<P: Encodable>(
        id: UUID, kind: OutboxKind, payload: P, expectedVersion: Int?, lastError: String?
    ) async {
        guard let data = try? encoder.encode(payload) else { return }
        try? await dbQueue.write { database in
            if let existing = try OutboxItemRecord.fetchOne(database, key: id),
               existing.kind == OutboxKind.captureTransaction.rawValue, kind != .captureTransaction {
                try OutboxItemRecord(
                    id: UUID(), kind: kind.rawValue, payloadJSON: data, expectedVersion: expectedVersion,
                    createdAt: Date(), attempts: 1, lastError: lastError
                ).insert(database)
                return
            }
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
        await refreshCounts()
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
        case .createTransaction, .createTransfer, .updateTransaction, .updateTransfer, .deleteTransaction,
             .deleteTransfer, .captureTransaction, .confirmCaptureTransaction, .reviewCapture:
            return try await replayTransaction(kind, data: item.payloadJSON)
        case .createAccount, .updateAccount, .setAccountBalance, .archiveAccount, .createCategory, .updateCategory:
            return try await replayAccountOrCategory(kind, data: item.payloadJSON)
        case .renameCardMapping, .unmapCard, .mapCard:
            return try await replayCardMapping(kind, data: item.payloadJSON)
        }
    }

    private func replayTransaction(_ kind: OutboxKind, data: Data) async throws -> Bool {
        switch kind {
        case .createTransaction:
            try await sender.createTransaction(decoder.decode(CreateTransactionPayload.self, from: data))
            return true
        case .createTransfer:
            try await sender.createTransfer(decoder.decode(CreateTransferPayload.self, from: data))
            return true
        case .updateTransaction:
            return try await sender.updateTransaction(decoder.decode(UpdateTransactionPayload.self, from: data))
        case .updateTransfer:
            return try await sender.updateTransfer(decoder.decode(UpdateTransferPayload.self, from: data))
        case .deleteTransaction:
            return try await sender.deleteTransaction(decoder.decode(DeleteTransactionPayload.self, from: data))
        case .deleteTransfer:
            return try await sender.deleteTransfer(decoder.decode(DeleteTransferPayload.self, from: data))
        case .captureTransaction:
            try await sender.captureTransaction(decoder.decode(CaptureTransactionPayload.self, from: data))
            return true
        case .confirmCaptureTransaction:
            let payload = try decoder.decode(ConfirmCaptureTransactionPayload.self, from: data)
            return try await sender.confirmCaptureTransaction(payload)
        case .reviewCapture:
            let payload = try decoder.decode(ReviewCaptureTransactionPayload.self, from: data)
            return try await sender.reviewCaptureTransaction(payload)
        default:
            return true
        }
    }

    private func pendingItems() async -> [OutboxItemRecord] {
        (try? await dbQueue.read { database in
            try OutboxItemRecord.order(Column("created_at")).fetchAll(database)
        }) ?? []
    }

    private func refreshCounts() async {
        let items = await pendingItems()
        pendingCount = items.count
        oldestPendingAt = items.first?.createdAt
        lastError = items.compactMap(\.lastError).first
    }
}
