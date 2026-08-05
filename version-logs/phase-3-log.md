# Phase 3 — Transaction Editing & Optimistic Concurrency

## Delivered

- `sync_conflicts` table (per `app-architecture.md` §3) — now actually populated.
- `revoke update on transactions from authenticated` — closes the RLS gap Phase 2's migration flagged ("RLS can't restrict which columns an UPDATE touches"). All transaction mutation now goes through four `SECURITY DEFINER` RPCs, which own field whitelisting themselves.
- RPCs: `update_transaction`, `update_transfer` (both legs, atomic, each leg's own expected version), `delete_transaction`, `delete_transfer` (soft-delete both legs together — never leaves a 1-leg group, which `check_transfer_integrity` would reject anyway).
- `transactions_with_details` view extended with `version` (appended at the end — `CREATE OR REPLACE VIEW` can't reorder or insert columns mid-list).
- Client: `TransactionRepository.update`/`updateTransfer`/`delete`/`deleteTransfer`, `WriteResult` enum (`.saved`/`.conflict`), moved to `KeepoCore/TransactionWrites.swift` to keep `Repositories.swift` under the file-length lint budget.
- `TransactionFormView` gained a `Mode` (`.create`/`.edit`), a `Date` field (previously occurred_at silently defaulted to `Date()` on every save — editing without a date field would have silently changed a transaction's date on every edit), and conflict-alert handling that reloads the current row.
- `TransactionsListView` rows are now tappable (first drill-in navigation in the app) and route delete through the versioned RPCs.
- Migration: `supabase/migrations/20260805134921_transaction_editing.sql`.

## The one real design bug, found only by testing against a live database

**Raising an exception on version conflict discarded its own audit row.** The first version of the migration inserted into `sync_conflicts` and then `RAISE EXCEPTION`ed. Caught while writing the SQL tests: an exception aborts the *entire* enclosing transaction, and an RPC call from a client is one top-level statement — so the conflict-audit insert was rolled back along with everything else, every time. There's no partial-commit-within-an-aborting-transaction in Postgres without `dblink`/`pg_background` autonomous transactions (not used anywhere in this codebase, not worth introducing for this).

**Fix:** conflicts are reported as data, not exceptions. Every write RPC returns `(conflict boolean, transaction ...)` (or just `conflict boolean` for deletes) instead of throwing. A conflict is a normal, successful call whose `sync_conflicts` insert commits along with everything else — not an error. Real errors (not found, not accessible, wrong leg type for the RPC called) still raise; there's nothing to audit for those.

Side effect worth remembering: `SELECT (some_function(...)).* ` calls a composite-returning function **once per output column** — a classic Postgres trap, hit while writing the SQL tests (a version-1 update call appeared to "immediately" conflict with itself). Use `SELECT * FROM some_function(...)` instead; it invokes the function exactly once.

## Two more bugs, found only by driving the actual Swift client (not by SQL testing)

1. **`supabase gen types` changed its default Swift access level to `internal`** (CLI ≥ ~2.100, vs. the `public` the codebase was built against) — a plain `supabase gen types --local --lang swift` silently made every generated type internal, breaking cross-module access from the `App` target. Fix: `--swift-access-control public` must be passed explicitly now; it's no longer the default.
2. **RPC calls with an omitted `nil` optional parameter don't match the Postgres function signature.** Swift's synthesized `Encodable` uses `encodeIfPresent` for `Optional` properties, so a `nil` field (e.g. `merchantRaw`) is omitted from the JSON body entirely, not sent as `null`. PostgREST's named-parameter RPC matching requires every parameter without a SQL-side `DEFAULT` to be present in the call — so `update_transaction` failed with `PGRST202 - could not find the function` any time `merchant_raw` was nil, i.e. always, since nothing in the UI sets it. Fixed by giving `p_merchant_raw` a `default null` in SQL (matching the pattern `create_transfer` already used for `p_to_amount`/`p_occurred_at`). Any future RPC parameter that a Swift `Optional` can send as `nil` needs the same `default null` treatment on the Postgres side.

## Verification

- 8 SQL-level invariant tests (same style as Phases 1–2): correct-version edit succeeds and bumps version; stale-version edit reports `conflict = true`, leaves exactly one `sync_conflicts` row, and touches no data; edit on someone else's transaction raises; edit on a deleted transaction raises; `update_transaction` on a transfer leg raises with a redirect message; `update_transfer` updates both legs atomically and applies no writes if either version is stale; `delete_transfer` never leaves a 1-leg group; a raw `UPDATE transactions` from `authenticated` now fails at the grant level.
- `xcodebuild -scheme Keepo build` — clean.
- `swift test` (KeepoCore) — 12 tests, all passing (no changes needed; conflict-handling logic lives in the DB, not in a Swift function worth unit-testing in isolation).
- `swiftlint` — 0 violations.
- Simulator, driven end-to-end: create an expense, edit its account/category/amount/date, confirm the accounts-list balance moves by exactly the new amount (not double-counted), delete it, confirm the balance returns to the pre-transaction value. Transfer editing/deletion verified at the SQL level only (tests 5–7) — not re-driven through the simulator UI this pass.

## Notes for the next phase

- Transfer editing/deletion has SQL coverage but no simulator walkthrough yet — worth doing before shipping if transfer editing sees real use.
- `sync_conflicts` rows are written but nothing reads them yet — they'll feed the `needs_review` view once that's built (Phase 7/8 territory).
- The local Supabase CLI needs `NOTIFY pgrst, 'reload schema';` after `db reset` in some sessions — PostgREST's schema cache didn't always pick up new functions automatically during this phase's dev loop. Not a code issue, just a local-dev gotcha worth remembering.
