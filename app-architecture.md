# Keepo App — Architecture

Stack target: **Native iOS (SwiftUI) + Supabase (Postgres/Auth/Edge Functions)**

This document is the schema and pipeline design for all of `keepo-v1-feature-spec.md`, written before any migration exists. Migrations are effectively append-only once pushed, so cross-feature mistakes belong here, while they're still free.

---

## 1. Architectural Map

```
Shortcuts (Wallet trigger) ──► App Intent ──► pending transaction (local) ──► notification ──► review
                                                       │
                                                       ▼
                          iOS client (SwiftUI) ──outbox──► Supabase Postgres (RLS per user/household)
                                                       ▲                │
frankfurter.dev (ECB) ──► sync-fx-rates Edge Function ─┘                │
                                                                        ▼
                                                        pg_cron / pg_net (FX sync, recurring materialization,
                                                                          health checks)
```

Every write reaches Postgres through PostgREST/RPC, never a direct table write from a screen that hasn't gone through the shared outbox path (§4). Every read of a converted or aggregated figure goes through a shared SQL function or view (§3), never client-side arithmetic.

**Feature → layer map**, so a spec section always has a home below:

| Spec section | Lives in |
|---|---|
| Platform & Auth | `AuthProvider` protocol (§2), Keychain, `profiles` |
| Onboarding | Onboarding flow (§2), `accounts`, `profiles.base_currency` |
| Data & Offline | Local store + outbox (§4), `version` columns, soft deletes |
| Accounts & Multi-Currency | `accounts`, `balance_snapshots`, `currencies` |
| FX Rate History | `fx_rates`, `fx_rate_on()`, `sync-fx-rates` Edge Function |
| Transaction Entry & Automation | `transactions`, `recurring_rules`, `card_mappings`, capture pipeline (§4) |
| Household & Sharing | `households`, `household_members`, `household_accounts`, `household_invites` |
| Sync Ritual | `reconciliations`, adjustment transactions, valuation snapshots |
| Needs Review | `needs_review` view (§3) |
| Dashboard & Insights | `net_worth()`, `account_balances`, `net_worth_daily`, `budgets`, FI RPCs |
| Operations & Monitoring | `ops_events`, health-check functions, alerting Edge Function |

---

## 2. Frontend — Screens & Shared Components

### Screens (SwiftUI, native navigation — no routes/URLs)

| Screen | Notes |
|---|---|
| Onboarding | Base currency → first account → opening balance → optional Wallet automation walkthrough |
| Home | Net worth trajectory hero metric, Total / Me / Household picker, staleness banner |
| Accounts | List, add/edit, archive. "Everyday" (`ledger`) and "Investments" (`valuation`) sections |
| Transaction entry | One view, three kinds via segmented control — used for capture review, manual add, and edit |
| Transactions | List, filters, per-account or global |
| Categories | Expense/income sections; the two default "Other" rows have no delete affordance |
| Insights | Category breakdowns, savings rate, budget tracking, FI metrics |
| Sync Ritual | Per-account freshness, enter-balance flow, unlogged adjustment |
| Needs Review | Single inbox, one row type per §3's `needs_review` view |
| Household | Members, invite, leave (with the fork confirmation) |
| Import | CSV upload → match-and-review |
| Settings | Base currency, appearance, security (export, delete), household |

**Transaction entry** mirrors the retired web spec's design intent even though the platform changed: one `TransactionFormView`, three kinds (expense/income/transfer), used for both create and edit. The kind is locked once a transaction exists — changing kind is delete-and-recreate, never an in-place mutation, because a transfer's two-leg shape and a ledger entry's single-leg shape aren't interchangeable in place.

### Shared components (one place each, per CLAUDE.md's Engineering Principles)

| Component | Location | Used by |
|---|---|---|
| `MoneyFormatter`, `Decimal(supabaseNumeric:)` | `KeepoCore` (exists) | every screen showing an amount |
| `CurrencyConversionLabel` | `KeepoCore` / SwiftUI view | Home, Insights, Sync Ritual banners — renders `—` when `has_missing_rate` |
| Date bucketing (weekly/monthly by span) | `KeepoCore` | Home trajectory chart, Insights charts |
| `TransactionFormView` | App | manual add, capture review, edit |
| `AccountRowView`, `BalanceHeaderView` | App | Home, Accounts, Sync Ritual |
| `StalenessBadge` | App | Sync Ritual row, Home banner |
| `NeedsReviewRow` | App | Needs Review inbox — one renderer switching on item `kind` |
| `AuthProvider` protocol | App | login, session refresh, step-up re-auth |

