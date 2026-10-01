import Foundation
import KeepoCore

// MARK: - Payloads (whole-row, never a per-field merge)

public struct CreateTransactionPayload: Codable, Sendable {
    public let id: UUID
    /// The account's owner, who owns every row on it — not necessarily the
    /// person entering it (`(account_id, owner_id)` is a foreign key).
    public let ownerId: UUID
    /// Who entered it, when that is not the owner: a partner logging on the
    /// owner's shared account. Nil means the owner, which is also what an
    /// item queued before this existed decodes to.
    public let createdBy: UUID?
    public let accountId: UUID
    public let categoryId: UUID
    public let amountE4: Int64
    public let currency: String
    public let occurredAt: Date
    public let notes: String?
    /// Non-nil only for a purchase made in another currency. Optional in
    /// the stored payload as well as in the type, so an item queued before
    /// this existed still decodes — `decodeIfPresent` is what Swift
    /// synthesizes for an `Optional` property.
    public let original: ForeignOriginal?
    /// The user's own name for the row, trimmed, or `nil` for none. Optional
    /// in the stored payload too, so an item queued before titles existed
    /// still decodes.
    public let title: String?

    public init(
        id: UUID, ownerId: UUID, createdBy: UUID? = nil, accountId: UUID, categoryId: UUID, amountE4: Int64,
        currency: String, occurredAt: Date, notes: String? = nil, original: ForeignOriginal? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.createdBy = createdBy
        self.accountId = accountId
        self.categoryId = categoryId
        self.amountE4 = amountE4
        self.currency = currency
        self.occurredAt = occurredAt
        self.notes = notes
        self.original = original
        self.title = title
    }
}

public struct CreateTransferPayload: Codable, Sendable {
    public let fromId: UUID
    public let toId: UUID
    public let fromAccountId: UUID
    public let toAccountId: UUID
    public let fromAmountE4: Int64
    public let toAmountE4: Int64?
    public let occurredAt: Date
    /// Written to BOTH legs — a transfer is one act by the user, and either
    /// account's history read on its own must still show what they wrote.
    /// Optional so an already-queued payload from before migration
    /// 20260904100000 still decodes.
    public let notes: String?
    /// Both legs, like `notes`, and for the same reason.
    public let title: String?

    public init(
        fromId: UUID, toId: UUID, fromAccountId: UUID, toAccountId: UUID,
        fromAmountE4: Int64, toAmountE4: Int64?, occurredAt: Date, notes: String? = nil, title: String? = nil
    ) {
        self.fromId = fromId
        self.toId = toId
        self.fromAccountId = fromAccountId
        self.toAccountId = toAccountId
        self.fromAmountE4 = fromAmountE4
        self.toAmountE4 = toAmountE4
        self.occurredAt = occurredAt
        self.notes = notes
        self.title = title
    }
}

public struct UpdateTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int
    public let accountId: UUID
    public let categoryId: UUID
    public let amountE4: Int64
    public let currency: String
    public let occurredAt: Date
    public let merchantRaw: String?
    public let notes: String?
    /// See `CreateTransactionPayload.original`. Passing `nil` on an edit
    /// **clears** a stored original, which is how a row wrongly marked
    /// foreign is corrected.
    public let original: ForeignOriginal?
    /// `nil` **clears** a title, the same way `original` and `notes` clear —
    /// an edit states the whole row.
    public let title: String?

    public init(
        id: UUID, expectedVersion: Int, accountId: UUID, categoryId: UUID,
        amountE4: Int64, currency: String, occurredAt: Date, merchantRaw: String?, notes: String? = nil,
        original: ForeignOriginal? = nil, title: String? = nil
    ) {
        self.id = id
        self.expectedVersion = expectedVersion
        self.accountId = accountId
        self.categoryId = categoryId
        self.amountE4 = amountE4
        self.currency = currency
        self.occurredAt = occurredAt
        self.merchantRaw = merchantRaw
        self.notes = notes
        self.original = original
        self.title = title
    }
}

public struct UpdateTransferPayload: Codable, Sendable {
    public let transferGroupId: UUID
    public let fromExpectedVersion: Int
    public let toExpectedVersion: Int
    public let fromAmountE4: Int64
    public let toAmountE4: Int64
    public let occurredAt: Date
    /// See `CreateTransferPayload.notes` — same both-legs rule.
    public let notes: String?
    public let title: String?
    /// Where each leg should now be. Optional so a payload queued by a build
    /// that predates moving a transfer still decodes (synthesized `Codable`
    /// reads a missing optional key as `nil`), and `nil` is exactly what the
    /// RPC reads as "unchanged".
    public let fromAccountId: UUID?
    public let toAccountId: UUID?

