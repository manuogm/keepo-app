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

`transaction_kind` (expense, income, transfer) is **not** an input enum — it's a `GENERATED ALWAYS` column derived from `transfer_group_id IS NOT NULL` and the sign of `amount`, so it can never disagree with the row that produced it (money rule 1: never re-sign in application code).

### Tables

- **`currencies`** — reference table, the ECB/Frankfurter set (~30 + EUR). `code` (PK), `minor_unit`. The currency picker (client) can only offer rows from this table — an unpriceable account can never be created.
- **`profiles`** — `id` (= `auth.uid()`), `base_currency` (FK `currencies`), `onboarded_at`.
- **`accounts`** — `id` (client-generated UUID), `owner_id`, `created_by`, `kind` (`account_kind`), `subtype` (`account_subtype`), `name`, `currency` (FK `currencies`), `opening_balance`, `opening_balance_at`, `include_in_total`, `counts_toward_fi`, `archived_at`, `version`, `deleted_at`, timestamps. `UNIQUE (id, currency)` — the anchor for a composite FK below.
- **`balance_snapshots`** — `account_id`, `as_of`, `value`, `created_by`, `created_at`. Only meaningful for `valuation` accounts; a transfer into one **auto-writes a snapshot** at `prior + transfer amount` so the account is never `—` between manual valuations.
- **`categories`** — `id`, `owner_id`, `kind` (`category_kind`), `name`, `is_default`, `deleted_at`. Exactly one `is_default` row per `(owner_id, kind)`. `UNIQUE (id, kind)` for the composite FK below.
- **`merchant_category_map`** — `owner_id`, `merchant_pattern`, `category_id`, `updated_at`. PK `(owner_id, merchant_pattern)`. RLS-scoped to `owner_id` alone, **never** joined into any household-visible view (spec: merchant learning is per-user, not per-household).
- **`transactions`** — `id` (client-generated UUID), `owner_id`, `created_by`, `account_id`, `category_id` (null for transfers), `category_kind` (mirrors `category_id`'s kind, set by trigger — see composite FKs), `amount` (`numeric(20,4)`, signed), `currency`, `occurred_at`, `merchant_raw`, `merchant_normalized`, `transfer_group_id` (null unless a transfer leg), `source` (`transaction_source`), `status` (`transaction_status`, default `confirmed`; `capture`-sourced rows start `pending`), `external_id` (nullable, idempotency — see §4), `version`, `deleted_at`, timestamps.
- **`recurring_rules`** — `id`, `owner_id`, `account_id`, `category_id`, `amount`, `currency`, `frequency` (`recurring_frequency`), `next_due_at`, `last_materialized_at`, `active`.
- **`fx_rates`** — `currency` (FK `currencies`), `rate_date`, `rate_to_eur`, `source` (`fx_source`), `fetched_at`. PK `(currency, rate_date)`. **Upserted, not blind-inserted** — a later `fetched_at` for the same `(currency, rate_date)` wins, which is how an ECB revision to a recent value gets picked up. This is why `fx_rates` is described as "append-only" in the money rules despite the upsert: no row is ever destructively rewritten by application code outside this one conflict-resolution rule, and old converted figures stay reproducible because the key never silently vanishes.
- **`reconciliations`** — `id`, `account_id`, `as_of`, `entered_balance`, `computed_balance`, `adjustment_txn_id` (nullable, ledger accounts), `snapshot_id` (nullable, valuation accounts), `created_by`, `created_at`. What renders "verified X ago."
- **`households`** — `id`, `created_at`.
- **`household_members`** — `household_id`, `user_id`, `joined_at`. PK `(household_id, user_id)`. Trigger caps membership at 2.
- **`household_accounts`** — `household_id`, `account_id`, `shared_at`. PK `(household_id, account_id)`.
- **`household_invites`** — `id`, `household_id`, `invited_by`, `token_hash`, `status` (`household_invite_status`), `expires_at`, `created_at`. Single-use, expiring, revocable per the parked security design.
- **`sync_conflicts`** — `id`, `table_name`, `row_id`, `owner_id`, `client_version`, `server_version`, `created_at`, `resolved_at`. Populated when a push's `version` doesn't match — feeds Needs Review.
- **`card_mappings`** — `owner_id`, `card_identifier` (raw Shortcuts card string), `account_id` (nullable — null means unmapped, routes to Needs Review). PK `(owner_id, card_identifier)`.
- **`csv_import_batches`** / **`csv_import_candidates`** — batch: `id`, `owner_id`, `account_id`, `filename`, `created_at`. candidate: `batch_id`, `raw_row` (jsonb), `matched_transaction_id` (nullable), `status` (`import_candidate_status`).
- **`budgets`** — `id`, `owner_id`, `category_id` (nullable = overall), `period_month`, `amount_base` (in the owner's base currency), `created_at`.
- **`fi_settings`** — `owner_id` (PK), `target_annual_spend` (nullable → derive from trailing 12mo expenses), `withdrawal_rate` (default `0.04`), `real_return_rate` (default `0.05`), `updated_at`.
- **`ops_events`** — `occurred_at`, `source`, `level`, `code`, `detail`. RLS **on, no policies** — nothing readable by `authenticated`, matching the parked ops design. No PII, ever.

### Derived balances — no balance is ever stored on `accounts`

- **`account_balances`** view (`security_invoker = true`): for `kind = 'ledger'`, `opening_balance + COALESCE(SUM(amount), 0)` over non-deleted transactions; for `kind = 'valuation'`, the latest `balance_snapshots.value` at or before the query date, plus `SUM` of transfers dated after that snapshot. One `UNION ALL`, so every caller (Home, Accounts, Sync Ritual) reads the same balance regardless of account kind — this is where money rule 1's two balance formulas actually live, in exactly one place.
- **`account_balances_base`** — adds the base-currency conversion via `fx_convert()` and exposes `has_missing_rate`, per money rule 5.
- **`net_worth(p_scope account_scope)`** RPC — `'me' | 'household' | 'total'`. `total` is literally `me + household` computed by summing the same `account_balances_base` rows under different `WHERE` clauses; it is **never** assembled by subtracting three client-fetched numbers, because there is nothing to subtract that RLS would let a client see anyway.
- **`net_worth_daily`** — materialized per user, per day, **in each account's own currency** (never pre-converted). The dashboard trajectory converts on read via `fx_rate_on(occurred_date)`, so a base-currency change never invalidates history and a past net worth figure never moves when today's rate moves.

### Money-rule-critical functions

- **`fx_rate_on(p_currency, p_date)`** — resolves the most recent `fx_rates` row at or before `p_date` (carries forward over weekends/holidays). EUR itself has an implicit rate of 1; every other currency is `rate_to_eur`.
- **`fx_convert(p_amount, p_from, p_to, p_date)`** — `p_amount / fx_rate_on(p_from, p_date) * fx_rate_on(p_to, p_date)`. **The only place currency conversion happens** — called by every view and RPC above, never duplicated. Returns `NULL` (→ `—`) if either rate is missing, never `0`.

### Integrity

- **Composite FKs**: `transactions (account_id, owner_id) → accounts (id, owner_id)` closes the RLS gap where a user could otherwise insert a transaction pointing at *someone else's* account — RLS checks `auth.uid()` on the row being written, not on the account it references. `transactions (account_id, currency) → accounts (id, currency)` keeps a transaction's currency locked to its account's. `transactions (category_id, category_kind) → categories (id, kind)` stops an expense filing under an income category; both columns are `NULL` for transfers, and `MATCH SIMPLE` skips the check there. `category_kind` on `transactions` is populated by a `BEFORE INSERT` trigger from `category_id`, so the app never has to keep the two in sync itself.
- **Transfer integrity**: a `DEFERRABLE INITIALLY DEFERRED` constraint trigger checks, at end of statement, that a `transfer_group_id` has exactly 2 legs, distinct accounts, one `owner_id`, and — only when both legs share a currency — nets to zero. Cross-currency legs deliberately don't balance; the difference is the real spread, and §Transaction Entry's rate-divergence guard is the check against a *typo* rather than a real spread.
- **`NO ACTION DEFERRABLE`, never `RESTRICT`** on FKs a cascade might touch — `RESTRICT` cannot be deferred and fires mid-cascade, which would make deleting a user (or a household fork, §4) impossible to express as one transaction.
- **Household access model**: shared visibility routes through `household_accounts` + `household_members`, never a second `owner_id` on the account. `can_read_account(p_account_id)` / `can_write_account(p_account_id)` are the only predicates any RLS policy calls:
  ```sql
  -- v1 body — ownership only
  create function can_read_account(p_account_id uuid) returns boolean
    language sql stable security invoker as $$
    select exists (
      select 1 from accounts
      where id = p_account_id and owner_id = (select auth.uid())
    );
  $$;
  -- can_write_account calls can_read_account — v1 access is symmetric,
  -- and this keeps the "same access" rule in one place if that ever changes.
  create function can_write_account(p_account_id uuid) returns boolean
    language sql stable security invoker as $$
    select can_read_account(p_account_id);
  $$;
  ```
  When households ship, `can_read_account`'s body gains one `OR EXISTS (... household_accounts JOIN household_members ...)` clause. **Every policy that calls it upgrades in the same migration, with no policy-by-policy rewrite** — this is the whole reason the predicate exists instead of inlining the ownership check per-policy.
- **RLS + GRANTs, every table, no exceptions.** RLS narrows access a `GRANT` already gave; it grants nothing itself — without the `GRANT` a query fails before RLS is even consulted. Nothing is granted to `anon`. One policy per command, always `(select auth.uid())` (the bare form re-evaluates per row), and every `UPDATE` policy carries both `USING` and `WITH CHECK` — `USING` alone lets a user reassign a row's ownership to someone else.
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

1. Card string resolves via `card_mappings`; unmapped → the row is still created but flagged into Needs Review (via `card_mappings.account_id IS NULL`).
2. Currency comes from the **mapped account**, never parsed from the `$`-formatted `Amount` string — the symbol is a mismatch check only.
3. `merchant_normalized` strips aggregator noise (`SQ *`, `TST*`, trailing store numbers, LLC suffixes); `merchant_raw` is kept so normalization can improve without re-capture.
4. `external_id = hash(card + amount + merchant_normalized + time_bucket)`, enforced by the partial unique index in §3 — a re-fired automation is a no-op, not a duplicate.
5. Row is inserted `status = 'pending', source = 'capture'`. A local notification prompts review; confirming sets `status = 'confirmed'`.
6. The App Intent extension **only ever inserts this pending stub** — it never reads a balance or existing transaction, since it executes outside the biometric lock (parked security design).

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
