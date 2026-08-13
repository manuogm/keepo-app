# Phase L5 — Sync engine on device

Part of the local-first rebuild (`keepo-local-first-plan.md`). Client-only except for one server-side
precision fix found before any client code shipped against it — `Outbox` (the push side) is unchanged;
this phase is the pull side. Nothing reads from the local money layer populated here yet — that's L6's
read-path cutover.

## Delivered

- **`supabase/migrations/20260817100000_pull_changes_numeric_precision.sql`** — see Findings #1.
  `pull_changes`'s signature is unchanged; `create or replace` matches the project's own
  never-edit-a-pushed-migration convention.
- **`Packages/KeepoCore/Sources/KeepoCore/SyncRepository.swift`** — thin RPC wrapper matching every
  sibling repository's own shape; decodes `payload` as `AnyJSON` rather than 16 per-table `Codable`
  structs (see Findings #2 for why).
- **`App/SyncCursorStore.swift`** — `(cursor, global_cursor, epoch)` in `UserDefaults`, namespaced by
  user id (a cursor is meaningless without knowing whose sync-seq domain it's denominated in).
  `epoch(for:)` distinguishes "never pulled" (`nil`) from "epoch 0" (a real value) — only a genuine
  before/after comparison should trigger the epoch-mismatch path.
- **`App/SyncApply.swift`** — one generic upsert, driven by the JSON row's own keys against a
  per-table column whitelist matching `LocalSchemaV1` exactly (never a blind pass-through of arbitrary
  JSON keys into SQL identifiers, even though the payload is fully self-controlled). A tombstone needs
  no special DELETE path — a soft-deleted server row still has a payload (`deleted_at` non-null), and
  every local money query already filters `deleted_at IS NULL` itself, so upserting it normally is
  already correct.
- **`App/SyncEngine.swift`** — `pull()`: one RPC round-trip (no pagination needed; `jsonb_agg` returns
  the full backlog in one call), applied inside one GRDB transaction. Epoch mismatch → wipe every
  server-derived table (never `outbox_items`) → reset cursors → re-pull from 0. Guarded against two
  overlapping `pull()` calls racing (the trigger sites can fire close together — sign-in immediately
  followed by the scene becoming active).
- **Wired into `SessionStore`** (rebuilt on every sign-in path, since a user id is required and isn't
  known at `init()`), **`RootView`** (scenePhase-active, alongside the existing
  `Outbox.drainAll()`), and **`NetworkMonitor`** (connectivity regained).
- **`KeepoTests/SyncEngineTests.swift`** — 5 tests against a stubbed `SyncPulling`: upserts land
  correctly, a tombstone upserts rather than deletes, the cursor advances and is used on the next
  call, an epoch mismatch wipes+resets+re-pulls (asserting the stale first response's data never
  lands, only the re-pull's does), and two overlapping `pull()` calls don't race.

## Findings

1. **A real, empirically-confirmed precision bug in `pull_changes`, found and fixed before any client
   ingestion code was written against it.** Postgres's `to_jsonb(row)` renders a `numeric` column as a
   JSON number, not a string. `fx_rates.rate_to_eur` and `fi_settings.withdrawal_rate`/
   `real_return_rate` are the only three `numeric` columns anywhere in the syncable set (L1's own
   migration converted every money amount to `bigint`, deliberately leaving these three as rates, not
   amounts). A naive client decoding one of these as a JSON number into a Swift floating-point type
   before re-encoding it as the local store's `TEXT` decimal string would silently reintroduce the
   exact binary-float imprecision L1 eliminated and L4's referee spent an entire phase verifying was
   gone — `"0.9000"` is not guaranteed to round-trip through a `Double` and back out as `"0.9000"` or
   even an equivalent decimal. Fixed at the source, in SQL: override just those three keys in
   `pull_changes`'s payload construction with an explicit `::text` cast merged onto the row's own
   `to_jsonb` output (`to_jsonb(fr) || jsonb_build_object('rate_to_eur', fr.rate_to_eur::text)`),
   leaving every other column (already `bigint`/`text`/`uuid`/`timestamptz`, all of which round-trip
   through JSON exactly) untouched. Two new pgTAP assertions
   (`supabase/tests/23_sync_primitives.sql`) pin this: `jsonb_typeof(row -> 'rate_to_eur') = 'string'`,
   and the withdrawal-rate value equals the exact decimal string, not a re-encoded number.
2. **Decoding a fully dynamic, per-table JSON payload into 16 hand-written `Codable` structs would
   have been a second, parallel copy of the schema `LocalSchemaV1` already defines.** Chose `AnyJSON`
   (already vendored by `supabase-swift`, already used nowhere else in this codebase before this
   phase) plus one generic upsert reading column names directly off each JSON row's own keys. The only
   thing genuinely table-specific left is each table's primary key and its whitelist of allowed
   columns — both small, static, one-time-written tables, not per-table functions. Column names come
   from the payload (server-controlled, not attacker-controlled) but are still checked against a fixed
   whitelist before ever reaching raw SQL string interpolation, rather than trusted blindly — cheap
   insurance against a future schema-drift bug reaching SQL as an unexpected identifier.
3. **The plan's own claim that "Phase 19 already uses Realtime" was false, and grepping for the actual
   mechanism before assuming there was something to reuse caught it before any code was written
   against a nonexistent pattern.** A repo-wide search for `RealtimeChannel`/`.channel(`/
   `postgresChange` outside the vendored SDK returned zero hits. Phase 19's household-events
   notification seam is plain HTTP polling
   (`HouseholdViewLoader.swift`/`HouseholdRepository.fetchEvents`, re-fetched each time that screen
   loads) — its own doc comment even says so ("the client polls this rather than waiting on a push").
   Building this app's first-ever Realtime subscription under an already-large phase's scope would
   have been new, untested feature-surface risk for an optimization (instant cross-device staleness)
   the three lifecycle triggers (app active, network regained, every sign-in) don't actually need for
   correctness — only for latency. Deferred explicitly, with the investigation documented in the plan
   file, rather than silently skipped or blindly built on a false premise.
4. **`UserDefaults` namespaced by user id, not a GRDB table, is the right home for cursor state** —
   consistent with `Outbox`'s own precedent (`created_at` as pure local bookkeeping, never synced).
   Considered a dedicated local-only GRDB table first, but a cursor has no relational shape, no query
   pattern beyond "read the three values for this user," and adding a 17th table purely for this would
   have been exactly the kind of premature structure CLAUDE.md's engineering principles warn against.

## Verification

- `xcodebuild -scheme Keepo -destination 'generic/platform=iOS Simulator' build` — clean.
- `xcodebuild ... test -only-testing:KeepoTests` — 27/27 (5 new `SyncEngineTests`, 22 pre-existing from
  L3/L4 unchanged).
- `swift test` (KeepoCore) — 74/74, unchanged (this phase's one KeepoCore addition, `SyncRepository.swift`,
  has no pure-logic surface to unit test — it's a thin RPC wrapper, exercised indirectly via
  `SyncEngineTests`' stubbed protocol seam).
- `swiftlint lint --strict` — 0 violations across 116 files.
- `supabase test db --local` — full suite green, including the two new numeric-precision assertions.
- `supabase db push` — pushed to hosted.
- `supabase gen types swift --local --lang swift --swift-access-control public` — regenerated; no
  functional diff (the migration only changed `pull_changes`'s body, not its signature).
- **Not performed this session**: no simulator walkthrough — nothing in the app's visible surface
  changed (the sync engine populates a store nothing reads from until L6; `NetworkMonitor`/`RootView`
  wiring is new code paths with no new UI). No two-device test — that's L7's job, once L6's read path
  actually depends on synced data being correct end to end.
