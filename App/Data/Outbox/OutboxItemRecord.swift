import Foundation
import GRDB

/// The GRDB row backing `outbox_items` — the storage `Outbox` (App/Outbox.swift)
/// reads and writes. `id` is the queued write's own client-generated UUID
/// (see `Outbox`'s own doc comment on why), stored as `TEXT`, matching every
/// other id column across this store.
struct OutboxItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox_items"
    // `created_at` here is purely local bookkeeping (FIFO ordering,
    // staleness checks) — never compared against a server-issued timestamp —
    // so unlike every synced table's `TEXT` date columns, this one is
    // encoded as a `timeIntervalSince1970` numeric string: full sub-second
    // precision, no ISO 8601 whole-second truncation that could round a
    // just-inserted row's timestamp into the future relative to `Date()`
    // read a moment later (confirmed empirically — `.iso8601`'s truncation
    // made `hasStalePending(threshold: 0)` flaky immediately after `enqueue`).
    static let databaseDateEncodingStrategy: DatabaseDateEncodingStrategy = .timeIntervalSince1970
    static let databaseDateDecodingStrategy: DatabaseDateDecodingStrategy = .timeIntervalSince1970

    var id: UUID
    var kind: String
    var payloadJSON: Data
    var expectedVersion: Int?
    var createdAt: Date
    var attempts: Int
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case payloadJSON = "payload_json"
        case expectedVersion = "expected_version"
        case createdAt = "created_at"
        case attempts
        case lastError = "last_error"
    }
}
