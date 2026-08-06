> **Maintenance note:** this file is the authoritative roadmap for the rest of the Keepo v1 build (Phases 5–20). If a coding session loses context or is cleared, read this file first — `CLAUDE.md` points here for that reason. If the plan changes along the way (a phase splits, a hazard turns out different, a decision gets revisited), update this file in place with the key finding before continuing, so it stays a reliable source of truth rather than a snapshot of the day it was written.

# Keepo v1 — Remaining Build Roadmap (Phases 5–20)

## Context

Phases 1–4 shipped a working vertical slice: schema for `currencies`/`profiles`/`accounts`/`balance_snapshots`/`categories`/`transactions`/`sync_conflicts`/`fx_rates`, the ledger/valuation balance views, versioned transaction-edit RPCs with conflict-as-data, FX conversion end to end, and a 3-tab SwiftUI app (Accounts | Transactions | Categories) on a `StubAuthProvider`.

Roughly 70% of `keepo-v1-feature-spec.md` is unbuilt: Home/net worth, Sync Ritual, Needs Review, households, recurring, Insights, budgets, FI, CSV import/export, Apple Pay capture, the offline outbox, ops/monitoring, and the security layer. There is also **no account-creation UI beyond onboarding** (flagged as blocking in two phase logs) and **no re-runnable SQL test suite** — the ~23 invariants from Phases 1–4 exist only as prose.

Goal: build every feature listed in the spec, in an order where each phase's foundations are correct before the next is built on them, verified by a suite that survives.

### Decisions taken (confirmed with the user)

- **Households split in two.** Access model + viewer-scoped money early (Phase 7); invites/leave/fork/APNs late (Phase 19).
- **`project.yml` stays at iOS 18.0**; verification runs on the installed iOS 26.5 simulator only. Accepted risk: an iOS-18-only bug surfaces at TestFlight.
- **`app-architecture.md` is authoritative.** Where it contradicts `keepo-v1-feature-spec.md` or CLAUDE.md's non-negotiable money rules, the phase **amends the doc first** (inline, matching its existing defect-history style) and then implements the corrected design. Three known cases are listed under "Doc amendments" below.
- **Hosted Supabase proven from Phase 5, not Phase 17.** `PasswordAuthProvider` (hosted-capable; `StubAuthProvider` has `precondition(config.isLocal)` and has never run against anything but the local stack) plus `supabase link` + `supabase db push` of the four existing migrations land in Phase 5. Every later phase's migration gets pushed to hosted as part of its own exit gate, not deferred to one big push at the end.
- **Apple Developer membership assumed not to arrive until after Phase 20.** Phase 19's two-device household test runs on free-personal-team provisioning (7-day profiles, built and installed from the Mac onto both phones — no TestFlight). Phase 20 stays the separate SIWA + APNs + TestFlight pass, unchanged in scope; revisit only if the membership actually arrives earlier.
- **Cadence — four human review stops, agreed with the user:**
  1. **After Phase 5** — before any feature work, confirm Phases 1–4 hold under the new pgTAP suite and that hosted actually works.
  2. **After Phase 8** (not 7) — Phase 7 (households backend) is a **machine gate only**: proceed to 8 solely if its pgTAP suite is green, stop and report if not. There's little to visually review at the end of 7 (single-member households, a toggle); Phase 8 is where a broken access model becomes *visible* — a wrong or missing number on the Home hero metric — which is what a human review is actually good at catching.
  3. **After Phase 11** — end of the offline-outbox/file-protection work, before capture depends on it.
  4. **After Phase 19** — household lifecycle complete on two physical devices (free-team provisioning); app fully functional except SIWA/APNs/TestFlight.
  Every other phase boundary still runs its full automated exit gate (pgTAP, xcodebuild, swiftlint, simulator walkthrough, version log) — it's just not a stop for human review.

### Doc amendments required (each made in the phase that needs it)

| Doc line | Conflict | Resolution |
|---|---|---|
| `app-architecture.md:108` — `budgets.amount_base` "in the owner's base currency" | Stores a converted amount → violates money rule 6; cannot satisfy the spec's "budgets: viewer's base currency" when two household members have different bases | Phase 16: store `amount` + `currency` as typed, convert on read via `fx_convert`. Amend the doc line. |
| `app-architecture.md:114` — the two-kind balance CASE lives "in exactly one place" (`account_balances`) | The view is hardcoded to `current_date`, so the Home trajectory cannot reuse it and would have to duplicate the CASE — breaking the doc's own one-place rule | Phase 8: extract `account_balance_on(p_account_id, p_date)`, redefine `account_balances` as a wrapper at `current_date`. Amend the doc to name the function as the one place. |
| `app-architecture.md:120` — `net_worth_daily` materialized | No conflict. Implemented as the doc specifies. | Phase 8 builds the table + `refresh_net_worth_daily()`, per-account-currency and unconverted, converted on read at `fx_rate_on(day)`. Phase 13's cron schedules the refresh. |

`categories.system_key` (Phase 9) is a doc *gap*, not a contradiction — the doc never says how the adjustment system category is identified, and it cannot be a second `is_default` row because of the `categories_one_default_per_kind` partial unique index. Added to the doc when built.

