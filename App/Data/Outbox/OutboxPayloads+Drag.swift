import Foundation
import KeepoCore

// The two writes one drag on the Accounts list can produce. Split out of
// OutboxPayloads.swift purely to keep that file under the project's
// file-length lint threshold.

/// The Accounts list's drag-to-reorder write: the full ordered id list for
/// ONE kind group, not a per-row delta.
///
/// No `expectedVersion`, deliberately, and the RPC leaves `version`
/// untouched — ordering is not a value two clients can meaningfully
/// disagree about (last arrangement wins, same reasoning as
/// `RenameCardMappingPayload`), and a drag that bumped versions would turn
/// every subsequent genuine edit into a phantom conflict.
///
/// `id` is the group's own stable identity rather than a fresh UUID per
/// drag: two reorders of the same group queued offline SHOULD collapse into
/// one queued item, since only the final arrangement needs to reach the
/// server. See `Outbox.enqueue`'s collapse-by-row-id rule.
public struct ReorderAccountsPayload: Codable, Sendable {
    public let id: UUID
    public let kind: PublicSchema.AccountKind
    public let accountIds: [UUID]

    public init(id: UUID, kind: PublicSchema.AccountKind, accountIds: [UUID]) {
        self.id = id
        self.kind = kind
        self.accountIds = accountIds
    }

    public init(kind: PublicSchema.AccountKind, accountIds: [UUID]) {
        self.init(id: Self.groupId(for: kind), kind: kind, accountIds: accountIds)
    }

    /// One fixed id per group, so a second drag of the same group replaces
    /// the first queued item instead of stacking behind it. A constant is
    /// safe here because the local store (and therefore the outbox) is
    /// wiped whenever the signed-in identity changes — see
    /// `SessionStore.ensureLocalDataBelongsTo`.
    static func groupId(for kind: PublicSchema.AccountKind) -> UUID {
        switch kind {
        case .regular: return UUID(uuidString: "0EEE0000-0000-4000-8000-000000000001") ?? UUID()
        case .investment: return UUID(uuidString: "0EEE0000-0000-4000-8000-000000000002") ?? UUID()
        }
    }
}

/// Dragging an account from Everyday into Investments, or back. Unlike
/// reordering this IS version-checked: `kind` is a real fact about the
/// account that two clients can disagree about, so the losing write has to
/// land in `sync_conflicts` like every other versioned edit.
public struct SetAccountKindPayload: Codable, Sendable {
    public let id: UUID
    public let expectedVersion: Int
    public let kind: PublicSchema.AccountKind

    public init(id: UUID, expectedVersion: Int, kind: PublicSchema.AccountKind) {
        self.id = id
        self.expectedVersion = expectedVersion
        self.kind = kind
    }
}
