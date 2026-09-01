import Foundation
import GRDB

/// The GRDB row backing `outbox_items` — the storage `Outbox` (App/Outbox.swift)
/// reads and writes. `id` is the queued write's own client-generated UUID
/// (see `Outbox`'s own doc comment on why), stored as `TEXT`, matching every
/// other id column across this store.
struct OutboxItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox_items"
    // `created_at` is purely local bookkeeping — FIFO ordering, and the
    // staleness check behind the pending-sync banner. It is never compared
    // against a server-issued timestamp, so unlike every synced table's date
    // columns it carries no format contract with Postgres.
    //
    // It is stored as GRDB's default: the TEXT `"yyyy-MM-dd HH:mm:ss.SSS"`,
    // in UTC. That is correct for both jobs this column has, and neither is
    // obvious enough to leave unsaid:
    //
    //  - **Ordering.** The format is fixed-width, zero-padded and UTC, so a
    //    lexicographic `ORDER BY` over it *is* chronological. `drainAll`'s
    //    FIFO replay rests on that: a dependent write (a confirm, an update,
    //    a delete) must never replay before the create it needs.
    //  - **Round-trip.** Encoding and decoding both take the same default,
    //    so a `Date` written here comes back equal to the millisecond.
    //
    // This type used to declare `databaseDateEncodingStrategy` /
    // `databaseDateDecodingStrategy` as static *properties* asking for
    // `.timeIntervalSince1970`. GRDB 7 takes them as static *functions*
    // (`databaseDateEncodingStrategy(for:)`), so those declarations satisfied
    // no protocol requirement and never did anything — and this project has
    // only ever used GRDB 7, so the column has always held TEXT, never a
    // mix. They are deleted rather than corrected, on purpose:
    //
    // Switching to the function form changes the storage type, which needs a
    // migration of the rows already queued on devices, and a half-applied one
    // leaves REAL and TEXT in the same column. SQLite sorts REAL before TEXT,
    // so that would silently invert the drain order on the one table holding
    // unsent financial writes — exactly the failure `Outbox.enqueue` exists
    // to prevent. All it would buy is sub-millisecond precision, which
    // nothing needs (one test sleeps 1ms around the quantization and says so).
    // Revisit only if something genuinely requires finer ordering.
    //
    // Read `createdAt` through this record, never as a raw column value: an
    // aggregate over `created_at` read as a `Double` is what crashed the app
    // on launch once already (see `Outbox+Retry.refreshCounts`).

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
