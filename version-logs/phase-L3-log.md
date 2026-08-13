# Phase L3 — On-device store: GRDB

Part of the local-first rebuild (`keepo-local-first-plan.md`). Client-only, server-side behavior
unchanged — the app is still online-first; this lands the SQLite store L5's pull loop and L6's read
path will build on, plus a full storage-layer port of the existing offline outbox.

## Delivered

- GRDB.swift 7.11.1 added as a SPM dependency on the `Keepo` and `KeepoTests` targets only
  (`project.yml`), same reasoning as `OfflineStore`'s own header comment on why offline-store plumbing
  lives in the app target and not `KeepoCore`.
- `App/LocalStore.swift` — `LocalSchemaV1.migrate()` creates all 16 syncable tables (`accounts`,
  `transactions`, `balance_snapshots`, `categories`, `currencies`, `fx_rates`, `budgets`,
  `fi_settings`, `recurring_rules`, `card_mappings`, `merchant_category_map`, `sync_conflicts`,
  `households`, `household_members`, `household_accounts`, `profiles`) mirroring the server 1:1 —
  `snake_case` columns, `sync_seq`/`deleted_at`/`version` present wherever the server has them, money
  as `INTEGER` (`_e4` bigint, matching L1). Split into six small per-domain helpers purely to stay
  under the project's `function_body_length` lint. `LocalStore.makeQueue()` — memoized single
  `DatabaseQueue` at `Local.sqlite`, same one-process/one-coordinator lock pattern and file-protection
  treatment (`.completeUnlessOpen` on the main file and its `-wal`/`-shm` siblings) as `OfflineStore`.
  **Schema only** — nothing writes into these 16 tables until L5's pull loop lands.
- `Outbox.swift` storage internals fully ported from SwiftData (`ModelContext`) to GRDB
  (`OutboxItemRecord` + `outbox_items` table, both in `LocalStore.swift`). The public API
  (`submit*`/`drainAll`/`queuedKindsAndPayloads`/`pendingCount`/`pendingCreateTransactions`) is
  unchanged — `Outbox.init` now takes a `DatabaseQueue` instead of a `ModelContext`, which is the only
  change every call site (`SessionStore`, `CaptureIntent`, `OutboxTests`) needed.
- `App/OutboxMigration.swift` — one-time, idempotent move of any rows still queued in the pre-L3
  SwiftData `OutboxItem` store into `outbox_items`. Run at `SessionStore` construction and defensively
  again in `CaptureIntent.perform()` (an App Intent launch may not always go through the same init
  path). `OfflineStore`'s `VersionedSchema` still declares the `OutboxItem` SwiftData model purely so
  this migration can open and read the legacy store — nothing else writes to it anymore.
  `PayloadCache`/`CachedPayload` are untouched and stay on SwiftData; L3's scope is the syncable-table
  mirror and the outbox, not the read-through payload cache.
- `KeepoTests/LocalStoreTests.swift` (schema creates all 17 tables; file-protection call doesn't
  throw), `KeepoTests/OutboxMigrationTests.swift` (three queued items migrate exactly once and the
  pass is idempotent; an empty legacy store is a no-op), `KeepoTests/OutboxTests.swift` updated to
  build its in-memory `Outbox` against an in-memory `DatabaseQueue` instead of an in-memory
  `ModelContainer` — all nine pre-existing assertions pass unchanged against the new storage.
