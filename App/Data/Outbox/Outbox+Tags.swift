import Foundation
import GRDB
import KeepoCore

// Tags going through the outbox — split out of Outbox.swift for the same
// reason Outbox+AccountsCategories.swift is: this project's file-length
// lint. Same three layers as every other write here (sender, local
// write-through, submit), in the same order.

// MARK: - Payloads

/// Deleting a tag IS in the outbox, unlike deleting a category — the two are
/// different operations wearing the same word. A category delete has to
/// reassign every transaction that used it and shows a live count first, so
/// it is deliberately online-only (`CategoryRepository.deleteWithReassign`'s
/// own header). A tag delete reassigns nothing: the server's
/// `tags_cascade_soft_delete` trigger soft-deletes the links and there is no
/// number to confirm against, so it queues offline like any other edit.
public struct CreateTagPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let name: String

    public init(id: UUID, ownerId: UUID, name: String) {
        self.id = id
        self.ownerId = ownerId
        self.name = name
    }
}

/// No `expectedVersion`, same reasoning as `UpdateCategoryPayload`: a rename
/// has nothing to conflict against. Two devices renaming one tag both meant
/// to rename it, and last-write-wins is the answer either of them expects.
public struct UpdateTagPayload: Codable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DeleteTagPayload: Codable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

/// Applying and un-applying are one payload with a flag, not two kinds: the
/// server side is a single upsert either way (`transaction_tags` is
/// soft-deleted, so removing a tag revives-then-tombstones the same row
/// rather than deleting it), and two outbox kinds for one statement would
/// have to be kept in step forever.
public struct SetTransactionTagPayload: Codable, Sendable {
    public let transactionId: UUID
    public let tagId: UUID
    /// Sent because the column is NOT NULL; the server overwrites it from the
    /// transaction (`set_transaction_tag_derived_columns`). It matters only
    /// for the local write-through, which has no trigger to do that for it.
    public let ownerId: UUID
    public let isApplied: Bool

    public init(transactionId: UUID, tagId: UUID, ownerId: UUID, isApplied: Bool) {
        self.transactionId = transactionId
        self.tagId = tagId
        self.ownerId = ownerId
        self.isApplied = isApplied
    }
}

// MARK: - LiveOutboxSender

extension LiveOutboxSender {
    public func createTag(_ payload: CreateTagPayload) async throws {
        do {
            try await TagRepository.create(
                client: client, id: payload.id, ownerId: payload.ownerId, name: payload.name
            )
        } catch {
            // A retried create that already landed hits `tags`' primary key.
            // A *different* tag with the same name hits the
            // `tags_owner_name_idx` unique index instead — also a 23505, and
            // also correctly a no-op from the queue's point of view: the
            // user's name is already taken by a tag that exists, so retrying
            // forever would never succeed.
            if Self.isDuplicateKey(error) { return }
            throw error
        }
    }

    public func updateTag(_ payload: UpdateTagPayload) async throws {
        try await TagRepository.update(client: client, tagId: payload.id, name: payload.name)
    }

    public func deleteTag(_ payload: DeleteTagPayload) async throws {
        try await TagRepository.softDelete(client: client, tagId: payload.id)
    }

    public func setTransactionTag(_ payload: SetTransactionTagPayload) async throws {
        try await TagRepository.setApplied(
            client: client, transactionId: payload.transactionId, tagId: payload.tagId,
            ownerId: payload.ownerId, isApplied: payload.isApplied
        )
    }
}

// MARK: - Outbox

