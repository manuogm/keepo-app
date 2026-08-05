# Phase 1 — Walking Skeleton

Reconstructed after the fact (this log didn't exist when Phase 1 shipped — see `lessons-learned.md`). Sourced from `app-architecture.md`'s inline history, the commit body of `8d83351`, and the Phase 2 plan file.

## Delivered

- Schema: `currencies` (seeded, ECB/Frankfurter set, ~30 codes + EUR), `profiles`, `accounts`, `balance_snapshots`.
- RLS predicates `can_read_account(uuid)` / `can_write_account(uuid)` — the extension point households (Phase 7) upgrade via one function-body edit.
- `StubAuthProvider` (fixed local dev user, refuses non-local Supabase URLs by precondition).
- Onboarding flow: base currency → first account → opening balance.
- Accounts list screen.
- Migration: `supabase/migrations/20260804184433_init_schema.sql`.

## Bugs found and fixed during Phase 1

1. `can_read_account` recursed infinitely under `SECURITY INVOKER` (`stack depth limit exceeded`) — the policy's inner query re-triggered the same policy. Fixed with `SECURITY DEFINER`, letting the inner lookup bypass RLS instead of re-entering it.
2. Supabase's local cluster grants `TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN` to `anon`/`authenticated` on every table by default (`pg_default_acl`) — `TRUNCATE` bypasses RLS entirely. Closed schema-wide with `ALTER DEFAULT PRIVILEGES ... REVOKE` placed before the first `CREATE TABLE`.
3. `INFOPLIST_KEY_*` auto-synthesis drops custom (non-Apple) keys, so `SupabaseURL`/`SupabaseAnonKey` never reached the built `Info.plist`. Fixed with a partial `App/Info.plist` merge.

## Defects found only later, while planning Phase 2 (fixed there)

- `account_balances`' valuation branch was missing `+ SUM(transfers dated after the snapshot)` — looked correct only because zero transactions existed yet.
- `accounts.version` shipped with the column but no trigger — permanently `1`.
- `handle_new_user()`/`ensure_user_bootstrap()` never seeded the default "Other" categories, though the design doc claimed they did.
- `OnboardingView` used `Decimal(string:)`, which is period-decimal only regardless of locale — a comma-decimal locale silently failed to parse.
- `accounts` was missing `UNIQUE (id, owner_id)` — described in a migration comment but never actually created; caught by `db reset` failing outright.
