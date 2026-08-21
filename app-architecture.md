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
| Accounts & Multi-Currency | `accounts`, `currencies` |
| FX Rate History | `fx_rates`, `fx_rate_on()`, `sync-fx-rates` Edge Function |
| Transaction Entry & Automation | `transactions`, `recurring_rules`, `card_mappings`, capture pipeline (§4) |
| Household & Sharing | `households`, `household_members`, `household_accounts`, `household_invites` |
| Sync Ritual | `reconciliations`, adjustment transactions, valuation snapshots |
| Needs Review | `needs_review` view (§3) |
| Home | `net_worth()`, `account_balances`, `net_worth_daily`, Needs Review notifications panel |
| Operations & Monitoring | `ops_events`, health-check functions, alerting Edge Function |

---

## 2. Frontend — Screens & Shared Components

### Screens (SwiftUI, native navigation — no routes/URLs)

| Screen | Notes |
|---|---|
| Onboarding | Base currency → first account → opening balance → optional Wallet automation walkthrough |
| Home | Tab labeled "Home" with the globe icon. Body is a **widget dashboard** the user arranges themselves (see "Home dashboard" below) — the top-left "more options" (•••) button and top-right bell are unchanged from before the dashboard: both open a self-owned SwiftUI overlay card (scale+fade from the button's corner, not a system `.popover` — that gave no reliable hook to keep a curtain in sync with its outside-tap dismiss) with a shared dark-curtain overlay behind whichever is open, dismissed by picking a row or tapping the curtain, both going through the same state; the ••• card is the Total/Personal/Household scope picker — each row keeps its identity icon (globe/person/person.2) and adds a trailing checkmark when selected, rather than swapping the icon out |
| Accounts | List, add/edit, icon + colour picker (`IconCatalogView`, shared with Categories), archive (with confirmation). New accounts pick a kind up front via `AccountKindPicker` (Everyday vs. Investment); the list renders both groups as a **single `ForEach` over a flat `[Item]` in which the group headers are themselves rows**, so one `.onMove` implements all three drag behaviours — reorder within a group, and drag across a header to convert `kind` in either direction (an account's kind is simply the kind of the nearest header above it once the move lands). Both headers always render, including for an empty group, or the conversion gesture would be undiscoverable, and headers are deliberately **not** `.moveDisabled` — a non-movable row makes its own index a dead zone in UIKit's drop targeting, which silently made "first row of the other group" unreachable in one direction and refused the drop outright in the other. A header drag is ignored in `handleMove` instead. An investment account carries a permanent `InvestmentBadge`, placed under the name rather than beside it — `kind` is otherwise purely presentational, both kinds behave identically. Archived accounts collapse to an "Archived (N)" link into a separate screen (My Profile → Data & Privacy → Data) with unarchive and non-reversible delete; archived accounts (and their transactions) never count toward net worth |
| Transaction entry | One view, three kinds via `KindTabBar` (a background-free underlined tab bar, not a segmented control — a mode switch, not a setting) over a single card. Body is `TransactionDetailCard`: for expense/income an account+amount block plus a category tile; for a transfer, two of the same block with a flow rail down the left showing the direction of travel. Used for capture review, manual add, and edit; edit mode has an explicit centred red Delete alongside the list's swipe-to-delete. A grey provenance line answers "where did this come from, and can it repeat?" in three mutually exclusive states: captured, already recurring, or "Make recurring" (which pushes a `RecurringRuleFormView` seeded from what is already on screen) |
| Transactions | Single day-grouped list with a day/week/month/year/custom period picker up top; toolbar has a search button (on-demand full-width search bar) and a "+". Amounts render in **ledger style** — an outflow drops its minus sign, an inflow gains an explicit `+` in green (`MoneySignStyle.ledger`; the stored value is never re-signed, money rule 1). A second line under the category carries the account name plus glyph-only provenance: a chip icon for an automatic capture, recurring arrows for an instance of a rule |
| Categories | Expense/income sections; the two default "Other" rows have no delete affordance. The edit form mirrors `AccountFormView`'s shape exactly — big tappable icon over `IconCatalogView`, an unlabelled name field, one centred red destructive action |
| Sync Ritual | Per-account freshness, enter-balance flow, unlogged adjustment |
| Needs Review | One inbox, one row type per §3's `needs_review` view — surfaced from Home's bell, not its own tab |
| Household | Members, invite, leave (with the fork confirmation) |
| Import | CSV upload → match-and-review |
| Settings | Base currency, appearance, security (export, delete), household |

**Home dashboard.** A 2-column grid of widgets the user adds, removes, and drags into place — absolute `(row, column)` placement (`DashboardArrangement`, `KeepoCore`), not flow-packed, so a lone 1×1 can sit in the right column with the left deliberately blank, and a hole between two wide tiles is preserved rather than auto-filled. **A grid row is half a widget** (`DashboardLayout.rowsPerWidget`), sized so two rows measure exactly one column width: every widget is two rows tall and therefore still square (1×1) or full-width-square (1×2), and the split exists only so a one-row tile — a spacer — can open half a widget of breathing room, which a full-height row could not express without leaving a widget-sized hole. Expanded sizes are always full width (2×2, or 3×2 for Cashflow's category breakdown, counted in widget-heights) — one tile expands at a time, and edit mode (long-press, jiggle, minus badges) always compacts back to base sizes first. Dashboards saved before the split decode into overlapping positions and are repaired by normalization into the layout they had, which `DashboardArrangementTests` pins.

**Two ways a widget arrives, two mechanisms.** Rearranging a tile already on the grid is a SwiftUI gesture (a short press with a generous distance tolerance, then a drag, reading the grid's coordinate space). Dragging one *out of the catalogue* is a **system drag session** (`.onDrag` + a `DropDelegate` on the canvas): a SwiftUI `DragGesture` on a scrolling row wins arbitration against the enclosing `ScrollView` and stops the catalogue scrolling entirely, however it is attached, while a drag session coexists with the pan and is carried by the window — so the panel can dismiss without taking the widget with it. Both converge on `previewDrop(at:)`, which reflows the same preview arrangement, and on `DashboardArrangement.insert`/`move`.

An arriving widget draws as a **grey landing slot** (`DashboardLandingSlot`), never as itself: the finger is already carrying a full rendering of it, and drawing a second one on real data beside the sample-data card in hand made the two disagree on every figure. The slot answers *where*; the card in hand answers *what*. Its cell comes from the **finger**, not from a corner derived from it — a drag session lifts its preview under the point actually pressed, so a widget grabbed near its edge is carried offset from the touch, and working back to a top-left corner put the slot a column away from where the user was pointing. `previewDrop` also clamps the target row to one past the last occupied one, since every row below that is empty and normalization would close it, stranding the slot far above the finger. Persisted device-local (`DashboardStore`, `UserDefaults`, JSON) — deliberately not synced, since nothing on it is financial data the way an account or transaction is; every widget still reads through the scope filter (Total/Personal/Household) like every other financial screen. One `DashboardDataLoader.load()` computes every mounted widget's figures in a single `dbQueue.read`; a widget nobody has added costs nothing. Widgets: **Net Worth** (existing net-worth card, now a tile), **Upcoming Bills** (`RecurrenceSchedule` projects `recurring_rules` occurrences client-side — the local counterpart to `next_occurrences()`), **Currency Exposure** (a donut of balances by currency, expanding to one currency's rate history against the base currency), **Cashflow** (money in/out for the last *complete* month or year — `CashflowPeriod` deliberately never shows a partial period — expanding to an in/out donut, then to one direction's category breakdown), **Investing Ratio** (invested ÷ net worth, where invested is the sum of `kind = 'investment'` account balances — the one place `kind` is read for a money figure; it classifies which accounts to sum, it does not change how any balance is computed, per CLAUDE.md's money rule 1). All new widget queries are client-side derivations of already-refereed L4 primitives (`accountBalance`, `LocalMoneyConversion.convert`), not fresh SQL of their own — see `LocalDashboardQueries`.

**The bar under the grid, and cancelling an add.** One slot under the grid, full width and **one row** — half a widget — tall, showing whichever end of an *add* the user is currently at: the way into the catalogue, and, while a widget is being carried, a red trash bar (`DashboardTrashSlot`) that discards it. Sharing one slot rather than adding a second control is load-bearing, not tidiness: a trash bar appearing beside or under the add button would grow the content and slide the grid out from under a mid-drag finger. Dropping there is a *cancel*, not a deletion — the store is never written during a drag, so the previewed arrangement is thrown away and the stored one simply stands — and the drop is still **accepted** (`performDrop` returns `true`), because a refused drop flies the carried preview back to a catalogue that is no longer on screen.

The bar sits at the end of the scrolling content, so anything that changes the grid's height moves it: previewing the widget into the last row makes the grid a whole widget taller, previewing it into a hole makes it no taller at all. Instrumented, a finger holding still on the bar watched it climb past and cancel its own target. So while a widget is in hand the content is held at the height it would have at its *tallest* — the widget's own height, less however much the preview is already using, reserved as empty space (`carriedReserve`) — and the grid reflows under the drag without the bar hearing about it. The hit region is deliberately lopsided to match: a row of overshoot below and to the sides, a little hysteresis above the top edge *once the trash is already the target*, and nothing above it on approach, because that strip is where "put it at the end of the dashboard" lands. Over the trash the landing slot fades rather than disappearing, and the preview freezes — removing the slot would shorten the grid and start the same feedback loop.

Insights (category breakdowns, savings rate, FI metrics) and its backing `spending_by_category`/`income_expense_series`/`savings_rate`/`unrealized_gain`/`fi_metrics` RPCs and the `fi_settings` table were removed pre-launch (not shipped in v1) — see the version log for the removal migration. Budgets is unrelated and unaffected.

**Transaction entry** mirrors the retired web spec's design intent even though the platform changed: one `TransactionFormView`, three kinds (expense/income/transfer), used for both create and edit. The kind is locked once a transaction exists — changing kind is delete-and-recreate, never an in-place mutation, because a transfer's two-leg shape and a ledger entry's single-leg shape aren't interchangeable in place.

### Shared components (one place each, per CLAUDE.md's Engineering Principles)

| Component | Location | Used by |
|---|---|---|
| `MoneyFormatter`, `Decimal(supabaseNumeric:)` | `KeepoCore` (exists) | every screen showing an amount |
| `CurrencyConversionLabel` | `KeepoCore` / SwiftUI view | Home, Accounts, Transactions, Sync Ritual banners — renders `—` when `has_missing_rate` |
| Date bucketing (weekly/monthly by span) | `KeepoCore` | Home trajectory chart |
| `TransactionFormView` | App | manual add, capture review, edit |
| `AccountRowView`, `BalanceHeaderView` | App | Home, Accounts, Sync Ritual |
| `AmountField` | App | the one large money input — Account balance and every `TransactionDetailContainer`. Whole part oversized, fraction smaller, grey placeholder derived from the currency's `minor_unit`. The styled split is drawn only while unfocused, over a full-size `TextField` that always defines the layout; focusing swaps to a plain uniform field. Overlaying styled text on a transparent field was tried and rejected — the two lay out at different widths, so the caret drifts away from the drawn digits. A **balance** passes `signed: true` to `AmountFormatter.editableString` and an overdrawn account renders `-$840.00` (minus ahead of the symbol); a **transaction amount** stays unsigned, because there the sign belongs to the kind |
| `IconCatalogView` + `IconLibrary` | App / `KeepoCore` | Accounts and Categories both. One grouped catalogue and one swatch row (`CategoryAppearance.palette` plus device-local custom colours), replacing the two divergent inline icon grids the two forms used to carry. A stored icon predating the catalogue surfaces as its own leading "Current" family so the grid's highlight never silently means nothing |
| `TransactionDetailCard` / `TransactionDetailContainer` | App | the transaction form's three shapes. Expense and income are structurally identical; a transfer is two of the same container, which is what keeps the two legs looking like peers |
| `AccountPickerRow`, `CategoryPickerRow` | App | the row that *displays* the value is the row that *changes* it, with identical layout in both states — a label-left/grey-value-right `Picker` would have made the account you are looking at and the account you are choosing look nothing alike |
| `PressableRowButtonStyle` (`.pressableRow` / `.pressableCard`) | App | every tappable row and card. Replaces `.onTapGesture`, which loses races with a `List`'s scroll recogniser (the "first tap after scrolling does nothing" bug) and draws no press state at all |
| `CreditCardTile` + `MappedCardSheet` | App | the Account form's card strip and its popup. Card-proportioned (ISO/IEC 7810 ID-1, 1.586:1) on purpose — the resemblance is the affordance. Replaced three screens (`MappedCardsView`, `AddCardMappingSheet`, `CardMappingDetailSheet`) that between them took two levels of navigation to rename one string |
| `DestructiveActionButton`, `IconPickerButton`, `SharedWithHouseholdIcon`, `FormCard`, `KindTabBar` | App | the redesigned forms' shared primitives (`FormPrimitives.swift`, `KindTabBar.swift`) |
| `FormatterCache` | `KeepoCore` | `MoneyFormatter`/`AmountParser`/`AmountFormatter`. `NumberFormatter()` was being constructed on **every** call — per money label, per render pass, per keystroke — which is the actual mechanism behind "the UI feels laggy", not the SQLite reads |
| `StalenessBadge` | App | Sync Ritual row, Home banner |
| `NeedsReviewRow` | App | Needs Review inbox — one renderer switching on item `kind` |
| `AuthProvider` protocol | App | login, session refresh, step-up re-auth |

`AuthProvider` is the seam named in the build plan: `StubAuthProvider` (fixed dev user id, locally-minted JWT) now, `AppleAuthProvider` (real SIWA) once the paid Apple Developer account exists. Nothing else in the app depends on which is active.

---

## 3. Backend — Schema, Indexes, Auth

### Enums (money rule 4 — enums, not `text` + `CHECK`)

`account_kind` (regular, investment) · `category_kind` (expense, income) · `transaction_source` (manual, capture, recurring, adjustment, csv_import) · `transaction_status` (pending, confirmed) · `fx_source` (ecb) · `household_invite_status` (pending, accepted, revoked, expired) · `import_candidate_status` (pending, accepted, rejected) · `recurring_frequency` (weekly, monthly, yearly)

`transaction_kind` (expense, income, transfer) is **not** an input enum, and **not a stored `GENERATED ALWAYS` column either** — that was the original plan, revised once building it: generation expressions require an `IMMUTABLE` cast, and `enum_in` is only `STABLE` (confirmed via `pg_proc` before writing the migration). Instead `kind` is derived in `transactions_with_details` (§ below) from `transfer_group_id IS NOT NULL` and the sign of `amount` — same can-never-disagree guarantee, no stored denormalization, no fragile generation expression.

### Tables

- **`currencies`** — reference table, the ECB/Frankfurter set (~30 + EUR). `code` (PK), `minor_unit`. The currency picker (client) can only offer rows from this table — an unpriceable account can never be created.
- **`profiles`** — `id` (= `auth.uid()`), `base_currency` (FK `currencies`), `onboarded_at`.
- **`accounts`** — `id` (client-generated UUID), `owner_id`, `created_by`, `kind` (`account_kind` — purely presentational, drives the "Investment" badge only, nothing else), `name`, `currency` (FK `currencies`), `opening_balance`, `opening_balance_at`, `include_in_total`, `icon`, `color` (presentational only, same pattern as `categories`), `archived_at`, `sort_order` (int, presentational — the user's own drag arrangement on the Accounts list; unique only WITHIN a `kind` group, so any flat query over accounts must order by `kind` first or the two groups interleave), `version`, `deleted_at`, timestamps. `UNIQUE (id, currency)` — the anchor for a composite FK below.
- **`balance_snapshots`** — **removed** (the account-kind unification migration, `20260902100000_unify_account_kinds.sql`). Every account's balance is now `opening_balance + SUM(amount)`, so there is no second balance source to snapshot.
- **`categories`** — `id`, `owner_id`, `kind` (`category_kind`), `name`, `is_default`, `deleted_at`. Exactly one `is_default` row per `(owner_id, kind)`. `UNIQUE (id, kind)` for the composite FK below.
- **`merchant_category_map`** — `owner_id`, `merchant_pattern`, `category_id`, `updated_at`. PK `(owner_id, merchant_pattern)`. RLS-scoped to `owner_id` alone, **never** joined into any household-visible view (spec: merchant learning is per-user, not per-household).
- **`transactions`** — `id` (client-generated UUID), `owner_id`, `created_by`, `account_id` (plain FK to `accounts(id)` — the `account_kind` mirror column and its composite FK were removed alongside `balance_snapshots`, since every account now accepts every transaction kind), `category_id` (null for transfers), `category_kind` (mirrors `category_id`'s kind, set by trigger — see composite FKs), `amount` (`numeric(20,4)`, signed), `currency`, `occurred_at`, `merchant_raw`, `merchant_normalized`, `transfer_group_id` (null unless a transfer leg), `source` (`transaction_source`), `status` (`transaction_status`, default `confirmed`; `capture`-sourced rows start `pending`), `external_id` (nullable, idempotency — see §4), `version`, `deleted_at`, timestamps. Three CHECK constraints do the rest of the enforcement declaratively: `amount <> 0`; exactly one of `transfer_group_id`/`category_id` is set; sign agrees with `category_kind` (expense negative, income positive — this is what lets expense/income be a **plain insert**, no RPC, with a wrong sign structurally impossible).
- **`recurring_rules`** — `id`, `owner_id`, `account_id`, `category_id`, `amount`, `currency`, `frequency` (`recurring_frequency`), `next_due_at`, `last_materialized_at`, `active`.
- **`fx_rates`** — `currency` (FK `currencies`), `rate_date`, `rate_to_eur`, `source` (`fx_source`), `fetched_at`. PK `(currency, rate_date)`. **Upserted, not blind-inserted** — a later `fetched_at` for the same `(currency, rate_date)` wins, which is how an ECB revision to a recent value gets picked up. This is why `fx_rates` is described as "append-only" in the money rules despite the upsert: no row is ever destructively rewritten by application code outside this one conflict-resolution rule, and old converted figures stay reproducible because the key never silently vanishes.
- **`reconciliations`** — `id`, `account_id`, `as_of`, `entered_balance`, `computed_balance`, `adjustment_txn_id` (nullable, ledger accounts), `snapshot_id` (nullable, valuation accounts), `created_by`, `created_at`. What renders "verified X ago."
- **`households`** — `id`, `created_at`.
- **`household_members`** — `household_id`, `user_id`, `joined_at`, `deleted_at` (L2). PK `(household_id, user_id)`. Trigger caps membership at 2, counting only `deleted_at is null` rows. A departure (`leave_household`/`erase_own_account`) soft-deletes rather than hard-deletes, so a rejoin reactivates the same row (`accept_invite`'s `ON CONFLICT ... DO UPDATE`) instead of colliding on the PK, and the remaining member's next pull still sees the departure as a tombstone rather than a row that silently vanished.
- **`household_accounts`** — `household_id`, `account_id`, `shared_at`, `deleted_at` (L2). PK `(household_id, account_id)`. Same soft-delete reasoning as `household_members` — `unshare_account` sets `deleted_at`, never a hard `DELETE`.
- **`household_invites`** — `id`, `household_id`, `invited_by`, `token_hash`, `status` (`household_invite_status`), `expires_at`, `created_at`. Single-use, expiring, revocable per the parked security design.
- **`sync_conflicts`** — `id`, `table_name`, `row_id`, `owner_id`, `client_version`, `server_version`, `created_at`, `resolved_at`. Populated when a push's `version` doesn't match — feeds Needs Review.
- **`card_mappings`** — `id` (uuid, PK — every other Needs Review item source has one to hand back as `item_id`; amended from this doc's original `(owner_id, card_identifier)` composite PK once Phase 12 actually wired it into Needs Review), `owner_id`, `card_identifier` (raw Shortcuts card string), `account_id` (nullable — null means unmapped, routes to Needs Review), `source` (`card_mapping_source`: `manual` when the user named the card themselves via `map_card`, `automatic` when the capture pipeline linked it for them via `link_card_to_account`; presentational only, decided by whoever first attaches a real `account_id` and never rewritten afterwards), `unique (owner_id, card_identifier)`.
- **`csv_import_batches`** / **`csv_import_candidates`** — batch: `id`, `owner_id`, `account_id`, `filename`, `created_at`. candidate: `batch_id`, `raw_row` (jsonb), `matched_transaction_id` (nullable), `status` (`import_candidate_status`).
- **`budgets`** — `id`, `owner_id`, `category_id` (nullable = overall), `period_month` (normalized to the first of the month by trigger), `amount` + `currency` (typed, **not** `amount_base` — H13, amended in Phase 16: a stored converted amount violates money rule 6 and can't be correct for two household members with different base currencies at once; converted on read via `fx_convert`, same as every other money value here), `version`, `created_at`, `updated_at`. Two partial unique indexes (`(owner_id, category_id, period_month) where category_id is not null` / `(owner_id, period_month) where category_id is null`) stand in for one constraint, since NULL is never equal to NULL in a plain unique index.
- **`ops_events`** — `occurred_at`, `source`, `level`, `code`, `detail`. RLS **on, no policies** — nothing readable by `authenticated`, matching the parked ops design. No PII, ever.

- **`reorder_accounts(p_account_ids uuid[])`** RPC — the Accounts list's drag-to-reorder write. Takes the full ordered id list for ONE kind group and sets each row's `sort_order` from its place in the array: one statement, one round trip, however many rows shifted. Deliberately **not** version-checked, and deliberately does not bump `version` or `updated_at` — it opts into the pre-existing `keepo.restamp_only` flag that `bump_version()`/`set_updated_at()` already honour (the same mechanism `restamp_account_for_sync` uses). Ordering is not a value two clients can meaningfully disagree about, and a drag that bumped versions would turn every subsequent genuine edit into a phantom `sync_conflicts` row.
- **`set_account_kind(p_id, p_expected_version, p_kind)`** RPC — dragging an account between the Everyday and Investments groups. Version-checked and conflict-returning, exactly like `update_account`: unlike ordering, `kind` **is** a value two clients can disagree about. Kind was immutable until `20260903100000`; `20260902100000` had kept it that way only because changing it "would be surprising", not because anything downstream depends on it — dragging the row is the user asking for it explicitly, so that reason no longer applies.
- **`accounts_set_sort_order`** trigger — a new account with no explicit `sort_order` is appended after the last row in its own kind group, not left at the column default of 0 (which would place it ahead of everything the user has already arranged). A trigger rather than a change to `create_account`, because `accounts` is inserted into from several places (`create_account`, `fork_one_account`, fixtures) and "a new row goes last" is a property of the column.

### Derived balances — no balance is ever stored on `accounts`

- **`account_balance_on(p_account_id, p_date)`** — one formula for every account, regardless of kind: `opening_balance + SUM(amount)` over transactions that are non-deleted, `status = 'confirmed'`, and `occurred_at <= least(p_date + 1 day, now())`. Unified in `20260902100000_unify_account_kinds.sql` — the account-kind CASE and the `balance_snapshots` lookup it used to branch into for `valuation` accounts are both gone. `least(p_date + 1 day, now())` is what lets one function serve both "today's live balance" (the future-dated guard: a not-yet-materialized recurring row can never move today's balance) and "balance as of an arbitrary past day" (Home's trajectory) without duplicating the formula — for `p_date = current_date` it reduces to exactly `occurred_at <= now()`. **`account_balances`** is a one-line wrapper (`account_balance_on(id, current_date)`) kept only because so much existing SQL already joins against it.
- **`accounts_with_balances`** — joins `account_balances` with `accounts`/`currencies` for name, kind, and `minor_unit` (`subtype` was dropped along with `account_subtype` — nothing used it behaviorally). One join, reused by every screen that lists accounts, instead of each re-deriving it.
- **`transactions_with_details`** — the same role for transactions: joins account name, category name, `minor_unit`, and derives `kind` (see the `transaction_kind` note above — computed here, not stored).
- **`create_transfer(p_from_account_id, p_to_account_id, p_from_amount, p_to_amount, p_occurred_at, p_from_id, p_to_id, p_notes)`** RPC — the only transaction kind that needs one. Expense/income are a plain insert (the `sign_matches_category_kind` CHECK makes a wrong sign impossible without any code enforcing it); a transfer needs both legs inserted atomically with signs applied here in SQL. `p_to_amount` is optional — inferred to equal `p_from_amount` when both accounts share a currency, required otherwise. `SECURITY INVOKER` (the default, stated explicitly): this is a convenience wrapper around ordinary inserts, not a privilege escalation, so RLS and every constraint above still fully apply. `p_notes` (migration 20260904100000, mirrored on `update_transfer`) writes the same note to **both** legs — a transfer is one act by the user, and either account's history read on its own must still show what they wrote; there is no third row representing "the transfer itself" to hang it off, which is the same reason both legs already duplicate `occurred_at`.
- **`account_balances_base`** — adds the base-currency conversion via `fx_convert()`, exposes `has_missing_rate` per money rule 5, and (since `20260820100000_archived_account_net_worth_exclusion.sql`) a trailing `archived_at` column so `net_worth()` can exclude an archived account's balance from the total while `account_balances` itself still resolves that account's own balance correctly wherever it's shown individually (AccountFormView, the Archive screen).
- **`net_worth(p_scope account_scope)`** RPC (shipped Phase 7) — `'me' | 'household' | 'total'`. `total` is literally `me + household` computed by summing the same `account_balances_base` rows under different `WHERE` clauses, each also filtering `archived_at is null`; it is **never** assembled by subtracting three client-fetched numbers, because there is nothing to subtract that RLS would let a client see anyway. Renders `NULL` (→ `—`) the instant any row in scope has a missing rate — never a silently-partial `SUM` — but `0` for a genuinely empty scope; the two are deliberately not conflated. `LocalMoneyConversion.scopedAccountIds` mirrors the same `archived_at IS NULL` filter for the on-device SQLite port.
- **`net_worth_daily`** (shipped Phase 8) — materialized per account, per day, **in each account's own currency** (never pre-converted), keyed `(account_id, as_of)`. RLS mirrors `can_read_account` (not `owner_id = auth.uid()`), so a household member can read a shared account's history for the `household`/`total` scopes exactly as they can the account itself. `refresh_net_worth_daily(p_user, p_from, p_to)` is the only write path (own data only, unless called as `service_role`); no `pg_cron` exists yet (Phase 13), so the client calls it itself before reading a trajectory. `net_worth_series(p_scope, p_from, p_to)` is the read side, converting each day on read via `fx_convert(..., that day)`, so a base-currency change never invalidates history and a past net worth figure never moves when today's rate moves.

### Money-rule-critical functions

- **`fx_rate_on(p_currency, p_date)`** — resolves the most recent `fx_rates` row at or before `p_date` (carries forward over weekends/holidays). EUR itself has an implicit rate of 1; every other currency is `rate_to_eur`.
- **`fx_convert(p_amount, p_from, p_to, p_date)`** — `p_amount / fx_rate_on(p_from, p_date) * fx_rate_on(p_to, p_date)`, short-circuited to `p_amount` when `p_from = p_to` (shipped Phase 8 — a same-currency conversion must never depend on `fx_rates` having a row for that date at all; without it, a many-day single-currency trajectory needed a resolvable rate on *every* day). **The only place currency conversion happens** — called by every view and RPC above, never duplicated. Returns `NULL` (→ `—`) if either rate is missing, never `0`.

### Integrity

- **Composite FKs**: `transactions (account_id, owner_id) → accounts (id, owner_id)` closes the RLS gap where a user could otherwise insert a transaction pointing at *someone else's* account — RLS checks `auth.uid()` on the row being written, not on the account it references. `transactions (account_id, currency) → accounts (id, currency)` keeps a transaction's currency locked to its account's. `transactions (category_id, category_kind) → categories (id, kind)` stops an expense filing under an income category; both columns are `NULL` for transfers, and `MATCH SIMPLE` skips the check there. (The former `transactions (account_id, account_kind) → accounts (id, kind)` composite FK, and the CHECK it supported, were dropped in `20260902100000_unify_account_kinds.sql` — every account now takes every transaction kind, so `account_id` reverted to a plain FK.) `category_kind` on `transactions` is populated by a `BEFORE INSERT OR UPDATE` trigger, so the app never has to keep it in sync itself.
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
- **`sync_seq bigint`** on every syncable table (`accounts`, `transactions`, `categories`, `budgets`, `recurring_rules`, `card_mappings`, `merchant_category_map`, `sync_conflicts`, `households`, `household_members`, `household_accounts`, `profiles`), stamped by a `BEFORE INSERT OR UPDATE` trigger calling `next_ticket()` for the row's domain. **`currencies`/`fx_rates` share one separate, fixed global domain** (`sync_global_domain()`) instead — a rate has no owner, but still needs a ticket. This is why `pull_changes` takes **two** cursors, not one: the global domain's counter accumulates across every user and grows far faster than any single household's, so a single scalar cursor taking the max across both would be dominated by the global one, and a freshly re-stamped row in a quiet household domain could sit at a low ticket while the client's cursor was already past a much higher global-domain value — `sync_seq > cursor` would be false forever for that row. Two independent cursors, each compared only against its own counter, is the actual fix (found via pgTAP, not by inspection).
- **`pull_changes(p_cursor, p_global_cursor)`** — `SECURITY INVOKER`, deliberately not an Edge Function: an RPC runs as the calling user, so RLS filters every table's changed-rows query for free. An Edge Function would need `service_role`, forcing `can_read_account` to be reimplemented in TypeScript — a second copy of the *access* model, a worse bug than a second copy of the money model. Returns one JSON object keyed by table name, each a `to_jsonb` array of rows with `sync_seq > cursor` (or `> global_cursor` for currencies/fx_rates), plus the two advanced cursors and the caller's `sync_epoch`.
- **`sync_epoch bigint`** on `profiles`, default 1. The access model today (RLS) filters every read live; a local-first client instead relies on the last pull, so gaining or losing access needs an explicit signal:
  - **Gaining access** (`share_account`) — the shared account and its existing transactions/snapshots/recurring rules predate the share and already carry old tickets that a normal cursor pull would never re-fetch. `restamp_account_for_sync()` re-stamps them with fresh tickets in the household domain instead. It does this via a plain touch `UPDATE`, not `ALTER TABLE ... DISABLE TRIGGER` (the first attempt) — that approach fails with "cannot ALTER TABLE because it has pending trigger events" whenever the account was created earlier in the same transaction, due to the `DEFERRABLE` FK triggers on `accounts`/`transactions`. `bump_version()`/`set_updated_at()` gained a transaction-local `keepo.restamp_only` escape hatch so this re-stamp doesn't also bump `version`/`updated_at` on every touched row — a share shouldn't silently invalidate the sharer's own cached `expectedVersion`.
  - **Losing access** (`unshare_account` with another member present, `leave_household`, `erase_own_account`, and `accept_invite` for the *accepting* user's own domain change) — bumps the affected user's `sync_epoch`. A local-first client sees the epoch move, drops its server-derived tables (keeping the outbox), and re-pulls from cursor 0 — the cleanest correct response to "my domain's ticket numbering just changed out from under me," since a cursor from before a domain change is denominated in a different, unrelated counter. `unshare_account` forks first (`fork_one_account`, extracted from `fork_household_accounts`' per-account loop so both share one implementation) so the losing member keeps a full independent replica, then bumps only *their* epoch — the sharer's own domain and cursor are untouched.
- **Not yet true**: "RLS filters at download time, not read time" is the eventual L5/L6 client behavior once the local store exists; today RLS still filters every live read exactly as before, and `pull_changes` simply exists as an available, additional path.

### On-device store (L3, `keepo-local-first-plan.md`)

Client-only, server-side behavior unchanged — the app is still online-first; this lands the SQLite store L5's pull loop and L6's read path will build on, plus a full storage-layer port of the existing offline outbox.

- **GRDB (`App/LocalStore.swift`)**, a SPM dependency on the `Keepo` app target only, same reasoning as `OfflineStore`'s own header comment on why it lives in the app target and not `KeepoCore`: this is client-storage plumbing, not portable money logic. A single `DatabaseQueue` at `Local.sqlite` in the app container's Application Support directory (no App Group — same reasoning as `OfflineStore.swift`), memoized per-process behind a lock so `SessionStore` and `CaptureIntent` never open two coordinators against the same file. File protection (`.completeUnlessOpen`) applied to the main file and its `-wal`/`-shm` siblings, identical pattern to `OfflineStore.protectStoreFiles` — including its confirmed Simulator limitation (no data-protection subsystem to read the attribute back from; real enforcement is device-only, Phase 20's checklist).
- **Schema mirrors the server 1:1** — all 16 syncable tables (`LocalSchemaV1`), `snake_case` columns, `sync_seq`/`deleted_at`/`version` present wherever the server has them, money as `INTEGER` (`_e4` bigint, matching L1). Dates/timestamps stay `TEXT`, the exact string PostgREST already produced — no reparsing here, no local FX arithmetic either (`fx_rates.rate_to_eur` stays an opaque `TEXT` decimal string; the referee comparing SQLite output against Postgres is L4's job). **Schema only, today** — nothing writes into these 16 tables until L5's pull loop lands; the table shapes are locked in now so the sync design and the schema can't drift apart.
- **The offline outbox is fully ported off SwiftData onto GRDB** (`outbox_items`, `OutboxItemRecord` in `LocalStore.swift`). `Outbox`'s public surface (`submit*`/`drainAll`/`queuedKindsAndPayloads`/`pendingCount`) is unchanged — only its storage internals moved, so every call site from Phase 11 onward needed no changes beyond how `Outbox` itself is constructed. `created_at` on this table alone is `.double` (a `timeIntervalSince1970`), not `.text` like every synced table's date columns — this column is pure local bookkeeping, never compared against a server timestamp, and a `TEXT`-affinity round trip through a 15-significant-digit cast was found (via a flaking unit test) to occasionally round a just-inserted row's timestamp forward past `Date()` read a moment later.
- **`OutboxMigration`** — a one-time, idempotent move of any rows still queued in the pre-L3 SwiftData `OutboxItem` store into `outbox_items`, run at `SessionStore` construction (and defensively again in `CaptureIntent`, since an App Intent launch may not go through the same init path). `OfflineStore`'s `VersionedSchema` still declares the `OutboxItem` SwiftData model purely so this migration can open and read the legacy store; nothing else writes to it anymore. (`PayloadCache`/`CachedPayload` were unaffected at the time and stayed on SwiftData through L3–L5 — L6 deleted `PayloadCache` outright once the local mirror replaced it as the read path; see that section below. `CachedPayload` itself stays declared in `OfflineSchemaV1` — dropping a SwiftData model from a versioned schema without a migration stage is its own hazard, not worth taking for a model nothing writes to anymore.)
- **No `ValueObservation` wiring yet** — `Outbox` is currently the sole writer to its own table and already refreshes its `@Observable` properties synchronously after every write; there is no second writer for a SwiftUI view to observe until L5's pull loop starts writing into the syncable-table mirror. Wiring `ValueObservation` now would be speculative.

### The money layer, ported to SQLite (L4, `keepo-local-first-plan.md`) — "the make-or-break phase"

Client-only; the server-side functions this ports (`account_balance_on`, `net_worth`, `spending_by_category`, `income_expense_series`, `savings_rate`, `unrealized_gain`, `budget_progress`, `fi_metrics`) are untouched and stay the oracle L6's cutover verifies against. Nothing reads from this layer yet — L5's pull loop has to populate the L3 schema first.

- **FX conversion is not ported to SQL** — every `LocalMoneyQueries` function (`App/LocalMoneyQueries.swift`) returns **native-currency** results only; the same file's header explains why grouping-then-converting can't be byte-exact against Postgres's `sum(fx_convert(...))` (which rounds inside the aggregate, once per row) unless the SQLite side reproduces that same per-row granularity. `LocalMoneyConversion.swift` (+ `LocalMoneyConversionFI.swift`, split only to stay under this project's file-length lint) is the one place native results become base-currency figures: a single-currency value (an account balance, a budget's own amount) converts once; a value built by summing across possibly-different-currency transactions is fetched as individual native rows and converted+rounded **row by row** before summing, via `LocalFxConvert` (already built in L1) plus a ported `fx_rate_on` carry-forward lookup. `LocalMoneyScope` (`{scope, baseCurrency}`) travels together through every scoped function purely to keep parameter counts under this project's lint limit.
- **Dates compared as `TEXT`, never reparsed** — `PostgresDate.sqliteTimestampBoundaryString(_:)` (`KeepoCore`) formats a boundary in PostgREST's own six-fractional-digit `+00:00` form so a `<=` string comparison against `occurred_at` sorts identically to a real timestamp comparison; `ISO8601DateFormatter`'s default whole-second `Z` form does not (a same-second row with a fractional part would sort *before* the boundary, silently dropping it). A `date`-only value is a literal `substr(occurred_at, 1, 10)` — safe only because Supabase's session timezone is UTC, the same zone PostgREST renders in, so this is a substring of an already-UTC string, not a re-derivation.
- **`fi_metrics`' ratio math (`years_to_fi`, `coast_fi_number_e4`, `percent_progress`) uses `Double`/`ln`/`pow`**, not `Decimal` — Postgres's `numeric` transcendental functions carry no bit-identical guarantee against Foundation's, and the referee's own contract only requires these within a stated tolerance. `fi_number_e4` itself (money, not a ratio) still divides using `Decimal` parsed straight from the `withdrawal_rate` TEXT column, to stay exact.
- **The referee (`KeepoTests/LocalMoneyRefereeTests.swift` + `LocalMoneyRefereeFixture.swift`)**: one fixture (two currencies with a resolvable rate, one — GBP — deliberately with none, a JPY account, a valuation account with an unrealized gain), asserted against real Postgres output captured once via `docker exec ... psql` against the local dev stack (`version-logs/phase-L4-log.md` has the exact command). **This is a pinned comparison, not a live cross-process one** — the iOS test target has no Postgres wire-protocol driver, so "the referee" means the SQLite port reproduces numbers Postgres actually produced in that capture, not Postgres answering live at every test run. The pinned values need regenerating (rerun the capture) if the ported SQL changes on either side. All 9 assertions pass, including the full money-rule-5 propagation chain (one missing-rate GBP transaction correctly poisons `net_worth`, `spending_by_category`, `income_expense_series`, `savings_rate`, `budget_progress`, and `fi_metrics` to `nil`, never `0`).

- **RLS + GRANTs, every table, no exceptions.** RLS narrows access a `GRANT` already gave; it grants nothing itself — without the `GRANT` a query fails before RLS is even consulted. Nothing is granted to `anon`. One policy per command, always `(select auth.uid())` (the bare form re-evaluates per row), and every `UPDATE` policy carries both `USING` and `WITH CHECK` — `USING` alone lets a user reassign a row's ownership to someone else. **Supabase's local cluster grants `TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN` to `anon` and `authenticated` on every table by default** (visible via `pg_default_acl`; confirmed `anon` could actually issue `TRUNCATE`, which bypasses RLS entirely) — closed once, schema-wide, with `ALTER DEFAULT PRIVILEGES ... REVOKE ...` before the first `CREATE TABLE`, so every future table is clean automatically rather than needing a per-table fix.
- **`needs_review`** is a **view**, not a table — `UNION ALL` over: `transactions WHERE status = 'pending'` (unconfirmed captures), `card_mappings WHERE account_id IS NULL` (ambiguous cards), `sync_conflicts WHERE resolved_at IS NULL`, `reconciliations` gaps, `csv_import_candidates WHERE status = 'pending'`, and low-confidence category suggestions from `merchant_category_map`. One inbox, one query, no duplicated review-tracking table per feature.

### Sync engine on device (L5, `keepo-local-first-plan.md`)

The pull side of local-first — `Outbox` (Phase 11/L3) remains, unchanged, the push side. Nothing reads from the local money layer yet (L6 is the read-path cutover), so this phase's own effect is invisible in the running app today; it exists so L6 has real, current data to read.

- **`pull_changes` precision fix, found before writing a line of client code**: `to_jsonb(row)` turns a Postgres `numeric` column into a JSON *number*. `fx_rates.rate_to_eur` was (with `fi_settings`'s two rate columns, since removed along with that table) one of the few `numeric` columns left in the syncable set (L1 made every money amount `bigint`); decoding one through a JSON number into a binary float before re-encoding it as the local `TEXT` decimal string would silently reintroduce the exact imprecision L1 removed and L4's referee verified was gone. Fixed with a follow-up migration overriding that key with an explicit `::text` cast merged onto the row's own `to_jsonb` output — `pull_changes`'s signature is unchanged.
- **`App/SyncApply.swift`** — one generic upsert, driven by the JSON row's own keys against a per-table column whitelist matching `LocalSchemaV1` exactly (never a blind pass-through of arbitrary JSON keys into SQL identifiers). A "tombstone" needs no special DELETE path: a soft-deleted server row still has a payload (`deleted_at` simply non-null), and every local money query already filters `deleted_at IS NULL` itself — upserting it normally is already correct.
- **`App/SyncEngine.swift`** — one `pull()` call round-trips `pull_changes` once (the RPC has no pagination; a single call already returns the full backlog) and applies the result inside one GRDB transaction. An **epoch mismatch** (this device's stored `sync_epoch` differs from the fresh one — a share/unshare/leave changed what this device can see since its last pull) wipes every server-derived table (never `outbox_items`), resets the stored cursors, and re-pulls from 0. `SyncCursorStore` persists `(cursor, global_cursor, epoch)` in `UserDefaults`, namespaced by user id — pure local bookkeeping, same category as `Outbox`'s own `created_at` column, never synced.
- **Trigger sites**: `RootView`'s existing scenePhase-active handler (alongside `Outbox.drainAll()`), `NetworkMonitor` regaining connectivity, and every sign-in path in `SessionStore`. **A Realtime nudge ("the ticket moved, go pull") is deferred, not built** — investigated first: Phase 19's household-events mechanism turned out to be polling (`HouseholdViewLoader`/`HouseholdRepository.fetchEvents`, called each time that screen loads), not an existing Realtime subscription, so there was nothing to reuse, and adding this app's first-ever `RealtimeChannel`/`postgresChange` usage is a genuinely separate, untested feature surface. The three lifecycle triggers already cover correctness (a shared account's changes are seen at the next foreground/reconnect/sign-in); only instant cross-device staleness is deferred.

### Read path on-device (L6, `keepo-local-first-plan.md`)

Every screen now reads from the local GRDB mirror — `PostgREST`/`PayloadCache`/`FxRateCache`/
`CurrencyCache`/`DataStore` are gone from the read path entirely, deleted rather than left dormant
alongside the local queries (two answers to "what's my balance" is the exact divergence this whole
rebuild exists to remove).

- **`App/LocalAccountRow.swift`/`App/LocalTransactionRow.swift`** are the two non-trivial result
  types. Straight 1:1 table types (`categories`, `budgets`, `recurring_rules`, `currencies`, a single
  `accounts`/`transactions` row, `households`/`household_members`/`household_accounts`) reuse the
  *generated* `PublicSchema.*Select` structs directly via `FetchableRecord` (GRDB's default
  `Decodable`-based row decoder) — `App/LocalTableQueries.swift`. But `accounts_with_balances` and
  `transactions_with_details` are Postgres *views* with computed columns (`balance_e4`, `is_shared`,
  `amount_base_e4`, `kind`, `has_missing_rate`) that don't exist as raw table columns, and FX
  conversion has to happen in Swift (L4), not SQL — so those two get purpose-built result types
  instead. `LocalTransactionRow` specifically builds `PublicSchema.TransactionsWithDetailsSelect`
  instances (the exact type every consumer — `TransactionRow`, `TransactionFormView`, `MapCardSheet`
  — already renders) via an `AnyJSON` → `JSONEncoder` → `JSONDecoder` round-trip, because that
  generated type has no public initializer reachable from the App target (a plain `Codable` struct
  with no custom `init`, so only its synthesized `public init(from decoder:)` crosses the module
  boundary) — this keeps every downstream view unchanged, at the cost of one indirection most other
  local-read call sites don't need.
- **`Outbox` write-through (`App/OutboxLocalWrite.swift`)** — the load-bearing piece that makes
  deleting the old cache/overlay machinery safe. Before L6, `Outbox` sent a write straight to
  Postgres and only *queued* it locally on failure; the local mirror otherwise only advanced via
  `SyncEngine.pull()`. Once every screen reads local-only, that gap would have meant an offline (or
  even a fast, just-submitted online) write staying invisible until the next pull — precisely what
  `PendingOverlay` used to paper over on the old cache-based read path. Every `Outbox.submitX` now
  applies the same payload as an optimistic upsert into the local mirror immediately, via
  `SyncApply.upsertRow` — the identical whitelist-guarded upsert the real sync pull already uses, so
  the eventual authoritative row overwrites the optimistic one at the same primary key; never a
  second, competing source of truth. `sync_seq` is written as a `0` placeholder (no money query reads
  it) purely to satisfy the `NOT NULL` constraint until the real value lands. Transfer legs are
  matched by their current sign (money rule 1) since an update/delete-transfer payload carries a
  `transfer_group_id` but not each leg's own id. `set_account_balance` mirrors the server RPC's own
  branch — an adjustment transaction for a ledger account, a new snapshot for a valuation account,
  never a stored balance either way. `captureTransaction` is the one write kind NOT covered: its
  payload has no `accountId`/`categoryId` (resolved server-side from `card_mappings`), and every
  local balance query already filters `status = 'confirmed'`, excluding the pending row it would
  write anyway.
- **A version conflict needs a real sync pull before the local re-read, not just a local re-read.**
  `Outbox`'s write-through already applied the user's (rejected) edit to the local mirror
  optimistically before the conflict was known — `AccountFormView`/`TransactionFormView`'s
  post-conflict reload calls `session.syncEngine?.pull()` first, then re-reads locally; skipping the
  pull would just echo the same wrong guess back.
- **`HouseholdView` stays partially online-first, deliberately.** `household_events` has no local
  table — it's a notification feed, not money-bearing data, and mirroring it was never in scope —
  so `HouseholdViewLoader` reads `household`/`members`/`myAccounts`/`sharedAccountIds` locally and
  fetches `events` best-effort over the network, never blocking the rest of the screen if that call
  fails.
- **`needs_review`'s `csv_import_candidate` branch never appears via the local read** —
  `LocalMoneyQueries.needsReview` only derives the three locally-computable branches; CSV import
  stays server-side entirely (a decision already on record — see the plan's open questions), so those
  review items are only reachable from `CSVImportView` itself while online.
- **`OfflineStatusBar`'s "Last synced …" moved from `PayloadCache.latestFetchedAt()` to
  `SyncCursorStore.lastSyncedAt(for:)`**, persisted in `UserDefaults` alongside the cursor/epoch on
  every successful pull — the same namespaced-by-user-id pattern that store already used, so this
  needed no new persistence mechanism, just one more field on an existing one.

### Indexes

Postgres doesn't auto-index FK columns. Needed from day one: `transactions (account_id)`, `(category_id)`, `(owner_id, occurred_at desc, id desc)` for keyset pagination, `(transfer_group_id) WHERE transfer_group_id IS NOT NULL`, a partial unique index on `(owner_id, source, external_id) WHERE external_id IS NOT NULL` (capture/import idempotency, §4), plus `accounts (owner_id)`, `categories (owner_id, kind)`.

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
