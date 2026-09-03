import GRDB

// Split out of LocalStore.swift purely to keep that file under the
// project's file-length lint — same precedent as
// LocalStore+SchemaMigration.swift. No ordering dependency on the other
// per-domain table helpers; `createSyncableTables` calls them in sequence.
extension LocalSchemaV1 {
    /// Tags and their join to transactions. Mirrors the server 1:1, including
    /// `transaction_tags.owner_id` — denormalized there so the row lands in
    /// the same sync domain as its transaction, and carried here so a local
    /// read can scope by owner without a join.
    static func createTagTables(_ database: Database) throws {
        try database.create(table: "tags") { table in
            table.column("id", .text).primaryKey().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("name", .text).notNull()
            table.column("version", .integer).notNull()
            table.column("deleted_at", .text)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("sync_seq", .integer).notNull()
        }

        try database.create(table: "transaction_tags") { table in
            table.column("transaction_id", .text).notNull().collate(.nocase)
            table.column("tag_id", .text).notNull().collate(.nocase)
            table.column("owner_id", .text).notNull().collate(.nocase)
            table.column("created_at", .text).notNull()
            table.column("updated_at", .text).notNull()
            table.column("deleted_at", .text)
            table.column("sync_seq", .integer).notNull()
            table.primaryKey(["transaction_id", "tag_id"])
        }
        try database.create(
            index: "idx_transaction_tags_tag", on: "transaction_tags", columns: ["tag_id"]
        )
    }
}
