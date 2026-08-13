# Keepo — Local-First Rebuild (Phases L1–L7)

## Why this exists

`keepo-v1-master-plan.md` (Phases 5–20) is complete through Phase 19. Phase 11 of that plan
**explicitly rejected** a local-first mirror, on the grounds that answering balance reads locally
would mean reimplementing the money formulas in Swift — a violation of money rule 3 and of the
one-place principle. It built a payload cache plus a write outbox instead, and Phase 21's
pending-overlay extended that to make balances correct offline.

The user has since made offline operation a **core product requirement**, not a degradation mode:
full CRUD offline, and **charts and analytics that recalculate on-device**, with sync-to-household
being the only thing that requires connectivity.

The pending overlay cannot deliver that. It patches balances; it does not recompute analytics, and
each additional metric costs bespoke delta logic with approximate-or-fall-back semantics.

This plan supersedes Phase 11's rejection. It does so **without** reimplementing money in Swift —
see "The decision that makes this safe" below.

---

## Decisions taken (confirmed with the user, 2026-08-12)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Money becomes integers**, fixed scale 4 (`bigint`, units of 1/10,000) | Int64 arithmetic is bit-identical in Postgres, SQLite and Swift. Removes the single largest divergence risk in a two-implementation system |
| 2 | **Ticket numbers, not timestamps**, for the delta cursor | `now()` is transaction-*start* time, so a slow write can commit behind the client's cursor and be lost permanently and silently. See LH1 |
| 3 | **Unshare forks**, exactly as `leave_household` already does | User's call. Neither side loses history; the survivor keeps an independent replica |
| 4 | **Conflicts stay human-reviewed**; Last-Write-Wins rejected | Already built and tested (version check → `sync_conflicts` → Needs Review). LWW would silently discard a partner's edit |
| 5 | **Own the sync engine; no PowerSync** | PowerSync would save the cursor loop, the apply step and the upload queue — roughly phase L5, one of seven. The schema change, the money port and the read-path rewrite are unavoidable either way. Not worth a third party in the data path of a personal finance app. Revisit only if L5 overruns badly |
| 6 | **SQLite (GRDB) on device, not SwiftData** | Enabled by decision 1. Gives real `SUM`/`GROUP BY`/joins on-device, and lets the money logic stay expressed as SQL on both sides |

---

## The decision that makes this safe

The original objection to local-first was *"the money formulas would have to be rewritten in Swift,
and two implementations will drift."* That objection is correct and it is why decisions 1 and 6
matter more than they look.

With integers and SQLite:

- **Aggregation stays SQL on both sides.** `account_balance_on`, the balance views,
  `spending_by_category`, `savings_rate` and the rest are *ported* from Postgres SQL to SQLite SQL,
  not rewritten as Swift loops. Two SQL implementations that read alike are far easier to keep in
  agreement — and a differential test can prove they agree.
- **Integer arithmetic cannot drift.** `SUM` over `bigint` is exact and identical everywhere.
- **Money rule 3 survives**, with one clarification rather than a waiver: all money arithmetic is
  still in SQL, never Swift. The SQL now runs in two places.

There is exactly **one** exception, and it is deliberate: **FX conversion happens in Swift, not in
SQLite.** SQLite has no exact numeric type, so a conversion intermediate would land in a double —
and for a balance at scale 4 above roughly €100M, the multiply exceeds double's exact-integer range
(2⁵³). Postgres does that intermediate in `numeric` and would disagree.

So: SQLite aggregates in native currency (exact integers), and one shared Swift function converts
each aggregate to the viewer's base currency using exact wide arithmetic (`Int128`, available from
iOS 18 — the project floor). One function, one rounding rule, few call sites, exactly testable.
This is a narrowing of rule 3, written down, not a hole in it.

---

## Money representation

**Every money column becomes `bigint` at a fixed scale of 4** — €12.34 is stored as `123400`.

- The scale is **4 for every currency**, independent of `currencies.minor_unit`. Rule 2's `4` was
  never about display; it was headroom for conversion intermediates. That reasoning is unchanged.
- `currencies.minor_unit` governs **display only**. The display divisor is `10^minor_unit`, never a
  constant 100 — JPY has zero minor digits and would otherwise render ¥1,000 as ¥10.
