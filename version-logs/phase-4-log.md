# Phase 4 — FX Conversion

## Delivered

- `fx_source` enum (`ecb`), `fx_rates` table (append-only-in-spirit, upserted — later `fetched_at` wins for the same `(currency, rate_date)`), `upsert_fx_rate()` (the only write path, `SECURITY DEFINER`, `service_role`-only execute), `fx_rate_on()` (carries forward over gaps, EUR implicit rate 1), `fx_convert()` (the one place conversion happens, returns `NULL` not an error/0 when a rate is missing).
- `account_balances_base` — new view, not an extension of `account_balances`: per-viewing-user conversion, joined for by `net_worth()` whenever that lands. `has_missing_rate` is `false` when `balance` itself is null (unsnapshotted valuation account) — a missing-balance state, not a missing-rate state.
- `accounts_with_balances` and `transactions_with_details` both extended (columns appended at the end, per Phase 3's `CREATE OR REPLACE VIEW` finding) with `base_currency`, `base_minor_unit`, `balance_base`/`amount_base`, `has_missing_rate`.
- `supabase/functions/sync-fx-rates` — first Edge Function in the repo. Pulls from `api.frankfurter.dev/v1` (not `.app`), EUR-pivoted, 5-day trailing window, only for currencies actually in use (`accounts.currency ∪ profiles.base_currency`, minus EUR), gated by an `X-Fx-Sync-Secret` header (`verify_jwt = false` in `config.toml`). Calls `upsert_fx_rate` via RPC per `(date, currency)` pair.
- Client: no repository changes needed — `AccountRepository.fetchAllWithBalances`/`TransactionRepository.fetchAll` already call bare `.select()`, so the new columns arrived free with regenerated types. New `App/CurrencyConversionLabel.swift` (the component `app-architecture.md` §2 already named), wired into `AccountsListView`/`TransactionsListView` row trailing stacks.
- Migration: `supabase/migrations/20260805152725_fx_conversion.sql`.

## Scope deliberately deferred (not built this phase)

- `pg_cron`/`pg_net` scheduling of `sync-fx-rates` — no automation/ops infrastructure (`pg_cron`, `ops_events`, health checks) exists anywhere in this codebase yet; wiring it now would mix "build FX conversion" with "build the ops platform."
- `vault.create_secret` provisioning of `FX_SYNC_SECRET` on the hosted project — `supabase secrets set FX_SYNC_SECRET=...` is sufficient for now, same mechanism other secrets would use.
- The 400-day-backfill-on-first-currency-use trigger.
- Subtotal/total rows on Accounts, Home dashboard, net worth, households — none of these screens/RPCs exist yet.

## Verification

- 15 SQL invariant checks (ad-hoc psql session, same style as Phases 1–3): `fx_rate_on` carry-forward over a gap, EUR's structural rate of 1 with zero rows, `fx_convert` returning `NULL` (not erroring) on a missing rate, a round-trip conversion within rounding, `upsert_fx_rate`'s "later `fetched_at` wins" rule in both directions (later call wins regardless of order; an earlier `fetched_at` than what's stored is a no-op, not just "last call wins"), `account_balances_base.has_missing_rate` correctly distinguishing "rate missing" from "balance missing," grant-level checks (`authenticated` can `select` on `fx_rates` but not write, and can't execute `upsert_fx_rate`), and that a not-yet-onboarded profile's null `base_currency` flows through the new joins as null rather than filtering the row out.
- Edge Function: served locally, confirmed 401 on missing/wrong secret, 200 with the correct one; a real call against `api.frankfurter.dev` populated `fx_rates` for the currencies in use; re-running was idempotent (no duplicate keys, `fetched_at` advanced).
- `xcodebuild -scheme Keepo build` — clean. `swiftlint` — 0 violations. `swift test` (KeepoCore) — 12 tests, all passing (no new tests — no new pure-Swift logic was introduced; all conversion math is SQL, per money rule 3).
- Simulator, driven end-to-end: onboarded with base currency EUR; seeded a second (USD) account directly via SQL (no add-account UI exists beyond onboarding — out of scope for this phase); confirmed the EUR account shows no secondary line (same currency, correctly suppressed) and the USD account shows `—` before any rate exists; seeded a USD→EUR rate via `upsert_fx_rate`, reloaded, confirmed the converted secondary line appeared correctly on both Accounts (`$500.00` → `€543.48`) and, after adding a USD expense, Transactions (`-$50.30` → `-€54.67`); deleted the seeded rate and confirmed both screens fell back to `—`, not blank or `0`.

## Notes for the next phase

- `fx_convert` has no same-currency short-circuit (implements the doc's formula literally) — converting a currency to itself still needs an `fx_rates` row for that date. Self-heals in practice since `sync-fx-rates` fetches every currency in use, but worth knowing if a "brand new currency shows `—` for a moment" report ever comes in.
- No add-account UI exists beyond onboarding (confirmed again this phase) — every account after the first requires direct SQL. Not this phase's problem to fix, but will block realistic multi-account testing for whatever phase does try to add it.
- SwiftUI `.task {}` only fires once per view identity — switching `TabView` tabs does **not** re-trigger it if the view instance persists across the switch. Relaunching the app was the only reliable way to force a reload during this phase's manual testing; a future phase adding pull-to-refresh or a proper reactive data layer should keep this in mind.
- The iOS Simulator MCP tool's `tap`/`swipe` coordinates are in **device points**, not screenshot pixels — this session's screenshots render at ~2.284x scale (918px-wide image for a 402pt-wide device). Passing raw pixel coordinates from a screenshot silently produces wrong (usually near-miss or off-screen) taps; always divide by the scale factor first.