- No `ValueObservation` wiring — investigated and rejected as speculative for this phase (see
  Findings #3).

## Findings

1. **`dbQueue.write`/`.read` resolve to the `async` overload, not the `sync throws` one, when called
   from inside an already-`async` function with no disambiguation.** `Outbox.drain(_:)`'s two
   `try? dbQueue.write { ... }` calls (already inside an `async` method) failed to compile ("expression
   is 'async' but is not marked with 'await'") even though the exact same call shape compiled fine in
   `enqueue()` (a non-`async` method, where only the sync overload is a candidate). Fixed by adding
   `await` at both call sites in `drain(_:)`. General lesson: GRDB's dual sync/async `DatabaseWriter`
   API means the *caller's* async-ness, not just the closure's shape, decides which overload resolves
   — always `await` explicitly inside already-`async` code rather than relying on inference.
2. **`xcodegen generate` stripped the committed `DEVELOPMENT_TEAM` signing setting again — twice in
   this phase alone**, the same gotcha `lessons-learned.md` already documents from L2. Regenerating
   after adding the GRDB package dependency, and again after adding two new source files
   (`LocalStore.swift`, `OutboxMigration.swift`), both silently dropped
   `DEVELOPMENT_TEAM = K46X3FA9HH;` from `project.pbxproj` (not tracked in `project.yml`). Caught both
   times via `git diff` before staging; restored via a small Python find/replace rather than hand-
   editing the generated file. **Confirms the lesson generalizes**: run this check after *every*
   `xcodegen generate`, not just ones that add packages.
3. **A real, empirically-confirmed clock-precision bug, found and fixed at the schema level, not
   papered over in the test.** `hasStalePending(threshold: 0)` flaked roughly 1 run in 5 once the
   outbox moved off SwiftData — `Date().timeIntervalSince(oldestPendingAt) > 0` occasionally read
   `false` immediately after `enqueue()`. Root cause, found in two layers:
   - GRDB's default Codable date strategy (`.deferredToDate`) and a first attempt at `.iso8601` were
     both wrong for this specific column — `.iso8601` truncates to whole seconds and can *round a
     just-inserted timestamp into the future* relative to a `Date()` read a moment later. Switched to
     `.timeIntervalSince1970` (full double precision) on `OutboxItemRecord` — reduced but did not
     eliminate the flake.
   - The column itself was declared `.text`, and SQLite's `TEXT` column affinity coerces any inserted
     numeric value through a 15-significant-digit `%.15g` text cast before storing it — enough to
     round a `timeIntervalSince1970` double (16 total digits) forward by a handful of microseconds,
     which is all it takes to flake a `threshold: 0` comparison executing in under a millisecond.
     Fixed at the actual layer the invariant broke: `outbox_items.created_at` is `.double`, not
     `.text` — the only column in the schema that isn't, and it's commented as to why (every other
     table's date columns are genuinely `TEXT`, mirroring the server's PostgREST-produced ISO 8601
     strings; this one is pure local bookkeeping with no server counterpart to match). The remaining
     residual flake (same-instant `Date()` calls, unrelated to storage) was closed with a 1ms
     `Task.sleep` in the test itself — a legitimate test-timing fix once the storage-layer rounding
     bug was actually gone, not a substitute for it.
4. **`ValueObservation` investigated and explicitly not wired up this phase.** The plan's "GRDB's
   `ValueObservation` replaces SwiftData's `@Query`" line turned out to describe a migration that
   doesn't exist in this codebase — a repo-wide grep found zero `@Query` usages. `Outbox`'s
   `@Observable` properties are already refreshed synchronously after every write, and `Outbox` is
   currently the *only* writer to `outbox_items` — there's no second writer yet for a SwiftUI view to
   need to observe independently. That changes in L5, once the pull loop becomes a second writer into
   the syncable-table mirror; wiring `ValueObservation` before that writer exists would be the
   speculative abstraction CLAUDE.md's engineering principles forbid. Flagged here so L5/L6 know to
   revisit it, not silently dropped.

## Verification

- `xcodebuild -scheme Keepo -destination 'generic/platform=iOS Simulator' build` — clean.
- `xcodebuild ... test -only-testing:KeepoTests` — 13/13 (9 pre-existing `Outbox` assertions unchanged
  behavior against new storage, 2 new `LocalStoreTests`, 2 new `OutboxMigrationTests`). Re-ran the
  previously-flaky `hasStalePending` test 10x standalone after the fix — 10/10 passing (was ~1-in-5
  failing before Findings #3's fix).
- `swift test` (KeepoCore) — 72/72, unchanged (this phase touched no KeepoCore code).
- `swiftlint lint --strict` — 0 violations across 105 files (required splitting `LocalSchemaV1.migrate`
  into six per-domain helpers and renaming GRDB's conventional `db`/`t` closure parameter names to
  `database`/`table` to satisfy this project's `identifier_name` and `function_body_length` rules).
- **Not performed this session**: no simulator walkthrough beyond the existing automated test suite —
  nothing in the app's visible surface changed (schema-only for the 16 mirrored tables; the outbox's
  behavior is identical from every call site's perspective, verified by the unchanged
  `OutboxTests` assertions passing against the new storage). No hosted push — this phase is
  entirely client-side, nothing in `supabase/migrations/` changed.