extension Outbox {
    @discardableResult
    public func submitCreateTag(_ payload: CreateTagPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.createTag(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.id, kind: .createTag, payload: payload) {
                try await self.sender.createTag(payload)
                return true
            }
        }
    }

    @discardableResult
    public func submitUpdateTag(_ payload: UpdateTagPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.updateTag(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.id, kind: .updateTag, payload: payload) {
                try await self.sender.updateTag(payload)
                return true
            }
        }
    }

    @discardableResult
    public func submitDeleteTag(_ payload: DeleteTagPayload) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.deleteTag(payload, in: $0) }
        return Task {
            await self.attempt(id: payload.id, kind: .deleteTag, payload: payload) {
                try await self.sender.deleteTag(payload)
                return true
            }
        }
    }

    /// Keyed on the **pair**, not on either id: a transaction's Coffee tag
    /// and its Holiday tag are independent queue items, and keying on the
    /// transaction alone would let the second overwrite the first before
    /// either was sent.
    @discardableResult
    public func submitSetTransactionTag(
        _ payload: SetTransactionTagPayload
    ) async -> Task<OutboxSubmitResult, Never> {
        await applyLocally { try OutboxLocalWrite.setTransactionTag(payload, in: $0) }
        let key = StableSeed.uuid(from: "\(payload.transactionId.uuidString):\(payload.tagId.uuidString)")
        return Task {
            await self.attempt(id: key, kind: .setTransactionTag, payload: payload) {
                try await self.sender.setTransactionTag(payload)
                return true
            }
        }
    }

    /// Called only for the cases `replay(_:)` delegates here — the `default`
    /// branch is unreachable in practice, kept only because a non-exhaustive
    /// switch over `OutboxKind` isn't allowed.
    func replayTag(_ kind: OutboxKind, data: Data) async throws -> Bool {
        switch kind {
        case .createTag:
            try await sender.createTag(decoder.decode(CreateTagPayload.self, from: data))
            return true
        case .updateTag:
            try await sender.updateTag(decoder.decode(UpdateTagPayload.self, from: data))
            return true
        case .deleteTag:
            try await sender.deleteTag(decoder.decode(DeleteTagPayload.self, from: data))
            return true
        case .setTransactionTag:
            try await sender.setTransactionTag(decoder.decode(SetTransactionTagPayload.self, from: data))
            return true
        default:
            return true
        }
    }
}

// MARK: - Local write-through

extension OutboxLocalWrite {
    static func createTag(_ payload: CreateTagPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "owner_id": .string(payload.ownerId.uuidString),
                "name": .string(payload.name),
                "version": .integer(1), "created_at": .string(now), "updated_at": .string(now),
                "sync_seq": .integer(0)
            ],
            table: "tags", in: database
        )
    }

    static func updateTag(_ payload: UpdateTagPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "id": .string(payload.id.uuidString), "name": .string(payload.name),
                "updated_at": .string(now)
            ],
            table: "tags", in: database
        )
    }

    /// Mirrors the server's `tags_cascade_soft_delete` trigger, which the
    /// local mirror has no equivalent of: tombstone the tag AND every link
    /// to it, or the transaction form keeps drawing a chip for a tag the
    /// Tags screen no longer lists.
    static func deleteTag(_ payload: DeleteTagPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try database.execute(
            sql: "UPDATE tags SET deleted_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, payload.id.uuidString]
        )
        try database.execute(
            sql: """
            UPDATE transaction_tags SET deleted_at = ?, updated_at = ?
            WHERE tag_id = ? AND deleted_at IS NULL
            """,
            arguments: [now, now, payload.id.uuidString]
        )
    }

    static func setTransactionTag(_ payload: SetTransactionTagPayload, in database: Database) throws {
        let now = PostgresDate.sqliteTimestampBoundaryString(Date())
        try SyncApply.upsertRow(
            [
                "transaction_id": .string(payload.transactionId.uuidString),
                "tag_id": .string(payload.tagId.uuidString),
                "owner_id": .string(payload.ownerId.uuidString),
                "created_at": .string(now), "updated_at": .string(now),
                "deleted_at": payload.isApplied ? .null : .string(now),
                "sync_seq": .integer(0)
            ],
            table: "transaction_tags", in: database
        )
    }
}