- **Columns are renamed with an explicit `_e4` suffix** (`amount` → `amount_e4`,
  `opening_balance` → `opening_balance_e4`, …). This is deliberate: renaming makes PostgREST and
  the Swift compiler surface every single call site, instead of silently reinterpreting `12.34` as
  `123400` wherever one was missed.
- **Ratios are not money.** `fi_settings.withdrawal_rate` and `real_return_rate` stay as ratios, and
  the outputs of `savings_rate` / `fi_metrics` are ratios too. The differential test asserts
  **zero tolerance on money outputs** and a small tolerance on ratio outputs.
- **`fx_rates.rate_to_eur` is not migrated — it stays `numeric(20,4)`.** A rate is a conversion
  factor, not an amount of a currency; it has no minor-unit story of its own, and converting it to
  a fixed-point integer would only complicate `fx_convert` for no risk reduction. `fx_convert` reads
  bigint in, does the division/multiplication against the numeric rate, and rounds back to bigint
  at the final step (below) — that boundary is exactly where the exactness guarantee already ends.

The 8 money columns affected: `accounts.opening_balance`, `balance_snapshots.value`,
`budgets.amount`, `csv_import_candidates.amount`, `fi_settings.target_annual_spend`,
`net_worth_daily.balance`, `recurring_rules.amount`, `transactions.amount`.

**Correction from the original review conversation:** `net_worth_daily` was going to be deleted in
this phase; that's wrong. L1 promises the app behaves identically online, and `HomeView`'s
trajectory chart still reads `net_worth_series`, which reads `net_worth_daily`. Deleting it now
would require rebuilding the trajectory query in the same phase as the type migration — two risky
changes at once. `net_worth_daily.balance` is migrated to bigint like every other money column;
the table itself is deleted in **L4**, once the on-device trajectory actually replaces it.

---

## The sync protocol

**Tickets.** A `sync_tickets(domain_id, next_ticket)` table holds one counter per *sync domain* — the
household id if the user is in one, otherwise the user id. Every write takes the next ticket via
`SELECT … FOR UPDATE` on the domain row, and stamps it onto each changed row as `sync_seq bigint`.
The row lock is held until commit, so **a lower ticket is guaranteed to have committed first**. The
client's cursor is a single integer. Rollback gaps are harmless (`where sync_seq > cursor`).

Cost: writes within one household serialize. At a two-member cap this is free.

**Pull.** `pull_changes(p_cursor bigint)` — a Postgres RPC, deliberately **not** an Edge Function.
An RPC runs as the user, so RLS does the filtering for free. An Edge Function would need
`service_role`, bypassing RLS and forcing `can_read_account` to be reimplemented in TypeScript. A
second copy of the *access* model is a worse bug than a second copy of the money model.

Returns changed rows per table, tombstones, `next_cursor`, and the caller's `sync_epoch`.

**Tombstones.** `deleted_at` where it already exists; added where missing on the syncable set.

**The access problem.** Today RLS filters *every read*. Under local-first, **RLS filters only at
download time** — anything already on the phone stays until something tells it to drop. So:

- **Gaining access** (`share_account`, `accept_invite`): the rows already exist with old tickets, so
  a normal pull would never fetch them. The RPC **re-stamps** newly-visible rows with fresh tickets
  and they flow down as ordinary changes. No wipe.
- **Losing access** (`unshare_account`, `leave_household`, `erase_own_account`): fork first so
  nothing is lost, then bump that user's `sync_epoch`. Their client sees the epoch move, drops all
  server-derived rows (**keeping the outbox**) and re-pulls from cursor 0. They end up holding their
  own replica and none of the other member's originals.

A full re-download is most defensible exactly here: rare, user-initiated, and a clean slate is what
you actually want at that moment.

**Syncable set.** accounts · transactions · balance_snapshots · categories · currencies · fx_rates ·
budgets · fi_settings · recurring_rules · card_mappings · merchant_category_map · sync_conflicts ·
households · household_members · household_accounts · own `profiles` row.

**Never synced.** `net_worth_daily` (deleted — it is a cached calculation, and syncing cached
calculations guarantees they disagree with reality), `ops_*`, `export_audit_log`, `csv_import_*`
(server-side workflow), `fork_handled_tables`, `household_events`, `household_invites`.

---

## Hazards this plan exists to close

