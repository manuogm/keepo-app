import GRDB

// Split out of LocalStore.swift purely to keep that file under the
// project's file-length lint threshold — same precedent as
// Outbox+Capture.swift.

extension LocalStore {
    /// Found chasing a real bug: a device that already had Keepo installed
    /// before a `LocalSchemaV1` column change (card_identifier, the notes
    /// column, nullable account_id/currency, ...) never picked it up — `v1`
    /// already ran, and GRDB never re-runs a completed migration, so the
    /// on-disk table kept its old columns forever. Every write touching a
    /// new column then failed with "no such column" — silently, since
    /// `Outbox.applyLocally`/`SyncEngine.pull` both swallow errors into
    /// state nothing reads — which looked exactly like a sync bug (a
    /// captured transaction that never shows up) but was actually a stale
    /// local schema. These tables are a pure server mirror, never a source
    /// of truth, so the fix is the same one `SyncEngine`'s own
    /// epoch-mismatch path already uses: drop and recreate them from the
    /// current schema, reset every stored cursor, and let the next pull
    /// fully repopulate — never touches `outbox_items`, so an unsent local
    /// write survives. Exposed (not a closure literal in `makeQueue()`) so
    /// `LocalStoreMigrationTests` can drive it directly against a
    /// hand-built "old schema" database.
    static func rebuildSyncableTables(_ database: Database) throws {
        for table in SyncApply.syncableTables {
            try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try LocalSchemaV1.createSyncableTables(database)
        SyncCursorStore.resetAll()
    }
}

extension LocalStore {
    /// Every migration this store has ever run, in order, split out of
    /// `LocalStore.swift` for the project's file-length lint. They belong
    /// beside `rebuildSyncableTables`, which is what all but the first of
    /// them call.
    static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { database in try LocalSchemaV1.migrate(database) }
        // Recovers a device whose local schema predates a `LocalSchemaV1`
        // column change — see `rebuildSyncableTables`'s own header comment
        // (`LocalStore+SchemaMigration.swift`) for why this is needed.
        migrator.registerMigration("v2_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild, re-run under a new name so a device that already
        // completed v2 still picks up C-07's new partial unique index on
        // transactions(owner_id, source, external_id) — GRDB never re-runs
        // a migration name that already succeeded.
        migrator.registerMigration("v3_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — items 2/3's new unique index on
        // card_mappings(owner_id, card_identifier); also purges any
        // duplicate row already on disk, since the fresh re-pull runs
        // through `SyncApply`'s new natural-key reconciliation.
        migrator.registerMigration("v4_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — the unify-account-kinds migration dropped
        // accounts.subtype, transactions.account_kind, and balance_snapshots
        // entirely server-side; a device that already completed v4 needs
        // this rebuild to drop them locally too, or every pull row omitting
        // those columns hits an INSERT NOT NULL violation.
        migrator.registerMigration("v5_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260903100000 adds accounts.sort_order
        // and card_mappings.source server-side. Unlike the v5 case these are
        // additive, so a stale device would not hard-fail on them; it would
        // silently drop both columns from every pulled row (SyncApply's
        // whitelist is intersected with the local schema), leaving the
        // Accounts list unable to remember its own order. Same rebuild, same
        // self-heal.
        migrator.registerMigration("v6_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260905100000 renames
        // fx_rates.rate_to_eur to units_per_eur server-side. A stale device
        // keeps the old column, so every pulled fx row loses its rate to
        // `SyncApply`'s whitelist-intersected-with-local-schema step and
        // lands with a NOT NULL violation. The rename carries no data change,
        // so a drop-and-repull costs nothing but the pull itself.
        migrator.registerMigration("v7_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260906100000 drops the budgets
        // table server-side. A stale device keeps its local copy forever:
        // harmless for reads (nothing queries it any more) but it is dead
        // rows of the user's financial data sitting on disk after the
        // feature was removed, which is the one thing a mirror must not do.
        migrator.registerMigration("v8_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260907100000 adds tags and
        // transaction_tags server-side. Additive, so a stale device would not
        // hard-fail; it would silently drop both tables from every pull
        // (SyncApply skips a table the local schema does not have), leaving
        // the Tags screen permanently empty with no error anywhere.
        migrator.registerMigration("v9_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260908100000 drops
        // tags.category_id server-side. A stale device keeps the column and
        // every pulled tag row loses nothing, but the column would sit there
        // holding a category link the product no longer has.
        migrator.registerMigration("v10_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260910100000 adds
        // profiles.display_name and profiles.avatar_path server-side.
        // Additive, so nothing hard-fails; a stale device would silently drop
        // both from every pulled profile row (`SyncApply` intersects its
        // whitelist with the local schema), which reads as a user who set a
        // name and a photo on one device and has neither on the other.
        migrator.registerMigration("v11_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260912100000 adds
        // categories.shared_group_id server-side. Additive, so nothing
        // hard-fails; a stale device would silently drop it from every pulled
        // category (`SyncApply` intersects its whitelist with the local
        // schema), leaving a shared category indistinguishable from a private
        // one on that device alone.
        migrator.registerMigration("v12_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260913100000 adds
        // categories.merge_origin server-side. Additive, so nothing
        // hard-fails; a stale device would silently drop it from every pulled
        // category (`SyncApply` intersects its whitelist with the local
        // schema), and the Household report would file every merged category
        // under Extra — the one distinction that column exists to carry.
        migrator.registerMigration("v13_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260920100000 adds
        // categories.pre_merge_name/icon/color server-side. Additive, so
        // nothing hard-fails; a stale device would silently drop all three
        // from every pulled category (`SyncApply` intersects its whitelist
        // with the local schema), and the merge sheet would go on showing two
        // identical tiles for a merged pair — the exact thing those columns
        // were added to fix.
        migrator.registerMigration("v14_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260921100000 adds
        // categories.created_as_twin server-side, `NOT NULL` with a default.
        // Unlike the additive cases above this one would hard-fail: a stale
        // device drops the column from its whitelist intersection, and every
        // pulled category then hits a NOT NULL violation on insert.
        migrator.registerMigration("v15_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260923100000 adds
        // transactions.original_amount_e4/original_currency server-side.
        // Additive, so nothing hard-fails; a stale device would silently
        // drop both from every pulled transaction (`SyncApply` intersects
        // its whitelist with the local schema), and a purchase made abroad
        // would lose the record of what was actually paid — on that device
        // only, while the other phone showed it. A mirror that quietly
        // holds less than the server is the failure mode this whole list
        // exists for.
        migrator.registerMigration("v16_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260927100000 adds
        // recurring_rules.to_account_id server-side AND drops NOT NULL from
        // recurring_rules.category_id. Both halves matter, and the second is
        // the one that hard-fails: a stale device keeps `category_id NOT
        // NULL`, so every pulled TRANSFER rule — which has none — hits a NOT
        // NULL violation on insert and takes the whole pull down with it.
        // The first half is the quieter failure this list is mostly about:
        // the new column would be dropped from the whitelist intersection,
        // leaving a transfer rule that points at no destination.
        migrator.registerMigration("v17_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260928100000 adds
        // profiles.time_zone server-side. Additive, so nothing hard-fails; a
        // stale device would silently drop it from every pulled profile
        // (`SyncApply` intersects its whitelist with the local schema), and
        // the mirror would hold less than the server about which calendar the
        // user's recurring rules are rendered against.
        migrator.registerMigration("v18_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20260930100000 adds
        // recurring_rules.notes and the whole `recurring_rule_tags` table
        // server-side. The table is the half that hard-fails without this:
        // `SyncApply` skips a table the local schema does not have, so the
        // rule's tags would be pulled and silently dropped, and the form
        // would open showing none of them.
        migrator.registerMigration("v19_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20261005100000 adds
        // transactions.title and recurring_rules.title server-side. Additive,
        // so nothing hard-fails; a stale device would silently drop both from
        // every pulled row (`SyncApply` intersects its whitelist with the
        // local schema), and a title typed on one phone would simply never
        // appear on the other — the mirror holding less than the server,
        // which is what every entry in this list exists to prevent.
        migrator.registerMigration("v20_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20261008100000 adds
        // sync_conflicts.attempted_payload. Without it a stale device drops
        // the column (`SyncApply` intersects its whitelist with the local
        // schema), and "Keep mine" has nothing to replay for any conflict
        // it pulls.
        migrator.registerMigration("v21_rebuild_syncable_tables", migrate: rebuildSyncableTables)
        // Same rebuild again — migration 20261009100000 adds
        // household_accounts.history_from. A stale device would drop it
        // (`SyncApply` intersects its whitelist with the local schema), so a
        // partner's phone would never learn where their view of an account
        // begins: no purge of older rows, no date limit on the forms.
        migrator.registerMigration("v22_rebuild_syncable_tables", migrate: rebuildSyncableTables)
    }
}
