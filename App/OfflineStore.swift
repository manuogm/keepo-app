import Foundation
import SwiftData

/// The local cache carries its own schema version and migration path (spec)
/// — a `VersionedSchema` + `SchemaMigrationPlan` from the very first version,
/// even though there is only one stage today, so adding a second model
/// version later is a migration stage, not a from-scratch store redesign.
public enum OfflineSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [CachedPayload.self, OutboxItem.self] }
}

public enum OfflineMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [OfflineSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

/// One row per query key (`accounts_with_balances`, a transactions page,
/// the Home summary, ...) — the *server-computed, already-decoded* rows
/// from the last successful fetch, replayed cold-start and offline with an
/// "as of `fetchedAt`" marker. Zero arithmetic happens against this data;
/// it only ever re-displays numbers Postgres already computed (money rule
/// 3), which is why a full local-first mirror was rejected for this phase.
@Model
public final class CachedPayload {
    @Attribute(.unique) public var key: String
    public var payloadJSON: Data
    public var fetchedAt: Date

    public init(key: String, payloadJSON: Data, fetchedAt: Date) {
        self.key = key
        self.payloadJSON = payloadJSON
        self.fetchedAt = fetchedAt
    }
}

/// One row per queued write, FIFO by `createdAt`. `id` is the same client-
/// generated UUID the write itself uses (a transaction id, a transfer's
/// from-leg id, ...) — draining the same row twice calls the same
/// idempotent write twice, never a duplicate. `payloadJSON` is always the
/// operation's complete parameters — a whole-row payload, never a per-field
/// merge, so there is nothing to reconcile against a row that changed
/// server-side in the meantime beyond what the write's own version check
/// already does.
@Model
public final class OutboxItem {
    @Attribute(.unique) public var id: UUID
    public var kind: String
    public var payloadJSON: Data
    public var expectedVersion: Int?
    public var createdAt: Date
    public var attempts: Int
    public var lastError: String?

    public init(
        id: UUID,
        kind: String,
        payloadJSON: Data,
        expectedVersion: Int? = nil,
        createdAt: Date = Date(),
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.expectedVersion = expectedVersion
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }
}

public enum OfflineStore {
    /// `Offline.store` lives in the app container's own Application Support
    /// directory — no App Group, deliberately: `CaptureIntent` (Phase 12)
    /// is declared in the app target, not an extension, so nothing else
    /// needs to reach this file, and an App Group isn't provisionable on
    /// the free personal team this project builds under until Phase 20.
    public static func makeContainer() throws -> ModelContainer {
        let storeURL = try storeDirectory().appendingPathComponent("Offline.store")
        let configuration = ModelConfiguration(schema: Schema(versionedSchema: OfflineSchemaV1.self), url: storeURL)
        let container = try ModelContainer(
            for: Schema(versionedSchema: OfflineSchemaV1.self),
            migrationPlan: OfflineMigrationPlan.self,
            configurations: configuration
        )
        protectStoreFiles(at: storeURL)
        return container
    }

    private static func storeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
    }

    /// `.completeUnlessOpen`, not `.complete` — the store must stay
    /// writable for a queued write made right up until the device locks,
    /// which `.complete` would refuse mid-write. Applied to the main store
    /// file and its `-wal`/`-shm` siblings: SQLite's WAL mode means
    /// uncommitted data can sit in either for a while, and an unprotected
    /// sibling would leak exactly what the main file's protection exists to
    /// hide. Confirmed empirically (`KeepoTests/OfflineStoreTests.swift`):
    /// on the iOS Simulator, `setAttributes` here returns success but the
    /// value never reads back — the Simulator has no data-protection
    /// subsystem at all, not even as unenforced metadata. Both the
    /// read-back and the real enforcement (ciphertext unreadable while
    /// locked) are device-only, confirmable only in Phase 20's checklist.
    private static func protectStoreFiles(at storeURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path
            )
        }
    }
}