| # | Hazard | Closed in |
|---|---|---|
| LH1 | `set_updated_at` uses `now()` = transaction *start* time. A write starting 3:04:00 and committing 3:04:04 is invisible to a pull at 3:04:02, and forever below the cursor afterwards. **Silent permanent row loss.** `clock_timestamp()` only narrows the window; no pre-commit stamp can close it, because label order ≠ commit order | L2 (tickets) |
| LH2 | RLS becomes a download-time filter, not a live one. Revoked data persists on-device indefinitely | L2 (epoch) |
| LH3 | Gaining access delivers nothing — the newly-visible rows have old tickets and sit below the client's cursor | L2 (re-stamp) |
| LH4 | `fork_household_accounts` leaves the original merely `archived_at`, transactions untouched. The non-owner's device keeps both the original *and* their fork → double-counted net worth | L2 (epoch on loss) |
| LH5 | Three offline edits to one record each carry `expectedVersion: 5`. The first bumps the server to 6; the second conflicts **against the user's own earlier edit** and lands in Needs Review as a false positive | L5 (coalesce before push) |
| LH6 | `set_account_balance` takes no expected version, so two concurrent balance edits both apply and the first silently vanishes with nothing logged | L2 |
| LH7 | Int64 overflow at the FX multiply: €20M at e4 (2×10¹¹) × a rate at 10⁸ = 2×10¹⁹, past Int64's 9.2×10¹⁸ ceiling — and Swift **traps** on overflow rather than wrapping | L1 (documented ceiling) / L4 (`Int128` in the one conversion function) |
| LH8 | Postgres and SQLite dialects drift; a ported view quietly computes something different | L4 (differential referee test) |
| LH9 | Apple's SQLite build has no `generate_series`, no `LATERAL`, no enums, different date functions | L4 |
| LH10 | Tables missing `deleted_at` / `sync_seq` can't participate in delta sync — `balance_snapshots` in particular, which is what makes valuation balances work | L2 |
| LH11 | A user upgrading the app with items **already queued in the outbox** must not lose them when the store changes from SwiftData to SQLite | L3 |
| LH12 | Forked histories rewrite transfers as plain adjustments (existing behaviour — a transfer's counterpart may not exist on the other side). Unshare-as-fork makes this visible far more often | L2 (surface in the confirmation copy) |

---

## Phase L1 — Money becomes integers

**Server-side only. The app stays online-first and behaves identically. This ships and is verified
on its own, before any sync work starts** — two large changes serialized rather than tangled.

- Migration: the 8 money columns → `bigint`, renamed with `_e4`. `fx_rates.rate_to_eur` stays
  `numeric(20,4)` — it's a rate, not an amount. Data migrated by multiplying by 10⁴ (exact — the
  source is `numeric(20,4)`, so no rounding occurs).