    public init(
        transferGroupId: UUID, fromExpectedVersion: Int, toExpectedVersion: Int,
        fromAmountE4: Int64, toAmountE4: Int64, occurredAt: Date, notes: String? = nil, title: String? = nil,
        fromAccountId: UUID? = nil, toAccountId: UUID? = nil
    ) {
        self.transferGroupId = transferGroupId
        self.fromExpectedVersion = fromExpectedVersion
        self.toExpectedVersion = toExpectedVersion
        self.fromAmountE4 = fromAmountE4
        self.toAmountE4 = toAmountE4
        self.occurredAt = occurredAt
        self.notes = notes
        self.title = title
        self.fromAccountId = fromAccountId
        self.toAccountId = toAccountId
    }
}

public struct DeleteTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int

    public init(id: UUID, expectedVersion: Int) {
        self.id = id
        self.expectedVersion = expectedVersion
    }
}

public struct DeleteTransferPayload: Codable, Sendable {
    public let transferGroupId: UUID
    public let fromExpectedVersion: Int
    public let toExpectedVersion: Int

    public init(transferGroupId: UUID, fromExpectedVersion: Int, toExpectedVersion: Int) {
        self.transferGroupId = transferGroupId
        self.fromExpectedVersion = fromExpectedVersion
        self.toExpectedVersion = toExpectedVersion
    }
}

/// Delete is deliberately absent — it needs a live server check (does this
/// account still have transactions?) that a queued write can't answer
/// truthfully offline, so it stays online-only (see AccountsListView).
/// Archive carries no such check (`archive_account` is a plain
/// version-checked flag flip, confirmed against its own migration) — see
/// `ArchiveAccountPayload` below, which does go through the outbox.
public struct CreateAccountPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let kind: PublicSchema.AccountKind
    public let name: String
    public let currency: String
    public let openingBalanceE4: Int64
    public let icon: String
    public let color: String

    public init(
        id: UUID, ownerId: UUID, kind: PublicSchema.AccountKind,
        name: String, currency: String, openingBalanceE4: Int64, icon: String, color: String
    ) {
        self.id = id
        self.ownerId = ownerId
        self.kind = kind
        self.name = name
        self.currency = currency
        self.openingBalanceE4 = openingBalanceE4
        self.icon = icon
        self.color = color
    }
}

/// `kind` stays absent by omission — `update_account` still takes no kind
/// parameter, and kind now has its own dedicated write
/// (`SetAccountKindPayload`) rather than riding along with every rename.
public struct UpdateAccountPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int
    public let name: String
    public let openingBalanceE4: Int64
    public let includeInTotal: Bool
    public let icon: String
    public let color: String

    public init(
        id: UUID, expectedVersion: Int, name: String,
        openingBalanceE4: Int64, includeInTotal: Bool, icon: String, color: String
    ) {
        self.id = id
        self.expectedVersion = expectedVersion
        self.name = name
        self.openingBalanceE4 = openingBalanceE4
        self.includeInTotal = includeInTotal
        self.icon = icon
        self.color = color
    }
}

/// Delete is deliberately absent here too — same reasoning as accounts: the
/// "N transactions will move to Other" warning is only honest with a live
/// count, so category delete stays online-only (see CategoriesView).
public struct CreateCategoryPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let kind: PublicSchema.CategoryKind
    public let name: String
    public let icon: String
    public let color: String

    public init(id: UUID, ownerId: UUID, kind: PublicSchema.CategoryKind, name: String, icon: String, color: String) {
        self.id = id
        self.ownerId = ownerId
        self.kind = kind
        self.name = name
        self.icon = icon
        self.color = color
    }
}

/// No `expectedVersion` — an appearance/name update has nothing to
/// conflict against beyond what `CategoryRepository.update` already is: a
/// plain, no-conflict-tracked update, same simplicity level the endpoint
/// already had before this went through the outbox.
public struct UpdateCategoryPayload: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let icon: String
    public let color: String

    public init(id: UUID, name: String, icon: String, color: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
    }
}

