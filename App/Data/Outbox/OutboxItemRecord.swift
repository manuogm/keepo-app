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
    // so unlike every synced table's `TEXT` date columns, this one was meant
    // to be encoded as a `timeIntervalSince1970` number: full sub-second
    // precision, no ISO 8601 whole-second truncation that could round a
    // just-inserted row's timestamp into the future relative to `Date()`
    // read a moment later (confirmed empirically — `.iso8601`'s truncation
    // made `hasStalePending(threshold: 0)` flaky immediately after `enqueue`).
    //
    // **These two declarations are inert, and the column holds TEXT.** GRDB 7
    // takes the strategy as a static *function* — `databaseDateEncodingStrategy
    // (for column: String)` — not the static property GRDB 5 took. These
    // properties therefore satisfy no protocol requirement; they are two
    // unused constants, and GRDB falls back to its default, which writes a
    // `"yyyy-MM-dd HH:mm:ss.SSS"` string. `LocalSchemaV1`'s `.double` column
    // affinity can't coerce that to a number, so it is stored as TEXT.
    //
    // Nothing is *wrong* today: encoding and decoding both take the same
    // default, so the round trip is symmetric and the sub-second precision
    // the flake needed is present in the string. It only bit when
    // `Outbox+Retry.refreshCounts()` read the raw column with an aggregate
    // instead of decoding a record — that crashed on launch, which is how
    // this was found. That reader no longer cares about the storage type.
    //
    // Fixing it properly means switching both to the function form AND
    // migrating the rows already on disk: `ORDER BY created_at` and
    // `MIN(created_at)` would otherwise sort every new REAL row before every
    // existing TEXT one (SQLite orders REAL before TEXT), silently
    // reordering the FIFO drain. That is a schema change with a migration,
    // deliberately not slipped into a performance pass.
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