`AuthProvider` is the seam named in the build plan: `StubAuthProvider` (fixed dev user id, locally-minted JWT) now, `AppleAuthProvider` (real SIWA) once the paid Apple Developer account exists. Nothing else in the app depends on which is active.

---

## 3. Backend — Schema, Indexes, Auth

### Enums (money rule 4 — enums, not `text` + `CHECK`)

`account_kind` (ledger, valuation) · `account_subtype` (checking, cash, credit_card, loan, investment) · `category_kind` (expense, income) · `transaction_source` (manual, capture, recurring, adjustment, csv_import) · `transaction_status` (pending, confirmed) · `fx_source` (ecb) · `household_invite_status` (pending, accepted, revoked, expired) · `import_candidate_status` (pending, accepted, rejected) · `recurring_frequency` (weekly, monthly, yearly)

`transaction_kind` (expense, income, transfer) is **not** an input enum, and **not a stored `GENERATED ALWAYS` column either** — that was the original plan, revised once building it: generation expressions require an `IMMUTABLE` cast, and `enum_in` is only `STABLE` (confirmed via `pg_proc` before writing the migration). Instead `kind` is derived in `transactions_with_details` (§ below) from `transfer_group_id IS NOT NULL` and the sign of `amount` — same can-never-disagree guarantee, no stored denormalization, no fragile generation expression.

### Tables