/// `expectedVersion` (L1) closes a real gap: without it, two concurrent
/// balance edits both apply and the first vanishes with nothing logged —
/// now a stale version is rejected and logged to `sync_conflicts` like
/// every other write. This never blocks an idempotent replay of the same
/// `id`, even against a since-advanced version — `set_account_balance`
/// checks idempotency before the version check server-side, specifically
/// so a queued write can still be retried safely.
public struct SetAccountBalancePayload: Codable, Sendable {
    public let id: UUID
    public let accountId: UUID
    public let newBalanceE4: Int64
    public let expectedVersion: Int

    public init(id: UUID, accountId: UUID, newBalanceE4: Int64, expectedVersion: Int) {
        self.id = id
        self.accountId = accountId
        self.newBalanceE4 = newBalanceE4
        self.expectedVersion = expectedVersion
    }
}

/// B: `archive_account` is a plain version-checked flag flip (no live
/// "does this still have transactions" check — that requirement belongs to
/// `delete_account` alone), so unlike delete it has nothing that needs a
/// live server round-trip and goes through the outbox exactly like any
/// other versioned account edit.
public struct ArchiveAccountPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int
    public let archived: Bool

    public init(id: UUID, expectedVersion: Int, archived: Bool) {
        self.id = id
        self.expectedVersion = expectedVersion
        self.archived = archived
    }
}

/// The Account edit sheet's "manage mapped cards" writes. No
/// `expectedVersion` — `card_mappings` has no `version` column, same
/// "last write wins" simplicity `map_card` itself already documented (a
/// single (owner, card) row nobody else can touch has no concurrent-edit
/// hazard worth one).
///
/// Resolved server- and locally by natural key — `(ownerId,
/// oldCardIdentifier)` — never by the mapping's own row id. `id` is a
/// server-generated value no RPC ever lets a client choose, so the local
/// mirror's optimistic write-through has no way to know it ahead of a sync
/// pull; keying these writes by it meant a row created locally before its
/// server counterpart synced down (a real sequence during an offline
/// capture) permanently failed "not found" on retry — the id itself, not
/// the network, was wrong. `id` here is only a synthetic outbox dedupe key
/// (`Outbox.attempt`'s bookkeeping), same role `MapCardPayload.id` already
/// plays, never sent to the server.
public struct RenameCardMappingPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let oldCardIdentifier: String
    public let newCardIdentifier: String

    public init(id: UUID, ownerId: UUID, oldCardIdentifier: String, newCardIdentifier: String) {
        self.id = id
        self.ownerId = ownerId
        self.oldCardIdentifier = oldCardIdentifier
        self.newCardIdentifier = newCardIdentifier
    }
}

/// A soft-delete (`unmap_card` sets `deleted_at`), never an
/// `account_id = null` reset — see `unmap_card`'s own migration comment on
/// why: that would immediately resurrect the mapping as an `ambiguous_card`
/// Needs Review item, the exact nagging this action is meant to dismiss.
/// Resolved by natural key — see `RenameCardMappingPayload`'s own header
/// comment on why this changed from keying by row id.
public struct UnmapCardPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let cardIdentifier: String

    public init(id: UUID, ownerId: UUID, cardIdentifier: String) {
        self.id = id
        self.ownerId = ownerId
        self.cardIdentifier = cardIdentifier
    }
}

/// The Account edit sheet's manual "Add Card" write — the same `map_card`
/// RPC an `ambiguous_card` Needs Review item resolves through, just with the
/// account fixed instead of picked. `id` is a synthetic outbox dedupe key
/// only (card_mappings has no client-chosen row id of its own — it's keyed
/// by the natural (owner, card_identifier) pair), so it never collides with
/// a real row id.
public struct MapCardPayload: Codable, Sendable {
    public let id: UUID
    public let ownerId: UUID
    public let cardIdentifier: String
    public let accountId: UUID

    public init(id: UUID, ownerId: UUID, cardIdentifier: String, accountId: UUID) {
        self.id = id
        self.ownerId = ownerId
        self.cardIdentifier = cardIdentifier
        self.accountId = accountId
    }
}

/// No `expectedVersion` — confirming is a plain status flip guarded the same
/// way every other edit here is (a stale version conflicts, logged to
/// `sync_conflicts`, never silently overwritten).
public struct ConfirmCaptureTransactionPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int

    public init(id: UUID, expectedVersion: Int) {
        self.id = id
        self.expectedVersion = expectedVersion
    }
}