---

## Hazards this ordering exists to avoid

These were found during exploration and are the reason the phase order is what it is. Each is closed in a named phase.

| # | Hazard | Closed in |
|---|---|---|
| H1/H9 | `account_balances_base:159` and `transactions_with_details:233` join `profiles on p.id = <row>.owner_id`. Both views are `security_invoker`, and `profiles_select` is `id = auth.uid()` — so under households a shared account owned by the *other* member has no visible `profiles` row and the inner join **silently drops the row entirely**. Not a wrong rate: a missing account, no error. | 7 |
| H2 | The four DEFINER write RPCs hardcode `owner_id <> auth.uid()` (`update_transaction:105,114`, `update_transfer:188`, `delete_transaction:245`, `delete_transfer:304`) and `create_transfer:484` derives each leg's owner from the account row. The "households upgrade via one function-body edit" story is false. | 7 |
| H3 | All three `accounts` policies inline `owner_id = auth.uid()` (documented Phase 2 exception: DEFINER self-reference breaks `INSERT … RETURNING`). Must be edited directly. | 7 |
| H4 | `accounts` still has an unrestricted `UPDATE` grant to `authenticated` — no column whitelist, no optimistic-concurrency check, despite `accounts.version` + bump trigger existing. Transactions closed this in Phase 3; accounts never did. | 6 |
| H5 | `net_worth(scope)` is `'me' \| 'household' \| 'total'` by spec — uncomputable before households exist. | 7 |
| H10 | `transactions` FK `(account_id, owner_id) → accounts (id, owner_id)` forces a txn's owner to equal its account's owner, and `check_transfer_integrity` asserts `count(distinct owner_id) = 1`. A transfer from a private account into a partner-owned household account is **structurally rejected**. | 7 |
| H11 | `account_balances` is `current_date`-only; a historical series can't reuse it. | 8 |
| H12 | No `(category_id, owner_id)` composite FK and no `unique (id, owner_id)` on `categories` — a transaction can reference another user's category. Latent now, live once household categories merge. | 5 |
| H13 | `budgets.amount_base` stores a converted amount. | 16 |
| H14 | The adjustment category can't be a second `is_default` row (partial unique index on `(owner_id, kind) where is_default`). | 9 |
| H15 | `fx_convert` has no same-currency short-circuit — a 365-point single-currency trajectory needs a resolvable rate row on every date or renders `—`. | 8 |
| H7 | `.task {}` fires once per view identity; tab switches never refetch. Live bug on all three existing screens. | 6 |
| H8 | `ISO8601DateFormatter()` instantiated ad hoc in 8 places; no inverse of `AmountParser` (`TransactionFormView:210,224` use `"\(abs(amount))"`, period-decimal — the Phase 1 locale bug in reverse). | 6 |

---

## Phase 5 — Re-runnable SQL test harness & seed fixtures

**Goal:** turn Phases 1–4's prose invariants into a committed suite that runs in one command — *before* households changes what they mean. A harness written inside Phase 7 can't distinguish "households broke this" from "this was never true."

- `supabase/tests/`, pgTAP via `supabase test db --local`. `create extension if not exists pgtap` goes **inside the test transaction**, never a migration — pgTAP must not reach the hosted project.
- Files: `_helpers.sql` (two fixture users, `as_user(uuid)`, `as_anon()`), `01_grants_rls.sql`, `02_accounts_balances.sql`, `03_transactions_integrity.sql`, `04_transaction_editing.sql`, `05_fx.sql`. Target ≥ the 23 documented invariants.
- **Schema-wide assertions pay compound interest** — they auto-cover every table added in Phases 6–20: zero grants to `anon` anywhere in `public` (`information_schema.role_table_grants`), `relrowsecurity` true on every table, zero `DELETE` policies (`pg_policies`), every `prosecdef` function carrying `search_path=` in `proconfig`.
- `supabase/seed.sql` — `config.toml` already points at a file that doesn't exist. Two users, EUR + USD + investment accounts, sample transactions, a few `fx_rates`. Immediately relieves the "every account after the first needs direct SQL" pain.
- Migration: closes **H12** — `unique (id, owner_id)` on `categories`, and the category-owner check added to `set_transaction_derived_columns()` (the trigger is where the household-aware version lands anyway, so no churn later).
- **Harness gotchas to encode as comments in `_helpers.sql`:** the file owns `begin … rollback`, so `DEFERRABLE INITIALLY DEFERRED` triggers (`transactions_check_transfer_integrity`) never fire — testing the 0-or-2-legs rule needs `SET CONSTRAINTS ALL IMMEDIATE`. `select * from f()`, never `select (f()).*` (Phase 3 lesson). `reset role` before switching fixture user. `auth.uid()` reads `request.jwt.claim.sub`, so `set_config(...) + set local role authenticated` suffices — no JWT minting.
- **Hosted, proven now, not deferred to Phase 17:** `KeepoCore/PasswordAuthProvider.swift` — email+password against whatever `SupabaseConfig` it's given, no `isLocal` precondition; `SessionStore` picks stub vs. password provider off a build flag/xcconfig var, defaulting to stub for local dev. `supabase link --project-ref <ref>` (real hosted project the user creates) + `supabase db push` of all four existing migrations. `supabase gen types swift --local --lang swift --swift-access-control public` re-run and diffed against hosted's generated types to confirm they match. Debug/Release `.xcconfig` gains a hosted URL/anon-key pair alongside the local one (still gitignored).
- **Verify:** `supabase db reset` then `supabase test db --local` green, locally. Separately: push to hosted, sign up + sign in with `PasswordAuthProvider` against the hosted URL from the simulator, confirm onboarding and one account/transaction round-trip through RLS with a real (non-local) JWT.