- **`currencies`** — reference table, the ECB/Frankfurter set (~30 + EUR). `code` (PK), `minor_unit`. The currency picker (client) can only offer rows from this table — an unpriceable account can never be created.
- **`profiles`** — `id` (= `auth.uid()`), `base_currency` (FK `currencies`), `onboarded_at`.
- **`accounts`** — `id` (client-generated UUID), `owner_id`, `created_by`, `kind` (`account_kind`), `subtype` (`account_subtype`), `name`, `currency` (FK `currencies`), `opening_balance`, `opening_balance_at`, `include_in_total`, `counts_toward_fi`, `archived_at`, `version`, `deleted_at`, timestamps. `UNIQUE (id, currency)` — the anchor for a composite FK below.
- **`balance_snapshots`** — `account_id`, `as_of`, `value`, `created_by`, `created_at`. Only meaningful for `valuation` accounts. **Revised from the original plan**: a transfer into one does *not* auto-write a snapshot at `prior + amount` — combined with `account_balances`' "snapshot + transfers after it" formula, that would double-count the very transfer that triggered it. The account creation flow writes the *first* snapshot atomically with the account (Phase 1's `AccountRepository.create`), which is enough to keep it off `—`; every snapshot after that is a deliberate Sync Ritual reconciliation.
- **`categories`** — `id`, `owner_id`, `kind` (`category_kind`), `name`, `is_default`, `deleted_at`. Exactly one `is_default` row per `(owner_id, kind)`. `UNIQUE (id, kind)` for the composite FK below.
- **`merchant_category_map`** — `owner_id`, `merchant_pattern`, `category_id`, `updated_at`. PK `(owner_id, merchant_pattern)`. RLS-scoped to `owner_id` alone, **never** joined into any household-visible view (spec: merchant learning is per-user, not per-household).
- **`transactions`** — `id` (client-generated UUID), `owner_id`, `created_by`, `account_id`, `account_kind` (mirrors the account's `kind`, set by trigger, never by the client — enables the valuation-accounts-take-transfers-only FK below), `category_id` (null for transfers), `category_kind` (mirrors `category_id`'s kind, same trigger — see composite FKs), `amount` (`numeric(20,4)`, signed), `currency`, `occurred_at`, `merchant_raw`, `merchant_normalized`, `transfer_group_id` (null unless a transfer leg), `source` (`transaction_source`), `status` (`transaction_status`, default `confirmed`; `capture`-sourced rows start `pending`), `external_id` (nullable, idempotency — see §4), `version`, `deleted_at`, timestamps. Four CHECK constraints do the rest of the enforcement declaratively: `amount <> 0`; exactly one of `transfer_group_id`/`category_id` is set; sign agrees with `category_kind` (expense negative, income positive — this is what lets expense/income be a **plain insert**, no RPC, with a wrong sign structurally impossible); `account_kind = 'ledger' OR transfer_group_id IS NOT NULL` (money rule 1's valuation-accounts-take-transfers-only, enforced by the schema, not application code).
- **`recurring_rules`** — `id`, `owner_id`, `account_id`, `category_id`, `amount`, `currency`, `frequency` (`recurring_frequency`), `next_due_at`, `last_materialized_at`, `active`.
- **`fx_rates`** — `currency` (FK `currencies`), `rate_date`, `rate_to_eur`, `source` (`fx_source`), `fetched_at`. PK `(currency, rate_date)`. **Upserted, not blind-inserted** — a later `fetched_at` for the same `(currency, rate_date)` wins, which is how an ECB revision to a recent value gets picked up. This is why `fx_rates` is described as "append-only" in the money rules despite the upsert: no row is ever destructively rewritten by application code outside this one conflict-resolution rule, and old converted figures stay reproducible because the key never silently vanishes.
- **`reconciliations`** — `id`, `account_id`, `as_of`, `entered_balance`, `computed_balance`, `adjustment_txn_id` (nullable, ledger accounts), `snapshot_id` (nullable, valuation accounts), `created_by`, `created_at`. What renders "verified X ago."
- **`households`** — `id`, `created_at`.
- **`household_members`** — `household_id`, `user_id`, `joined_at`, `deleted_at` (L2). PK `(household_id, user_id)`. Trigger caps membership at 2, counting only `deleted_at is null` rows. A departure (`leave_household`/`erase_own_account`) soft-deletes rather than hard-deletes, so a rejoin reactivates the same row (`accept_invite`'s `ON CONFLICT ... DO UPDATE`) instead of colliding on the PK, and the remaining member's next pull still sees the departure as a tombstone rather than a row that silently vanished.
- **`household_accounts`** — `household_id`, `account_id`, `shared_at`, `deleted_at` (L2). PK `(household_id, account_id)`. Same soft-delete reasoning as `household_members` — `unshare_account` sets `deleted_at`, never a hard `DELETE`.
- **`household_invites`** — `id`, `household_id`, `invited_by`, `token_hash`, `status` (`household_invite_status`), `expires_at`, `created_at`. Single-use, expiring, revocable per the parked security design.
- **`sync_conflicts`** — `id`, `table_name`, `row_id`, `owner_id`, `client_version`, `server_version`, `created_at`, `resolved_at`. Populated when a push's `version` doesn't match — feeds Needs Review.
- **`card_mappings`** — `id` (uuid, PK — every other Needs Review item source has one to hand back as `item_id`; amended from this doc's original `(owner_id, card_identifier)` composite PK once Phase 12 actually wired it into Needs Review), `owner_id`, `card_identifier` (raw Shortcuts card string), `account_id` (nullable — null means unmapped, routes to Needs Review), `unique (owner_id, card_identifier)`.
- **`csv_import_batches`** / **`csv_import_candidates`** — batch: `id`, `owner_id`, `account_id`, `filename`, `created_at`. candidate: `batch_id`, `raw_row` (jsonb), `matched_transaction_id` (nullable), `status` (`import_candidate_status`).
- **`budgets`** — `id`, `owner_id`, `category_id` (nullable = overall), `period_month` (normalized to the first of the month by trigger), `amount` + `currency` (typed, **not** `amount_base` — H13, amended in Phase 16: a stored converted amount violates money rule 6 and can't be correct for two household members with different base currencies at once; converted on read via `fx_convert`, same as every other money value here), `version`, `created_at`, `updated_at`. Two partial unique indexes (`(owner_id, category_id, period_month) where category_id is not null` / `(owner_id, period_month) where category_id is null`) stand in for one constraint, since NULL is never equal to NULL in a plain unique index.
- **`fi_settings`** — `owner_id` (PK), `target_annual_spend` (nullable → derived from trailing 12mo real expense activity when unset), `withdrawal_rate` (default `0.04`), `real_return_rate` (default `0.05`), `updated_at`. Seeded once per user at signup (same as `profiles`) — always exactly one editable row, never an upsert-on-first-view path.
- **`fi_settings`** — `owner_id` (PK), `target_annual_spend` (nullable → derive from trailing 12mo expenses), `withdrawal_rate` (default `0.04`), `real_return_rate` (default `0.05`), `updated_at`.
- **`ops_events`** — `occurred_at`, `source`, `level`, `code`, `detail`. RLS **on, no policies** — nothing readable by `authenticated`, matching the parked ops design. No PII, ever.

### Derived balances — no balance is ever stored on `accounts`

- **`account_balance_on(p_account_id, p_date)`** (shipped Phase 8) — for `kind = 'ledger'`, `opening_balance + SUM(amount)` over transactions that are non-deleted, `status = 'confirmed'`, and `occurred_at <= least(p_date + 1 day, now())`. For `kind = 'valuation'`, the latest `balance_snapshots.value` at or before `p_date`, plus `SUM` of transfers dated after that snapshot, same filters. One `CASE`, so every caller (Home, Accounts, Sync Ritual) reads the same balance regardless of account kind — this is where money rule 1's two balance formulas actually live, in exactly one place. `least(p_date + 1 day, now())` is what lets one function serve both "today's live balance" (the future-dated guard: a not-yet-materialized recurring row can never move today's balance) and "balance as of an arbitrary past day" (Home's trajectory) without duplicating the CASE — for `p_date = current_date` it reduces to exactly `occurred_at <= now()`. **`account_balances`** is now a one-line wrapper (`account_balance_on(id, current_date)`) kept only because so much existing SQL already joins against it. **"After the snapshot" compares against `balance_snapshots.created_at` (the real timestamp it was recorded), not `as_of::date`** — found by testing the ordinary case of funding a brand-new investment account same-day: truncating to date made `occurred_at::date > as_of` false whenever both landed on the same calendar day, silently dropping every same-day transfer from the balance.
- **`accounts_with_balances`** — joins `account_balances` with `accounts`/`currencies` for name, kind, subtype, and `minor_unit`. One join, reused by every screen that lists accounts, instead of each re-deriving it.
- **`transactions_with_details`** — the same role for transactions: joins account name, category name, `minor_unit`, and derives `kind` (see the `transaction_kind` note above — computed here, not stored).
- **`create_transfer(p_from_account_id, p_to_account_id, p_from_amount, p_to_amount, p_occurred_at)`** RPC — the only transaction kind that needs one. Expense/income are a plain insert (the `sign_matches_category_kind` CHECK makes a wrong sign impossible without any code enforcing it); a transfer needs both legs inserted atomically with signs applied here in SQL. `p_to_amount` is optional — inferred to equal `p_from_amount` when both accounts share a currency, required otherwise. `SECURITY INVOKER` (the default, stated explicitly): this is a convenience wrapper around ordinary inserts, not a privilege escalation, so RLS and every constraint above still fully apply.
- **`account_balances_base`** — adds the base-currency conversion via `fx_convert()` and exposes `has_missing_rate`, per money rule 5.
- **`net_worth(p_scope account_scope)`** RPC (shipped Phase 7) — `'me' | 'household' | 'total'`. `total` is literally `me + household` computed by summing the same `account_balances_base` rows under different `WHERE` clauses; it is **never** assembled by subtracting three client-fetched numbers, because there is nothing to subtract that RLS would let a client see anyway. Renders `NULL` (→ `—`) the instant any row in scope has a missing rate — never a silently-partial `SUM` — but `0` for a genuinely empty scope; the two are deliberately not conflated.
- **`net_worth_daily`** (shipped Phase 8) — materialized per account, per day, **in each account's own currency** (never pre-converted), keyed `(account_id, as_of)`. RLS mirrors `can_read_account` (not `owner_id = auth.uid()`), so a household member can read a shared account's history for the `household`/`total` scopes exactly as they can the account itself. `refresh_net_worth_daily(p_user, p_from, p_to)` is the only write path (own data only, unless called as `service_role`); no `pg_cron` exists yet (Phase 13), so the client calls it itself before reading a trajectory. `net_worth_series(p_scope, p_from, p_to)` is the read side, converting each day on read via `fx_convert(..., that day)`, so a base-currency change never invalidates history and a past net worth figure never moves when today's rate moves.

### Money-rule-critical functions

- **`fx_rate_on(p_currency, p_date)`** — resolves the most recent `fx_rates` row at or before `p_date` (carries forward over weekends/holidays). EUR itself has an implicit rate of 1; every other currency is `rate_to_eur`.
- **`fx_convert(p_amount, p_from, p_to, p_date)`** — `p_amount / fx_rate_on(p_from, p_date) * fx_rate_on(p_to, p_date)`, short-circuited to `p_amount` when `p_from = p_to` (shipped Phase 8 — a same-currency conversion must never depend on `fx_rates` having a row for that date at all; without it, a many-day single-currency trajectory needed a resolvable rate on *every* day). **The only place currency conversion happens** — called by every view and RPC above, never duplicated. Returns `NULL` (→ `—`) if either rate is missing, never `0`.

### Integrity

- **Composite FKs**: `transactions (account_id, owner_id) → accounts (id, owner_id)` closes the RLS gap where a user could otherwise insert a transaction pointing at *someone else's* account — RLS checks `auth.uid()` on the row being written, not on the account it references. `transactions (account_id, currency) → accounts (id, currency)` keeps a transaction's currency locked to its account's. `transactions (account_id, account_kind) → accounts (id, kind)` plus a CHECK enforces valuation-accounts-take-transfers-only. `transactions (category_id, category_kind) → categories (id, kind)` stops an expense filing under an income category; both columns are `NULL` for transfers, and `MATCH SIMPLE` skips the check there. Every referenced tuple (`id, owner_id`), `(id, currency)`, `(id, kind)` needs its own `UNIQUE` constraint on `accounts` — `id` alone being unique isn't sufficient for Postgres to accept it as a composite FK target; `(id, owner_id)` was the one Phase 1 should have added alongside `(id, currency)` and didn't, caught by `db reset` failing outright rather than by review. `account_kind` and `category_kind` on `transactions` are both populated by one `BEFORE INSERT OR UPDATE` trigger, so the app never has to keep either in sync itself.
- **Transfer integrity**: a `DEFERRABLE INITIALLY DEFERRED` constraint trigger checks, at end of statement, that a `transfer_group_id` has exactly 0 or 2 non-deleted legs (never 1 — soft-deleting one leg can't orphan the other), distinct accounts, one `owner_id`, and — only when both legs share a currency — nets to zero. Cross-currency legs deliberately don't balance; the difference is the real spread, and §Transaction Entry's rate-divergence guard is the check against a *typo* rather than a real spread.
- **`NO ACTION DEFERRABLE`, never `RESTRICT`** on FKs a cascade might touch — `RESTRICT` cannot be deferred and fires mid-cascade, which would make deleting a user (or a household fork, §4) impossible to express as one transaction.
- **Household access model** (shipped Phase 7): shared visibility routes through `household_accounts` + `household_members`, never a second `owner_id` on the account. `households`/`household_members` cap membership at 2 (trigger); `my_household_id()` (`SECURITY DEFINER`, same recursion-avoidance reasoning as below) is the predicate `household_members`'/`households`' own RLS policies call. `can_read_account(p_account_id)` / `can_write_account(p_account_id)` are the predicates every *other* account-scoped table's RLS policy calls:
  ```sql
  -- SECURITY DEFINER, not INVOKER — required to avoid infinite recursion
  -- (see finding below), not a style choice.
  create function can_read_account(p_account_id uuid) returns boolean
    language sql stable security definer set search_path = '' as $$
    select exists (
      select 1 from public.accounts
      where id = p_account_id and owner_id = (select auth.uid())
    )
    or exists (
      select 1
      from public.household_accounts ha
      join public.household_members hm on hm.household_id = ha.household_id
      where ha.account_id = p_account_id and hm.user_id = (select auth.uid())
    );
  $$;
  create function can_write_account(p_account_id uuid) returns boolean
    language sql stable security definer set search_path = '' as $$
    select public.can_read_account(p_account_id);
  $$;
  ```
  Every policy that calls either predicate (`balance_snapshots`' two policies, `transactions`' select/insert/update) upgraded for free from this one function-body edit — **except `accounts`' own two policies, a deliberate exception; see below.** `share_account()`/`unshare_account()` (both `SECURITY DEFINER`, owner-only) are the only write path onto `household_accounts`. **Revised in L2** (`keepo-local-first-plan.md`): `unshare_account` now forks — same posture as `leave_household` — whenever another member is present, so the losing member keeps a full independent replica instead of simply losing the account; see "Sync primitives" below. `net_worth(p_scope account_scope)` sums `account_balances_base` under a `me`/`household`/`total` `WHERE` clause, `total` always `me + household`, never subtraction. Full account of the two hazards this ordering was chosen to avoid — shared rows silently vanishing from `account_balances_base`/`transactions_with_details` (both views now join `profiles` on the *viewer's* id, not the row's `owner_id`), and a cross-owner transfer being structurally rejected (`check_transfer_integrity`'s one-owner rule now also accepts "both legs' accounts share a household") — lives in `supabase/migrations/20260806090000_households.sql`'s header comment and `version-logs/phase-7-log.md`.

  **Two real bugs found only by testing against a live database, not by inspection:**
  1. **`SECURITY INVOKER` recursion (Phase 1).** The obvious first version queries `accounts` from inside a policy *on* `accounts` — under `SECURITY INVOKER` that inner query re-triggers the same policy, calling itself again, forever (`stack depth limit exceeded`). Fixed with `SECURITY DEFINER`, which lets the inner lookup bypass RLS instead of re-entering it.
  2. **`SECURITY DEFINER` + self-reference breaks `INSERT ... RETURNING` (Phase 2).** Even after fixing (1), `accounts`' *own* `SELECT`/`UPDATE` policies routed through `can_read_account`/`can_write_account` — which re-query `accounts`, the very table whose policy is calling them. That self-reference breaks specifically for a row written earlier in the *same command*: Postgres doesn't reliably make it visible to the function's own fresh subquery (confirmed empirically; ruled out `STABLE` vs `VOLATILE` and SQL vs `plpgsql` as the cause — neither changed the result). A bare inline `owner_id = (select auth.uid())` needs no such lookup and is unaffected, proven by testing the identical `can_read_account(account_id)` pattern on `transactions` — checking a *different*, already-existing table — succeeding perfectly with `RETURNING`. **Fix:** `accounts`' own `accounts_select`/`accounts_update` policies compare `owner_id` (or household membership) directly instead of calling the shared predicate — Phase 7 edited both policies directly, as this note originally predicted, an accepted, documented cost of a real Postgres behavior rather than a design mistake.
### Sync primitives (L2, `keepo-local-first-plan.md`)

Server-side infrastructure for the local-first rebuild, landed ahead of any client code that consumes it (L3–L6 build the on-device store and read path against this). **The app is still online-first today** — nothing below changes current client behavior; it exists so the client can adopt it incrementally.

- **`sync_tickets(domain_id, next_ticket)`** + **`next_ticket(p_domain_id)`** — one monotonic counter per *sync domain* (a household's id if the caller belongs to one, otherwise their own user id; `sync_domain_id(p_user_id)` resolves which). `next_ticket()` takes the counter via `select ... for update`, so the row lock is held until the caller's transaction commits — a **lower ticket is guaranteed to have committed first**, closing the hazard a `now()`-based cursor cannot: a slow write starting before a fast one but committing after it would otherwise sit below a naive timestamp cursor forever, silently and permanently unsynced. Verified empirically with two overlapping `psql` sessions, not just by inspection — see `supabase/scripts/two_session_ticket_order.sh`.
- **`sync_seq bigint`** on every syncable table (`accounts`, `transactions`, `balance_snapshots`, `categories`, `budgets`, `fi_settings`, `recurring_rules`, `card_mappings`, `merchant_category_map`, `sync_conflicts`, `households`, `household_members`, `household_accounts`, `profiles`), stamped by a `BEFORE INSERT OR UPDATE` trigger calling `next_ticket()` for the row's domain. **`currencies`/`fx_rates` share one separate, fixed global domain** (`sync_global_domain()`) instead — a rate has no owner, but still needs a ticket. This is why `pull_changes` takes **two** cursors, not one: the global domain's counter accumulates across every user and grows far faster than any single household's, so a single scalar cursor taking the max across both would be dominated by the global one, and a freshly re-stamped row in a quiet household domain could sit at a low ticket while the client's cursor was already past a much higher global-domain value — `sync_seq > cursor` would be false forever for that row. Two independent cursors, each compared only against its own counter, is the actual fix (found via pgTAP, not by inspection).
- **`pull_changes(p_cursor, p_global_cursor)`** — `SECURITY INVOKER`, deliberately not an Edge Function: an RPC runs as the calling user, so RLS filters every table's changed-rows query for free. An Edge Function would need `service_role`, forcing `can_read_account` to be reimplemented in TypeScript — a second copy of the *access* model, a worse bug than a second copy of the money model. Returns one JSON object keyed by table name, each a `to_jsonb` array of rows with `sync_seq > cursor` (or `> global_cursor` for currencies/fx_rates), plus the two advanced cursors and the caller's `sync_epoch`.
- **`sync_epoch bigint`** on `profiles`, default 1. The access model today (RLS) filters every read live; a local-first client instead relies on the last pull, so gaining or losing access needs an explicit signal:
  - **Gaining access** (`share_account`) — the shared account and its existing transactions/snapshots/recurring rules predate the share and already carry old tickets that a normal cursor pull would never re-fetch. `restamp_account_for_sync()` re-stamps them with fresh tickets in the household domain instead. It does this via a plain touch `UPDATE`, not `ALTER TABLE ... DISABLE TRIGGER` (the first attempt) — that approach fails with "cannot ALTER TABLE because it has pending trigger events" whenever the account was created earlier in the same transaction, due to the `DEFERRABLE` FK triggers on `accounts`/`transactions`. `bump_version()`/`set_updated_at()` gained a transaction-local `keepo.restamp_only` escape hatch so this re-stamp doesn't also bump `version`/`updated_at` on every touched row — a share shouldn't silently invalidate the sharer's own cached `expectedVersion`.
  - **Losing access** (`unshare_account` with another member present, `leave_household`, `erase_own_account`, and `accept_invite` for the *accepting* user's own domain change) — bumps the affected user's `sync_epoch`. A local-first client sees the epoch move, drops its server-derived tables (keeping the outbox), and re-pulls from cursor 0 — the cleanest correct response to "my domain's ticket numbering just changed out from under me," since a cursor from before a domain change is denominated in a different, unrelated counter. `unshare_account` forks first (`fork_one_account`, extracted from `fork_household_accounts`' per-account loop so both share one implementation) so the losing member keeps a full independent replica, then bumps only *their* epoch — the sharer's own domain and cursor are untouched.
- **Not yet true**: "RLS filters at download time, not read time" is the eventual L5/L6 client behavior once the local store exists; today RLS still filters every live read exactly as before, and `pull_changes` simply exists as an available, additional path.

- **RLS + GRANTs, every table, no exceptions.** RLS narrows access a `GRANT` already gave; it grants nothing itself — without the `GRANT` a query fails before RLS is even consulted. Nothing is granted to `anon`. One policy per command, always `(select auth.uid())` (the bare form re-evaluates per row), and every `UPDATE` policy carries both `USING` and `WITH CHECK` — `USING` alone lets a user reassign a row's ownership to someone else. **Supabase's local cluster grants `TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN` to `anon` and `authenticated` on every table by default** (visible via `pg_default_acl`; confirmed `anon` could actually issue `TRUNCATE`, which bypasses RLS entirely) — closed once, schema-wide, with `ALTER DEFAULT PRIVILEGES ... REVOKE ...` before the first `CREATE TABLE`, so every future table is clean automatically rather than needing a per-table fix.
- **`needs_review`** is a **view**, not a table — `UNION ALL` over: `transactions WHERE status = 'pending'` (unconfirmed captures), `card_mappings WHERE account_id IS NULL` (ambiguous cards), `sync_conflicts WHERE resolved_at IS NULL`, `reconciliations` gaps, `csv_import_candidates WHERE status = 'pending'`, and low-confidence category suggestions from `merchant_category_map`. One inbox, one query, no duplicated review-tracking table per feature.

### Indexes

Postgres doesn't auto-index FK columns. Needed from day one: `transactions (account_id)`, `(category_id)`, `(owner_id, occurred_at desc, id desc)` for keyset pagination, `(transfer_group_id) WHERE transfer_group_id IS NOT NULL`, a partial unique index on `(owner_id, source, external_id) WHERE external_id IS NOT NULL` (capture/import idempotency, §4), plus `accounts (owner_id)`, `categories (owner_id, kind)`, `balance_snapshots (account_id, as_of desc)`.

### Auth

`profiles` is created by a `handle_new_user()` trigger on `auth.users` insert (`SECURITY DEFINER`, `search_path = ''`), which also seeds both default "Other" categories. Deliberately minimal — any exception aborts signup with an opaque error — with an idempotent `ensure_user_bootstrap()` for self-heal, mirroring the pattern that proved itself in the prior backend.

The app never holds `service_role`. Only the anon key ships on-device; anything needing elevated access is an Edge Function.

---

## 4. Data Pipelines

### FX sync

`supabase/functions/sync-fx-rates` pulls from **`api.frankfurter.dev/v1`** (note: `frankfurter.app` 301-redirects and must not be used), EUR-pivoted, only for currencies actually in use (`accounts.currency ∪ profiles.base_currency`), on a 5-day overlapping window so one missed run self-heals. `pg_cron` fires it daily; `pg_net` calls it asynchronously, gated by a `FX_SYNC_SECRET` header rather than a user JWT (the caller is a cron job, not a signed-in user).

**Backfill on first use**: adding the first account in a currency, or changing `base_currency`, triggers a 400-day backfill for that currency so the user never sees `—` waiting for the next scheduled run. The 400-day floor makes repeated triggers idempotent — a currency already backfilled doesn't re-qualify.

**Health is derived from data, never job status** (`cron.job_run_details` records success once a request is *dispatched*, regardless of whether it actually succeeded) — see §Operations.

### Recurring materialization

A nightly job walks `recurring_rules` and inserts real `transactions` rows (`source = 'recurring'`) **only up to today**, backfilling any occurrences missed while the job was down. Balance-reading code additionally guards `occurred_at <= now()` regardless, so a bug here degrades to a stale projection, never a corrupted current balance. Upcoming instances shown in the UI are computed from the rule at read time and are never rows.

### Capture ingestion (Wallet automation)

Shortcuts automation on the Wallet trigger → App Intent, payload `Transaction; Card; Merchant; Amount; Name`:

1. Card string resolves via `card_mappings`; unmapped → **no transaction is created** (there is no account to attach a signed amount to yet) — only the card's placeholder `card_mappings` row lands, flagged into Needs Review via `card_mappings.account_id IS NULL`. The purchase itself is not retried once the card is later mapped; the next capture on that card succeeds normally.
2. Currency comes from the **mapped account**, never parsed from the `$`-formatted `Amount` string — the symbol is a mismatch check only.
3. `merchant_normalized` strips aggregator noise (`SQ *`, `TST*`, trailing store numbers, LLC suffixes); `merchant_raw` is kept so normalization can improve without re-capture.
4. `external_id = hash(card + amount + merchant_normalized + time_bucket)`, enforced by the partial unique index in §3 — a re-fired automation is a no-op, not a duplicate.
5. Row is inserted `status = 'pending', source = 'capture'`. A local notification prompts review; confirming sets `status = 'confirmed'`.
6. The App Intent (declared in the **app target**, not an extension — see Phase 11/12) **only ever inserts this pending stub** — it never reads a balance or existing transaction, since it executes outside the biometric lock (parked security design).

### CSV import

Client parses the file; each row becomes a `csv_import_candidates` row matched against existing transactions (exact amount, ±3 days, same account). No `external_id` exists for CSV (no bank-assigned id), so nothing is ever blind-inserted — every candidate surfaces in Needs Review for accept/reject.

### Household leave / fork

One `SECURITY DEFINER`, transactional RPC: copies every row in `household_accounts` for that household — the accounts themselves, their transactions, and their `balance_snapshots` — into two fresh sets of rows under new ids, one per member, then deletes the `household_members` row. Deleting that row is the entire revocation: `can_read_account` no longer matches for either member on the old shared account, and each new copy is owned outright by its respective member. A leaver's pending offline writes are drained against their own new copy, not the now-severed original. The same RPC is what GDPR erasure calls before scrubbing the leaving member's PII from their own resulting copy.

---

## 5. Charts

**Swift Charts** (native SwiftUI, iOS 16+) replaces the retired backend's hand-rolled SVG — no third-party charting dependency, matching the "reuse before writing" principle now that a first-party equivalent exists on the platform. Bucketing/scale logic that Swift Charts doesn't provide out of the box (weekly vs. monthly granularity by span) lives in `KeepoCore`, unit-tested, per §2.

Two findings from the retired doc's palette work still hold and are **not being re-derived**, since they were validated against actual CVD tooling rather than chosen by eye:

| Role | Light | Dark |
|---|---|---|
| Expense | `#FF5A5F` (BrandPrimary) | `#F04A50` |
| Income | `#2a78d6` | `#3987e5` |

- **Income is blue, not green.** Coral-vs-green is the canonical red-green colorblind failure (ΔE 7.6); coral-vs-blue clears it (ΔE 19.5).
- **Mango (`#FF9F1C`, BrandSecondary) stays a UI accent** (budget limits, goal markers) — it falls outside the lightness band needed for a data series on a white surface.

Other rules carried forward: one axis, never dual — a second implied scale is a comprehension tax the chart doesn't need to impose. Gaps filled with real zeroes, never omitted, so evenly-spaced bars don't imply evenly-spaced dates. Category bars carry their name and value as text, so an unvalidated user-chosen category color is never the only identity channel. Bucket granularity is derived from the span, never a user control: 30/90-day ranges bucket weekly, longer ranges monthly — daily income-vs-expense is dominated by the one day salary lands.

---

## 6. Deploy

**Backend**: `supabase init` + `supabase start` locally against Docker for day-to-day work; `supabase link --project-ref <ref>` to the hosted project the user creates. `supabase db push` is manual — migrations are never automatic — and always runs **before** the client code that depends on them, never after. `supabase gen types swift` regenerates the Swift model layer after **every** migration, so a schema change is a compile error in the client if the model wasn't updated, not a silent runtime mismatch. Edge Functions deploy individually via `supabase functions deploy <name>`.

**Client**: TestFlight for beta builds, App Store Connect for release, no auto-deploy on push — matching CLAUDE.md.

**Local secrets**: `Config/Debug.xcconfig` / `Config/Release.xcconfig` (gitignored, `.example` variants committed) hold `SUPABASE_URL` / `SUPABASE_ANON_KEY`. Real Supabase secrets (`FX_SYNC_SECRET`, the vault-stored sync URL) are set via `supabase secrets set` on the hosted project and `vault.create_secret` in SQL — never committed, never in an `.xcconfig`.