- All ~18 money functions and 5 views updated: every money-typed parameter/column becomes `bigint`;
  ratio outputs (`savings_rate`, `fi_metrics`' percent/years) stay `numeric`, explicitly cast before
  dividing. `fx_convert` takes/returns `bigint`, does the division/multiplication against the
  `numeric` rate, and rounds **half-up to e4 at the final step only, never at intermediates** — this
  is *the* rounding contract, written into `app-architecture.md`, and L4's SQLite/Swift side must
  match it exactly.
- Documented overflow ceiling for the FX path, asserted in pgTAP.
- KeepoCore: `MoneyFormatter` and `AmountParser` move from `Decimal` to `Int64` + `minor_unit`.
  Regenerate types; every screen keeps reading the same views.
- `net_worth_daily`/`refresh_net_worth_daily` stay — migrated to `bigint` like everything else, not
  deleted. Deletion moves to L4 (see correction above).
- **Verify:** all 271 pgTAP assertions green · new assertions for the rounding contract, JPY
  (`minor_unit = 0`) display, and the overflow boundary · **every money value on the seed fixture
  identical before and after** · build/lint/simulator walkthrough.
- **Human review stop.** The whole plan rests on this representation.

## Phase L2 — Sync primitives on the server

- `sync_tickets` + `next_ticket(domain)` with `FOR UPDATE`; `sync_seq bigint` on every syncable
  table via trigger; backfill existing rows.
- `deleted_at` added where missing on the syncable set (`balance_snapshots` first).
- `pull_changes(p_cursor)` RPC, security invoker.
- `sync_epoch` on `profiles`; bumped on `leave_household`, `erase_own_account`, `accept_invite`
  (domain change), and for the losing member on `unshare_account`.
- `share_account` / `accept_invite` re-stamp tickets on newly-visible rows.
- `unshare_account` → extract the per-account body of `fork_household_accounts` into a shared
  function and call it, then bump the other member's epoch.
- `set_account_balance` gains `p_expected_version` (LH6).
- **Verify:** pgTAP for pull/epoch/re-stamp/fork-on-unshare · plus a **two-session shell test** for
  the ticket ordering guarantee, which pgTAP cannot express from inside one transaction · hosted push.

**Shipped 2026-08-16 — three corrections found while building/testing, all detailed in
`version-logs/phase-L2-log.md`:**

1. **`pull_changes` needs TWO cursors, not one.** `currencies`/`fx_rates` share one global domain
   (no owner of their own) whose ticket counter accumulates across every user and grows far faster
   than any single household's. A single scalar `next_cursor` taking the max across every table
   (global + per-domain) starves the slow-growing domain: a freshly re-stamped row there can sit at
   a low ticket while the cursor is already past a much higher global-domain value, so
   `sync_seq > cursor` is false forever. `pull_changes(p_cursor, p_global_cursor)` — domain-scoped
   tables compare against the first, `currencies`/`fx_rates` against the second.
2. **`set_account_balance`'s `p_expected_version` (LH6) was already added during L1**, not L2 — no
   further migration work needed here beyond confirming it via pgTAP.
3. **`household_members`/`household_accounts` needed converting from hard `DELETE` to soft-delete**
   (not called out explicitly in the original L2 bullets above, but required by "re-stamp on gain /
   epoch-bump on loss" to actually work): a hard delete gives the remaining household member's next
   pull nothing to learn a departure from. `deleted_at` added to both; `my_household_id()`/
   `can_read_account()`/the `accounts` H3-exception policies/`enforce_household_member_cap()` all
   updated to filter it; `accept_invite` reactivates a tombstoned row on rejoin instead of colliding
   on the PK.

## Phase L3 — On-device store: GRDB

- GRDB dependency; SQLite schema mirroring the syncable set, integers throughout.
- File protection on `.sqlite` **and** its `-wal`/`-shm` siblings (the Phase 11 pattern).
- **Outbox migration (LH11):** read the existing SwiftData `OutboxItem` rows and re-insert them into
  the new store. Do not drop them, and do not require the user to be online to upgrade.
- Keep the existing Outbox *logic* — kinds, payloads, replay, conflict handling. Port storage only.
- `ValueObservation` → SwiftUI, replacing SwiftData's `@Query`.
- **Verify:** unit tests for the store and the outbox migration path, including "upgrade with three
  queued items while offline".

**Shipped 2026-08-16 — one correction found while building:** `ValueObservation` → SwiftUI was not
built. Investigated first (per this plan's own reuse-before-writing discipline): a repo-wide grep
found zero `@Query` usages anywhere in the app target, so there was nothing for `ValueObservation` to
replace. `Outbox` already refreshes its `@Observable` properties synchronously after every write and
is the only writer to `outbox_items` today — there's no second writer for a SwiftUI view to need to
observe independently until L5's pull loop starts writing into the syncable-table mirror. Revisit this
bullet in L5/L6 once that second writer exists; wiring it now would have been unmotivated. See
`version-logs/phase-L3-log.md` Findings #4 for the full reasoning, and its Findings #3 for a real
schema-level bug found and fixed along the way (a `TEXT`-affinity column silently rounding a stored
timestamp forward, caught via a flaking unit test rather than by inspection).

## Phase L4 — Port the money layer to SQLite, and the referee

The make-or-break phase.

- Port to SQLite SQL: `account_balance_on`, the three balance views, `net_worth` by scope, the net
  worth series (rebuilt directly off `account_balance_on` per day — no `net_worth_daily` equivalent
  on-device, since a local store can afford to recompute rather than cache), `spending_by_category`,
  `income_expense_series`, `savings_rate`, `unrealized_gain`, `budget_progress`, `fi_metrics`,
  `needs_review`.
- **Delete `net_worth_daily`, `refresh_net_worth_daily` and its cron job on the server** (moved here
  from L1 — see the correction in "Money representation"). The on-device trajectory now supersedes
  it; nothing server-side reads it once `HomeView` moves to the local query in L6.
- Dialect work (LH9): recursive CTEs in place of `generate_series`; correlated subqueries in place
  of `LATERAL`; `strftime`/`date` in place of Postgres date functions; text + CHECK in place of
  enums. Window functions and `FILTER` are available on iOS 18's SQLite.
- **FX conversion is not ported.** One shared Swift function, exact wide arithmetic (`Int128`),
  implementing the L1 rounding contract, called at the display boundary on already-aggregated
  native-currency figures.
- **The referee test:** one fixture loaded into both Postgres and SQLite; assert every money output
  identical **to the unit**, every ratio output within a stated tolerance. The Postgres views stay
  in the repo purely as this oracle — nothing in the app calls them after L6.
- **Verify:** referee green across the full fixture, including two members with different base
  currencies, a missing FX rate, a valuation account, and a JPY account.
- **Human review stop.** If the referee cannot be made green, the architecture is wrong and we stop
  here rather than building on it.

**Shipped 2026-08-13 — the referee is green; two scope corrections found while building, detailed in
`version-logs/phase-L4-log.md`:**
1. **`net_worth_daily`/`refresh_net_worth_daily` deletion deferred to L6, not done here.** This
   phase's own bullet above says "nothing server-side reads it once `HomeView` moves to the local
   query in L6" — but the app is still online-first through L4 (per L3's own architecture note), and
   `HomeView`'s trajectory today calls `net_worth_series`, which still reads `net_worth_daily`
   server-side. Dropping it now would break the live, shipping Home screen for no benefit, since
   nothing local reads the new SQLite money layer until L6 either. Deferred to land in the same L6
   commit that switches `HomeView` over — the "moved here from L1" correction this bullet documents
   turns out to still be one step early.
2. **`needs_review`'s `csv_import_candidate` branch not ported** — `csv_import_candidates`/
   `csv_import_batches` were never added to L3's 16-table syncable schema (they're not in
   `app-architecture.md`'s list), so there is no local table for this branch to read. Not a gap
   introduced here; the local `needs_review` in `LocalMoneyQueries.swift` covers the three branches
   whose source tables exist locally (`sync_conflicts`, pending captures, ambiguous `card_mappings`).
   Revisit if CSV import ever needs a local table (out of scope for the current plan phases).
3. **Dialect work turned out to need none of the specific techniques anticipated** (recursive CTEs,
   correlated subqueries, `strftime`/`date`, text+CHECK) — the actual money functions decompose
   cleanly into plain `SELECT`/`SUM`/`WHERE` against the local mirror plus Swift-side reduction for
   FX (see app-architecture.md's new L4 section), so `generate_series`/`LATERAL`/Postgres-specific
   date functions never came up as porting obstacles in practice.

## Phase L5 — Sync engine on device

- Pull loop: cursor → apply upserts and tombstones in one transaction → advance cursor.
- Epoch mismatch → drop server-derived tables, keep the outbox, re-pull from 0.
- Push loop: **coalesce queued mutations per record id** (LH5), then FIFO through the existing RPCs.
- Triggers: app becomes active · network regained · after sign-in · Realtime nudge (which reduces to
  "the ticket moved, go pull" — exactly how Phase 19 already uses Realtime).
- Conflicts unchanged: version rejected → `sync_conflicts` → Needs Review.

**Shipped 2026-08-13 — the referee-adjacent precision bug caught before it shipped, and one deferred
trigger, both detailed in `version-logs/phase-L5-log.md`:**
1. **`pull_changes` had a real precision bug, fixed before any client code shipped against it.**
   `to_jsonb(row)` renders a Postgres `numeric` column as a JSON *number* — `fx_rates.rate_to_eur` and
   `fi_settings.withdrawal_rate`/`real_return_rate` (the only three `numeric` columns left in the
   syncable set) would have round-tripped through a Swift binary float before landing back in the
   local `TEXT` decimal column, silently reintroducing the exact imprecision L1 eliminated and L4's
   referee verified was gone. Fixed with a follow-up migration
   (`20260817100000_pull_changes_numeric_precision.sql`) overriding just those three keys with an
   explicit `::text` cast, plus two new pgTAP assertions.
2. **The Realtime nudge is deferred, not built — the plan's own claim that Phase 19 "already uses
   Realtime" turned out to be wrong.** Investigated before assuming there was something to reuse: a
   repo-wide grep for `RealtimeChannel`/`postgresChange` found zero hits outside the SDK itself.
   Phase 19's household-events mechanism is plain polling
   (`HouseholdViewLoader`/`HouseholdRepository.fetchEvents`, called each time that screen loads), not
   a subscription. Building this app's first-ever Realtime channel usage is a genuinely separate,
   untested feature surface, not a two-line reuse — deferred rather than built speculatively under
   this phase's already-large scope. The three lifecycle triggers that *were* built (app active,
   network regained, every sign-in path) already cover pull correctness; only instant cross-device
   staleness (seeing a household partner's edit before the next foreground/reconnect) is what's
   missing. Revisit if that latency becomes a real product complaint.
3. **`needs_review` was intentionally not re-ported here** — L4 already covers why (the local schema
   has no `csv_import_candidates` table); L5 only had to make sure the sync engine doesn't need one
   either, which it doesn't (`sync_conflicts`/pending captures/`card_mappings` all pull and apply like
   every other table).

## Phase L6 — Read-path rewrite

- Every screen moves from PostgREST view types to local queries (~20 screens across 66 App files).
- Delete: `PendingOverlay`, `PendingOverlayAdapter`, `LocalFxConvert`, `PayloadCache`,
  `FxRateCache`, `CurrencyCache`, and `DataStore`'s network path. Two answers to "what is my balance
  offline" would recreate the exact divergence problem this plan exists to remove.
- `CaptureIntent` writes locally and resolves its card mapping locally — offline Apple Pay capture
  finally works end to end, which the current architecture cannot do.

## Phase L7 — Verification and cutover

- Referee suite green; full pgTAP green; build/lint/unit clean.
- Airplane-mode walkthrough: create, edit, delete, archive across transactions, accounts and
  categories; confirm every chart recalculates.
- Two physical devices: share, unshare-with-fork, leave, concurrent edit → Needs Review.
- Upgrade path: install over the previous build with queued outbox items, offline.
- Access-change matrix: gain and loss, in both directions.

---

## Doc amendments

| Doc | Change | Phase |
|---|---|---|
| `CLAUDE.md` money rule 2 | `numeric(20,4)` → `bigint` at fixed scale 4, `_e4` suffix; `currencies.minor_unit` governs display only | L1 |
| `CLAUDE.md` money rule 3 | Clarified, **not waived**: all money arithmetic stays in SQL — Postgres server-side, SQLite on-device, the same logic ported and differentially tested. Single documented exception: FX conversion, one shared Swift function with exact wide arithmetic | L4 |
| `CLAUDE.md` money rules 1, 5, 6 | Unchanged and still binding | — |
| `app-architecture.md` | New section: the sync protocol (tickets, epoch, fork-on-unshare), the rounding contract, and **"RLS filters at download time, not at read time"** | L2, L4 |
| `app-architecture.md` line ~120 | `net_worth_daily` removed | L4 |
| `keepo-v1-master-plan.md` | Phase 11's "rejected: a full local-first mirror" annotated with a pointer here and the reason it was revisited | L1 |

---

## Open questions

1. **FX rate precision.** Migrating at scale 4 preserves today's results exactly. Raising to scale 8
   is a genuine accuracy improvement but changes every converted figure. Recommend: ship L1 at
   parity, decide separately.
2. **Currency and FX table size.** `fx_rates` is append-only and grows daily per currency. A full
   local mirror is fine now; if it ever gets large, the pull can be scoped to the currencies the
   user actually holds. Not a v1 concern.
3. **`csv_import_*` stays server-side**, so CSV import will require connectivity. Assumed acceptable
   — flag if not.

---

## Change log

- **2026-08-12** — written after an architecture review with the user. Six decisions recorded above.
  The key finding: choosing integers plus SQLite means money rule 3 is *narrowed* rather than
  waived, because the aggregation logic stays SQL on both sides instead of being rewritten as Swift.
  That materially lowers the risk that made Phase 11 reject local-first in the first place.