## Phase 6 — Account lifecycle & shared client data layer

**Goal:** accounts are fully manageable from the app, and every screen refreshes correctly.

- **Migration:** `revoke update on accounts from authenticated` (**H4**), then DEFINER RPCs `update_account`, `archive_account`, `delete_account` (refuses when non-deleted transactions exist), each returning `(conflict boolean, …)` as data per Phase 3's convention, each with `default null` on every parameter a Swift `Optional` can omit (the `PGRST202` lesson). Editable: `name`, `subtype`, `include_in_total`, `counts_toward_fi`, `opening_balance`. Not editable: `currency` (composite FKs lock it), `kind` (changes the balance formula). Append `version` to `accounts_with_balances`.
- **Client:** `AccountFormView` (create/edit, mirroring `TransactionFormView`'s `Mode` enum), archive/unarchive, "Everyday"/"Investments" sections with subtotals, extracted `AccountRowView`.
- **KeepoCore (H8):** `DateFormatting.swift` — one Postgres timestamp/date codec replacing all 8 ad-hoc `ISO8601DateFormatter()` sites (`Repositories.swift` ×7, `TransactionFormView.swift:198`). `AmountFormatter.editableString(_:minorUnit:locale:)` as `AmountParser`'s missing inverse, fixing `TransactionFormView.swift:210,224`. Unit-tested.
- **App (H7):** `RefreshCoordinator` + a per-screen-family `DataStore` with `load(force:)`; `.refreshable` on every list; screens key off `.task(id: coordinator.token)` so a write anywhere invalidates everywhere. **This is the seam Phase 11 plugs offline persistence into** — no protocol, no speculative abstraction; `persist`/`restore` are added to the same type once a second behaviour genuinely exists.
- **Verify:** new pgTAP (raw `UPDATE accounts` from `authenticated` denied; stale version → `conflict` + exactly one `sync_conflicts` row + no data change; delete refused with transactions present). Simulator: create three accounts incl. USD + investment, edit, archive, confirm subtotals and cross-tab refresh.

## Phase 7 — Households: access model & viewer-scoped money ⚠️ largest phase

**Goal:** the access model, the viewer's-base-currency rule, and `net_worth(scope)` are correct before anything is built on them.

- **New:** `account_scope` enum; `households`, `household_members` (2-member cap trigger), `household_accounts`, `household_invites` (table only — no RPCs yet, same precedent as `sync_conflicts` in Phase 3). DEFINER `my_household_id()` so `household_members`' own policy can't recurse (Phase 1 lesson, applied pre-emptively). `can_read_account` gains `OR EXISTS (household_accounts JOIN household_members …)`.
- **Retrofits — the phase's real weight:**
  - `accounts_select`/`accounts_insert`/`accounts_update` edited directly (**H3**).
  - The six hardcoded ownership checks re-pointed at `can_write_account` (**H2**).
  - `check_transfer_integrity`'s `count(distinct owner_id) = 1` relaxed to "one owner, or all legs' accounts within one household" (**H10**). `transactions.owner_id` stays the account owner (the composite FK forces it); `created_by` records who entered it, per spec.
  - Both `profiles` joins rewritten to `left join profiles p on p.id = (select auth.uid())` (**H1/H9**). `left`, not inner — a pre-onboarding null `base_currency` must still not drop rows, which Phase 4 explicitly tested for.
  - `set_transaction_derived_columns()`'s category-owner check made household-aware.
- **RPCs:** `create_household()`, `share_account()`, `unshare_account()` (deletes one `household_accounts` row — no copying, ownership never moved, so this is *not* a fork), `net_worth(p_scope account_scope)` — `total` = `me + household` summed from `account_balances_base` under two `WHERE` clauses, never subtraction (**H5**).
- **Client:** new Settings tab with a Household section (create household, per-account share/unshare, member list); shared/private indicator on `AccountRowView`; `created_by` on transaction detail. Plus a **Debug-only dev-identity switcher** in `StubAuthProvider` (env var or launch arg, two fixed emails) — it currently hardcodes one email, so the app can never have two users; ~15 lines that unblock manual household, realtime, and conflict testing for four later phases.
- **Verify:** ~25 pgTAP assertions with two fixture users — private account invisible to the other member (the `SELECT` returns nothing, not filtered in UI); shared readable *and* writable by both; **shared rows still present in `accounts_with_balances`/`transactions_with_details`** (the H9 regression test); two members with different base currencies see the same shared account with different `balance_base`; cross-owner transfer succeeds within a household, rejected across households; `net_worth('total') = net_worth('me') + net_worth('household')`; 2-member cap; no `anon` grants on the four new tables.
- **Split seam if this runs long:** 7a = migration + pgTAP only, zero Swift; 7b = Settings/Household UI + dev switcher. The migration must be green before any client code either way.
- **Known limitation, by design:** the running app has single-member households until Phase 19 (`accept_invite` is what admits a second member). Two-member behaviour is verified by pgTAP, which is better and re-runnable.
- **This phase's exit gate is a machine gate, not a review stop.** Proceed to Phase 8 only if the full pgTAP suite (including the ~25 new assertions) is green against both local and hosted. If anything is red, stop here and report rather than pushing into Phase 8 — but the human review itself happens at the end of Phase 8, where a broken access model is visible as a wrong number rather than a failing assertion.

## Phase 8 — Home dashboard & net worth trajectory

- **Migration:** extract `account_balance_on(p_account_id, p_date)` holding the one ledger/valuation CASE; redefine `account_balances` as a wrapper at `current_date` (**H11**, doc amended). `net_worth_daily` per the doc — materialized per user, per day, **in each account's own currency, never pre-converted** — plus `refresh_net_worth_daily(p_user, p_from, p_to)`; a reading RPC converts each day at `fx_rate_on(day)` so a base-currency change never rewrites history. Same-currency short-circuit in `fx_convert` (**H15**).
- **Client:** `HomeView` — hero net worth, Total/Me/Household picker, Swift Charts trajectory; `BalanceHeaderView`; `KeepoCore/DateBucketing.swift` (weekly ≤ 90d, monthly beyond — derived from span, never a user control; unit-tested). Palette per `app-architecture.md` §5 (income blue, not green; mango stays a UI accent). Gaps filled with real zeroes, one axis only.
- **Also here:** the app-switcher snapshot overlay — this is the first screen whose whole purpose is a large balance.
- **Verify:** pgTAP asserting `account_balances` is byte-identical before/after the refactor; a series spanning a rate gap carries forward; a day with no resolvable rate renders `—`, never `0`; three scopes sum correctly. Simulator: screenshot the app switcher, confirm no balance visible.
- **Human review stop #2.** This is where Phase 7's access model becomes observable: the Home hero metric and the Total/Me/Household picker are the first place a households bug would show up as a wrong or missing number rather than a failing assertion. Review here covers both Phase 7 and Phase 8's own work.

## Phase 9 — Sync Ritual & reconciliations

- **Migration:** `reconciliations`; `categories.system_key` + `unique (owner_id, system_key)` and a seeded `Adjustment` system category in `handle_new_user`/`ensure_user_bootstrap` with a backfill (**H14**); `reconcile_ledger_account()` (adjustment transaction `source='adjustment'` + reconciliation row, atomic, refuses-or-rebases against a stale reconciliation point); `reconcile_valuation_account()` (snapshot + reconciliation row, no adjustment, no transaction review); `account_staleness(subtype, last_verified_at)` with per-subtype thresholds in one CASE.
- The ritual **never stores a balance** — a stored balance would compete with `SUM(amount)` as a second source of truth.
- **Client:** Sync Ritual screen, per-account enter-balance flow, always-visible one-tap unlogged adjustment, `StalenessBadge`, the factual staleness banner above Home's net worth.
- **Verify:** pgTAP — an adjustment moves the balance by exactly the gap; two members reconciling the same shared account hours apart cannot double-count (the second rebases or is refused); a valuation reconciliation writes no transaction; `prevent_default_category_deletion` extended to system categories.
- **Delivered (Phase 9 complete):** Sync Ritual is not a 6th tab — reached from Home's toolbar and its staleness banner, same "not every spec screen is a top-level tab" precedent as Household (Settings). Staleness thresholds (3/7/30 days) are a judgment call — the spec gives no concrete numbers, only "cash drifts in a day, a mortgage does not move in a month." The concurrency guard is `p_expected_last_reconciliation_id` (last-known reconciliation id, not a version column) — refuses on mismatch; there's no separate "rebase" path because the client's natural reload-and-recompute after a conflict already is the rebase. Two follow-up migrations landed same-phase after the first was already pushed to hosted (`p_expected_last_reconciliation_id` needed `default null`; `accounts_sync_status` needed the reconciliation id, not just its timestamp) — see version-logs/phase-9-log.md and lessons-learned.md's new "Optional RPC parameters" section. **Simulator walkthrough was skipped for Phases 9–11 per explicit user instruction** — all three phases' UI is build/lint/pgTAP-verified only until the Phase 11 review stop, when it gets exercised together with the user present.

## Phase 10 — Needs Review inbox & transaction filters

- **Migration:** `needs_review` view with a **stable column contract** (`kind`, `item_id`, `account_id`, `occurred_at`, `title`, `subtitle`, `amount`, `currency`) so Phases 12/14/18/19 each append a `UNION ALL` branch without ever changing the client decoder. Initial branches: `sync_conflicts WHERE resolved_at IS NULL`, reconciliation gaps. `resolve_sync_conflict(p_id)`. Index `sync_conflicts (owner_id, resolved_at)` — currently only a PK exists.
- **Client:** `NeedsReviewRow` (one renderer switching on `kind`), inbox screen, tab badge; transaction filters (account/category/kind/date range/search) riding the existing `(owner_id, occurred_at desc, id desc)` keyset index.
- **Delivered (Phase 10 complete):** Needs Review IS a 6th tab with a badge, per this section's own literal wording — unlike Household/Sync Ritual (Phases 7/9), which were deliberately reached via Settings/Home instead. `needs_review`'s two branches: unresolved `sync_conflicts` (account_id resolved through the polymorphic table_name/row_id pair) and `reconciliation_gap` (every non-archived stale account, not gated by include_in_total — broader than Home's banner on purpose). No pagination UI was built for the transaction filters — "riding the keyset index" was read as an ordering constraint, not a mandate for infinite scroll. See version-logs/phase-10-log.md.
- **Required follow-up, found during Phase 11's live review-stop walkthrough (user-confirmed, not deferred as optional):** `sync_conflicts` only stores the two version *numbers* (`client_version`/`server_version`), never the actual field values the rejected write attempted. Resolving a conflict from Needs Review today means swiping it away with **zero information about what the conflict actually was** — not even a "your version vs. the current one" comparison, since the attempted payload was discarded the instant the version check failed. This needs a real fix, not a UI tweak: `sync_conflicts` needs a new column (e.g. `attempted_payload jsonb`) capturing the rejected write's fields at the moment of conflict, and every versioned write RPC that can produce a conflict (`update_transaction`, `update_transfer`, `update_account`, `archive_account` — anything using the conflict-as-data pattern) needs to populate it instead of just logging the two version integers. `needs_review`'s `sync_conflict` branch and `NeedsReviewRow` then need to actually render a diff (attempted value vs. current saved value) before the user resolves, and tapping a `sync_conflict` row should navigate to see it, not just swipe-to-dismiss blindly. Whichever phase next touches Needs Review or the conflict-as-data RPCs should treat this as required work, not a nice-to-have — the current behavior lets a user discard a real conflict with no way to know what it was.

## Phase 11 — Local data protection & offline outbox

**Goal:** offline writes, encrypted at rest, replayed safely. **Client-only phase.**

- **Rejected: a full local-first mirror.** Answering balance reads locally means reimplementing `account_balances`' two-kind CASE and `fx_convert` in Swift — a direct violation of money rule 3 ("all money arithmetic in SQL, never Swift") and the one-place principle.
- **Built instead:** write-outbox + read-through **payload** cache. The cache stores the *server-computed* decoded rows per query key (`accounts_with_balances`, a page of `transactions_with_details`, the Home summary), written on every successful fetch, replayed cold-start and offline with an "as of HH:mm" marker. Zero arithmetic in Swift — it re-displays numbers Postgres computed. This is the minimum that honors "on-device cache + offline write queue, unsynced writes flagged."
- SwiftData store with `VersionedSchema` + `SchemaMigrationPlan` (the spec's "local cache carries its own schema version and migration path"). `NSFileProtectionCompleteUnlessOpen` on the store file **and** its `-wal`/`-shm` siblings.
- `OutboxItem(id, kind, payloadJSON, expectedVersion, createdAt, attempts, lastError)`, FIFO per row id, keyed by the client-generated UUID that already exists — so a retry is idempotent for free. **Whole-row payloads, never per-field merge.** Drain calls the *same* versioned RPCs, so `conflict = true` already writes the `sync_conflicts` row and version-mismatch-to-Needs-Review needs no new mechanism (this is why Needs Review precedes the outbox). Drain on `scenePhase == .active` and after every successful `signIn()` — "only syncs once a valid session exists" is structural, not a separate check. A transfer's two legs push in one call (`update_transfer` already does).
- `persist`/`restore` added to Phase 6's `DataStore`; unsynced flags; banner for items pending past a threshold.
- **Two calls that must be right first time:** `CaptureIntent` will be declared in the **app target**, not an extension, so the store lives in the app container and needs no App Group (not provisionable on a free personal team). File protection belongs here, not in Phase 17 — it's a property of the store, not the session.
- **Verify:** unit-test the drainer's conflict path against a stubbed client; simulator — airplane mode, create/edit/delete, foreground, confirm exactly one server row per client UUID after a forced double-drain; force a version mismatch via SQL and confirm it lands in Needs Review; assert the protection attribute reads back (real enforcement is device-only).
- **Delivered (Phase 11 migration/client work complete; human review stop below still pending):** outbox scoped to transactions only (create/update/delete, ledger + transfer) — not accounts/categories/households, per this section's own ambiguity about which entity "create/edit/delete" refers to; transactions are the highest-volume write and what Phase 12's capture depends on. Found and fixed a real idempotency gap before the outbox could expose it: `create_transfer` generated both legs' ids server-side, unlike every other write in this codebase — closed via `p_from_id`/`p_to_id` (migration `20260807140000`), so a retried transfer now hits a PK violation (23505) instead of duplicating. Pending items are invisible in every list until drained (no optimistic merge) — the stale-pending banner is the one "unsynced" signal, not a merged UI. `xcodebuild test -only-testing:KeepoTests` (headless, non-interactive) is green — 5 new `OutboxTests` covering conflict-vs-failure-vs-collapse. See version-logs/phase-11-log.md.
- **Human review stop #3.** End of the offline-outbox and file-protection work, before Phase 12's capture depends on it. The migration, pgTAP, build/lint, and automated unit-test legs of this phase's exit gate are complete and green; the manual simulator walkthrough (airplane mode, foreground-drain, forced version mismatch, file-protection read-back) is deliberately deferred to a joint session with the user, per their explicit request — not yet run as of this writing.

## Phase 12 — Apple Pay capture & merchant learning

- **Migration:** `card_mappings`, `merchant_category_map` (RLS-scoped to `owner_id` alone, **never** joined into any household-visible view); `capture_transaction()` inserting `status='pending', source='capture'`, with the per-owner ingestion rate guard the spec requires; three new `needs_review` branches (pending captures, `card_mappings.account_id IS NULL`, low-confidence suggestions).
- **KeepoCore:** `MerchantNormalizer` (`SQ *`, `TST*`, trailing store numbers, LLC suffixes — `merchant_raw` always retained so normalization can improve without re-capture) and `CaptureIdentity.externalId(card:amount:merchant:at:)`. The hash is computed **client-side** because the Intent writes offline; the existing partial unique index on `(owner_id, source, external_id)` is the backstop. Unit-tested against ~30 real-world strings incl. refunds and time-bucket boundaries.
- **App:** `CaptureIntent: AppIntent` in the app target with exactly the trigger's five parameters (`Transaction; Card; Merchant; Amount; Name`). `occurred_at` = the automation's fire time, never sync time. Currency from the **mapped account**; the `$` symbol is a mismatch check only. Local notification → review. Onboarding's Wallet-automation walkthrough. The Intent **only ever writes a pending stub** — never reads a balance or existing transaction.
- **Verify:** unit tests + a Debug "Simulate capture" screen calling the same `perform()` with canned payloads. Shortcuts exists on the simulator and can run an App Intent manually, proving the intent surface and the pending-write path even though the Wallet trigger can't fire there.

## Phase 13 — Ops platform: scheduling, health, alerting

All locally verifiable — `pg_cron 1.6.4`, `pg_net 0.20.4`, `supabase_vault 0.3.1` are installed in the local stack, with `pg_cron`/`pg_net` preloaded.

- `pg_cron` + `pg_net`; `vault.create_secret` for `FX_SYNC_SECRET` and the function URL; **the daily `sync-fx-rates` schedule, overdue since Phase 4**; `ops_events` (RLS on, **no policies**, 30-day prune, ids and codes only — the capture/import parsers will want to log unparseable input and must not).
- **Health derived from data, never job status:** `fx_freshness_check` (newest rate older than N days), `recurring_materialization_check`, capture/import failure counts in 24h. Plus a daily heartbeat, so silence means the alerting itself broke.
- The 400-day FX backfill on first use of a currency and on `base_currency` change — async via `pg_net`, never inline. The 400-day floor makes repeated triggers idempotent.
- Edge Function `alert-operator` → webhook, with per-function rate limiting (spec requires it on every Edge Function and the ingestion path).
- **Verify:** delete recent `fx_rates` rows, assert the health function reports unhealthy; confirm the heartbeat fires; point the webhook at a local listener.

## Phase 14 — Recurring transactions

- `recurring_frequency` enum, `recurring_rules`, `transactions.recurring_rule_id`; `materialize_recurring(p_through date)` made idempotent by reusing `external_id = rule_id|occurrence_date` with `source='recurring'` — the existing partial unique index fits exactly, no new index. Cron job. `next_occurrences(rule, n)` for read-time projection — **upcoming instances are never rows**.
- Store the rule, not future rows; backfill occurrences missed while the job was down. Balance reads already guard `occurred_at <= now()` independently.
- **Client:** recurring list + form; "this one" vs "all future" when editing an instance.
- **Verify:** pgTAP — a backfill after N missed days produces exactly N rows, re-running produces zero; a future-dated materialized row never reaches `account_balances`.

## Phase 15 — Insights & savings rate

`spending_by_category`, `income_expense_series`, `savings_rate` (**excludes transfers and valuation changes** — otherwise moving money into savings reads as an expense and a market dip reads as a bad month), unrealized gain for investments (`latest valuation − SUM(all transfers ever)` — the cost basis is already in the ledger, so this metric is free). Insights screen reusing `DateBucketing` and the §5 palette; category bars carry name + value as text so a user-chosen colour is never the only identity channel.

## Phase 16 — Budgets & FI

- `budgets` storing **`amount` + `currency` as typed, not `amount_base`** (**H13**; doc line 108 amended) — calendar month, no rollover in v1, rendered in the *viewer's* base via `fx_convert`.
- `fi_settings` (`target_annual_spend` nullable → derive from trailing 12mo expenses, `withdrawal_rate` 0.04, `real_return_rate` 0.05); `fi_metrics()` returning FI number, % progress, years-to-FI and Coast FI from **one visible, editable assumption set — never hidden constants**. `accounts.counts_toward_fi` is finally read here.
- **Verify:** pgTAP on savings-rate exclusions and FI math; simulator — change the withdrawal rate, confirm years-to-FI moves immediately.

## Phase 17 — Security, session & Settings

- **KeepoCore:** `KeychainSessionStorage: AuthLocalStorage` injected via `SupabaseClientOptions` (today `makeSupabaseClient` in `SupabaseConfig.swift:24` passes no options, so the refresh token sits in the default Keychain item with default accessibility), backed by `SecAccessControl` with `.biometryCurrentSet` + `.whenUnlockedThisDeviceOnly`. `StepUpAuthenticator.requireFreshSession(reason:)` implemented as a **forced re-read of that Keychain item** — the OS/Secure Enclave enforces it, not an in-app `LAContext` boolean that a patched binary could flip.
- **`AuthProvider` widened by exactly three members**, all implemented by the stub: `restoreSession()` (the biometric-gated cold-start path — `SessionStore.start()` currently conflates it with interactive sign-in), `stepUp(reason:)`, and `capabilities` (so Settings shows "Sign in with Apple" only when the active provider supports it, instead of the UI knowing which provider is live). Deliberately **not** added: nonce plumbing or a credential type — those are `AppleAuthProvider` internals, and inventing them now is the speculative abstraction CLAUDE.md forbids.
- Settings: base-currency change (triggers Phase 13's backfill), appearance, security. Email-OTP recovery identity — works locally against Mailpit on `:54324`; note `config.toml` has `enable_manual_linking = false`, to flip for true identity linking rather than `updateUser(email:)`. MetricKit subscriber (no third-party SDK in a finance app).
- **Verify:** simulator with Features → Face ID → Enrolled; both Matching and Non-matching branches for step-up. `.biometryCurrentSet` invalidation on new-face enrollment has no simulator equivalent → Phase 20 device checklist.

## Phase 18 — CSV import & export

- `csv_import_batches`/`csv_import_candidates`, `import_candidate_status`; `match_import_candidates()` (exact amount, ±3 days, same account); accept/reject RPCs; a `needs_review` branch. **Nothing is ever blind-inserted** — CSV carries no transaction ids, so a blind insert of an overlapping statement duplicates everything.
- Export gated by Phase 17's step-up re-auth immediately before generation, writing an **audit row per export** (account, timestamp, what was exported) — the export can't be undone but it can be detected.
- Also here: the **cross-currency transfer rate-divergence guard** (compare the derived rate against `fx_rates`, warn past N%) if not already landed with transfers — nothing else catches a `320` → `3200` typo, and it corrupts net worth permanently.

## Phase 19 — Household lifecycle: invites, leave, fork, erasure

- `household_invite_status`; `create_invite` (returns a one-time token, stores only its SHA-256 hash), `accept_invite` (2-cap, expiry, single-use, not-self).
- `merge_household_categories()` — one-time 2-way merge at formation: exact matches auto-suggested, near-matches into Needs Review, full history/budget/merchant-learning reassignment. The two-member cap removes the later-joiner case entirely.
- `leave_household()` — one transactional, retry-safe DEFINER RPC: fork a full replica of every shared account/transaction/snapshot to each side under new ids, then delete the `household_members` row. Deleting that row **is** the entire revocation. Fork first, then drain the leaver's outbox against their own replica.
- **The forkable-table registry test** — the mechanical answer to "fork grows with every table added after it." A pgTAP assertion enumerates every `public` table with an `account_id` column via `information_schema.columns` and asserts each appears in a `fork_handled_tables` allowlist that `leave_household()` demonstrably reads. Any future migration adding an `account_id` column without updating the fork turns the suite red. This is what makes landing fork late safe.
- `erase_own_account()` = fork, then scrub the leaving member's PII from their own resulting copy — so the other member's shared history is never corrupted by an erasure.
- Realtime used as a **cache-invalidation signal only** ("something changed on account X → refetch through the normal path"), never a data channel — the payload is discarded, which sidesteps Realtime-RLS correctness entirely.
- Notification seam: a `household_events` row + `notify-household` Edge Function whose APNs call sits behind a no-op transport; surfaced client-side via Needs Review + an in-app banner on next foreground. Phase 20 swaps the transport only.
- **Client:** Household screen, invite share/accept, leave with fork confirmation + step-up. First real two-live-member testing — **on two physical devices**, built and installed from the Mac under the free personal team (7-day provisioning profiles, re-installed weekly as needed; no TestFlight until Phase 20's membership). Notification-seam fallback (in-app banner) stands in for APNs here.
- **Human review stop #4.** Household lifecycle complete and exercised on both physical devices — the app is fully functional per the spec except SIWA/APNs/TestFlight, which is what Phase 20 adds once the membership exists.

## Phase 20 — SIWA, APNs & the device pass

Everything that genuinely requires the paid Apple Developer membership. **Assumed not to start until after the membership is acquired, which may be after this plan's other 19 phases are otherwise done** — this phase is deliberately last and fully pre-seamed by then (`AuthProvider.capabilities`, the notification no-op transport, free-team-tested household lifecycle) so it is a swap-in, not new design work.

- `AppleAuthProvider` conforming to the Phase 17 protocol; `com.apple.developer.applesignin` + push entitlements; `auth.external.apple` configured; APNs swapped in behind Phase 19's transport seam; Apple token revocation on account delete (an App Store requirement for SIWA apps). **`App/Keepo.entitlements`' comment says "restored in Phase 10" — renumber it.**
- Accumulated device-only checklist: does a refund fire the Wallet trigger and how is its amount signed; does an Apple Watch tap fire the paired phone's automation; `.biometryCurrentSet` invalidation on new-face enrollment; real file-protection ciphertext claim; MetricKit payloads in Xcode Organizer; App Group fallback if background-launch-while-locked turns out to be blocked for an in-app `AppIntent`.
- TestFlight build.

---

## Cross-cutting rules for every phase

- **Migration first, then dependent client code — never the reverse.** `supabase gen types swift --local --lang swift --swift-access-control public` after **every** migration (the `--swift-access-control` flag is mandatory now; the CLI's default changed to `internal` and the failure is a build error in the `App` target).
- **`xcodegen generate` after adding any new `.swift` file**, not just after editing `project.yml`.
- Every new RPC parameter a Swift `Optional` can send as `nil` needs `default null` in SQL, or PostgREST returns `PGRST202`.
- Every new table: RLS enabled, explicit `GRANT`s, one policy per command, always `(select auth.uid())`, `UPDATE` policies carry both `USING` and `WITH CHECK`, nothing to `anon`. The Phase 5 schema-wide pgTAP assertions enforce all of this automatically.
- Conflicts and other recoverable conditions are returned **as data**, never raised — a `RAISE` aborts the audit insert in the same transaction.
- A value that cannot be computed renders `—`, never `0`.
- **Per-phase exit gate:** `supabase test db --local` green · `supabase db push` to the hosted project (from Phase 5 onward) · `xcodebuild -scheme Keepo build` clean · `swift test` (KeepoCore) green · `swiftlint` 0 violations · simulator walkthrough of the phase's own flow · `version-logs/phase-N-log.md` written and `lessons-learned.md` updated **before** the next phase starts (CLAUDE.md requires this; Phases 1–2 had to be reconstructed after the fact) · `app-architecture.md` amended where this plan says so · one commit per phase.
- **Four human review stops** (agreed with the user): end of Phase 5, end of Phase 8, end of Phase 11, end of Phase 19. Every other phase boundary still runs the automated exit gate above and gets reported, but doesn't wait for review before the next phase starts. Phase 7 specifically is a machine gate — proceed to 8 only if its suite is green.

## Verification of the whole build

1. `supabase db reset && supabase test db --local` — the full pgTAP suite from a clean database, growing every phase, with the Phase 5 schema-wide assertions covering tables that didn't exist when they were written.
2. `xcodebuild -scheme Keepo build` + `swift test` + `swiftlint` clean at every phase boundary.
3. Simulator (iPhone 17 Pro, iOS 26.5) end-to-end per phase, driven with the iOS Simulator MCP tools. **Coordinates are device points, not screenshot pixels** — screenshots render at ~2.284×; divide before tapping. Verify by screenshotting after the *next* action, not immediately after a tap.
4. `xcrun simctl erase <device>`, not uninstall/reinstall, whenever testing fresh signup after a `supabase db reset` — Keychain survives uninstall and a stale session against a wiped `auth.users` surfaces as `PGRST116`.
5. `NOTIFY pgrst, 'reload schema';` if a freshly-added RPC comes back "could not find the function."
6. Edge Functions: the local edge runtime is currently **stopped** and **Deno is not installed** — both needed to serve or typecheck `sync-fx-rates` and the Phase 13 `alert-operator`.

## Known gaps this plan does not close

- iOS 18.0 remains the declared minimum but is never executed (user's call). Surfaces at TestFlight if it bites.
- Two-live-member household behaviour is pgTAP-verified from Phase 7 but only physical-device-verified from Phase 19, on free-team provisioning that needs weekly re-installation.
- Everything in Phase 20's device checklist (APNs, SIWA, TestFlight, `.biometryCurrentSet` invalidation, real file-protection ciphertext, MetricKit) is unverifiable until the paid membership exists — assumed to be after Phase 19 for planning purposes.

## Change log

- **2026-08-05** — initial version, written after exploring Phases 1–4 and pressure-testing with a Plan agent. Decisions on households timing, hosted-from-Phase-5, review cadence, and doc amendments confirmed with the user.
- **2026-08-05** — Phase 5 complete (pgTAP harness, seed.sql, H12 migration, hosted proof via `PasswordAuthProvider`). One deviation from this plan's original wording, recorded here rather than silently: "diff hosted vs. local generated types" turned out to be blocked by a `supabase gen types --linked` limitation in this environment (its introspection role can run DDL but returns empty column lists for every table/view) — not a schema problem. Verified hosted correctness instead via a real simulator round-trip (sign-in → onboarding → account creation) plus a direct `service_role` REST query against hosted, which is the load-bearing proof this step existed for. See `version-logs/phase-5-log.md` for full detail. No hosted-proof cleanup was done (the test identity/account are harmless and left in place). Ready for human review per this plan's cadence.
