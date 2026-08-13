# Phase L4 — Port the money layer to SQLite, and the referee

Part of the local-first rebuild (`keepo-local-first-plan.md`) — "the make-or-break phase." Client-only,
server-side behavior and functions unchanged; the Postgres money functions stay in the repo purely as
the referee's oracle. Nothing reads from this new local money layer yet — L5's pull loop has to
populate L3's schema first, and L6 is the actual read-path cutover.

## Delivered

- **`App/LocalMoneyQueries.swift`** — native-currency-only SQLite port of `account_balance_on`
  (ledger + valuation, boundary clamped to `least(asOf+1day, now())` exactly like the server), a
  generalized `account_balances`-equivalent (any `asOf` date, not just "today" — needed by the net
  worth series, which recomputes per day rather than caching a `net_worth_daily` equivalent),
  `unrealized_gain` (exact, single-currency, no FX involved), `needs_review` (`sync_conflicts` +
  pending captures + ambiguous `card_mappings` — the three branches whose source tables exist in L3's
  schema), and the shared scope-filter/categorized-transaction-fetch helpers every insights function
  reuses.
- **`App/LocalMoneyConversion.swift` + `LocalMoneyConversionFI.swift`** (split only for this project's
  file-length lint) — the one place native results become base-currency figures: `fx_rate_on` (a
  carry-forward lookup, ported to SQL) feeds `LocalFxConvert` (already built in L1) at the display
  boundary. `net_worth`/`net_worth_series`/`spending_by_category`/`income_expense_series`/
  `savings_rate`/`budget_progress`/`fi_metrics`, each converting at exactly the granularity Postgres
  itself rounds at (single-currency values convert once; multi-currency sums convert+round row by row
  before summing, matching `sum(fx_convert(...))`'s per-row rounding — see Findings #1).
- **`App/LocalMoneyTypes.swift`** — shared UTC/ISO calendars, the `RunningTotal` accumulator (money
  rule 5 propagation: any missing-rate row poisons the running total to `nil` permanently, matching
  Postgres's `bool_or(... is null)` short-circuit), and the plain result structs.
- **`KeepoCore/DateFormatting.swift`** gained `PostgresDate.sqliteTimestampBoundaryString(_:)` — see
  Findings #2.
- **The referee** (`KeepoTests/LocalMoneyRefereeTests.swift` + `LocalMoneyRefereeFixture.swift`) — one
  fixture (EUR/USD/JPY ledger accounts with resolvable rates, a GBP ledger account with **no** rate
  ever, a EUR valuation account with a snapshot + a transfer-in after it), captured against real local
  Postgres via `docker exec -i supabase_db_keepo-app psql -U postgres -d postgres` running a
  `BEGIN; ...; ROLLBACK;` script (never committed, scratch only) that calls every ported function
  directly. The exact captured output (account balances, `net_worth` by scope, `spending_by_category`,
  `income_expense_series` weekly/monthly, `savings_rate`, `budget_progress`, `fi_metrics`) is pinned as
  the Swift test's expected values; the identical fixture (same UUIDs, amounts, dates) is inserted
  directly into an in-memory GRDB store and asserted to match. **9/9 pass**, including full money-rule-5
  propagation: the one no-rate GBP transaction correctly poisons `net_worth('me')`/`('total')`,
  `spending_by_category`, both `income_expense_series` granularities' expense side, `savings_rate`, and
  every `fi_metrics` field to `nil` — while `net_worth('household')` (no accounts in that scope) stays
  a clean `0`, proving the "empty set is 0, one unresolvable member is null" distinction survived the
  port.

## Findings

1. **Byte-exact FX conversion requires row-level rounding granularity, not currency-level.** Postgres's
   `spending_by_category`/`income_expense_series`/`budget_progress` all compute
   `sum(fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date))` — `fx_convert` rounds to
   bigint *inside* the aggregate, once per row. A first design drafted grouping natively by
   `(currency, date)` and converting once per group before summing — mathematically close, but NOT
   guaranteed identical: two same-currency same-day transactions round independently server-side, and
   rounding a pre-summed native total in one shot can differ from the sum of two independent roundings.
   Fixed by having `LocalMoneyQueries` return individual native transaction rows (still a plain SQL
   `SELECT`, no arithmetic) and doing the per-row convert-then-round-then-sum reduction in
   `LocalMoneyConversion` via the `RunningTotal` accumulator — this is what the referee's fixture
   (multiple currencies, several same-week/same-month transactions) actually exercises and confirms
   exact against the captured Postgres output.
2. **A local `TEXT` timestamp column can only be compared as a string if every string sharing that
   column was rendered in the identical format** — `LocalStore.swift`'s own design already avoids
   reparsing these columns; this phase is the first one that needs to *compare* them (`account_balance_on`'s
   `occurred_at <= least(p_date+1day, now())`). `ISO8601DateFormatter().string(from:)`'s default output
   (`...16Z`, whole seconds) sorts **before** a same-second PostgREST row with a fractional part
   (`...16.320521+00:00`) — `.` (0x2E) < `Z` (0x5A) at that byte position — silently excluding a
   transaction that occurred earlier in the same second than the boundary's truncation implies. Fixed
   with a dedicated `PostgresDate.sqliteTimestampBoundaryString(_:)` matching PostgREST's own six-
   fractional-digit `+00:00` rendering exactly; confirmed against a live row via `curl` against the
   local REST API before writing the formatter, not assumed. Unit-tested in `DateFormattingTests.swift`
   with the exact same-second-but-later case that would have flipped the comparison.
3. **`fi_metrics`' `withdrawal_rate` division needed `Decimal`, not `Double`, to keep `fi_number_e4`
   exact** — an early draft parsed `withdrawal_rate`/`real_return_rate` both as `Double` for the ratio
   math (`ln`/`pow`, which need floating point regardless). `withdrawal_rate` (e.g. `"0.04"`) isn't
   exactly representable in binary `Double`, so routing the *money* division (`annual_spend / withdrawal_rate`)
   through it would introduce real, if tiny, drift from Postgres's exact `numeric` division — a real
   violation of the "money output identical to the unit" contract this phase's whole point is to
   guarantee. Fixed by keeping two separate parses: `Decimal(string:)` for the value that feeds
   `fi_number_e4` (money, exact), `Double.init` only for `real_return_rate` (which only ever feeds
   `ln`/`pow` for `years_to_fi`/`coast_fi_number_e4`, both explicitly tolerance-bound by the plan).
4. **The referee is a pinned comparison, not a live cross-process one — a deliberate, disclosed scoping
   decision, not a shortcut.** The plan's own text ("one fixture loaded into both Postgres and SQLite")
   reads as a live differential test. The iOS/`KeepoTests` target has no Postgres wire-protocol driver
   (no `PostgresNIO`/`libpq` binding anywhere in this project, and adding one solely for a test target
   would be exactly the kind of heavyweight, out-of-place dependency CLAUDE.md's engineering principles
   warn against), so a genuinely live comparison isn't available from within the app's own test suite.
   Instead: the fixture was run once against real local Postgres via `docker exec ... psql` inside a
   rolled-back transaction (see Delivered above), the actual output captured, and those exact numbers
   pinned as the Swift test's expected values against the identical fixture inserted into GRDB. This is
   real ground truth, not hand-computed/assumed — but it is frozen at capture time: if the ported SQL
   changes on either side, the pinned values need regenerating by rerunning the capture, not just
   rerunning `swift test`. Documented here and in `app-architecture.md`'s new L4 section so this
   limitation is visible to whoever next touches this code, not discovered by surprise.
5. **The dialect-porting hazard the plan anticipated (LH9 — `generate_series`, `LATERAL`, Postgres date
   functions, enums) never actually came up.** None of the eight ported functions needed a recursive
   CTE, a correlated subquery, or `strftime`; every one decomposes into plain `SELECT`/`WHERE`/`GROUP
   BY`-shaped SQL once FX conversion is factored out into Swift (Finding #1) and date comparisons are
   done as literal `TEXT` matching (Finding #2). The actual porting risk turned out to be arithmetic
   granularity and string-format precision, not SQL dialect syntax — worth knowing for L5/L6, which
   will hit real dialect differences once they touch `pull_changes`'s JSON shapes and upsert semantics.

## Verification

- `xcodebuild -scheme Keepo -destination 'generic/platform=iOS Simulator' build` — clean.
- `xcodebuild ... test -only-testing:KeepoTests` — 22/22 (9 new referee assertions, 13 pre-existing
  from L3 unchanged).
- `swift test` (KeepoCore) — 74/74 (72 pre-existing + 2 new `PostgresDate.sqliteTimestampBoundaryString`
  tests).
- `swiftlint lint --strict` — 0 violations across 111 files (required splitting the money-conversion
  logic into `LocalMoneyConversion.swift`/`LocalMoneyConversionFI.swift`/`LocalMoneyTypes.swift` and the
  referee fixture into its own file to stay under `file_length`/`type_body_length`/
  `function_body_length`/`function_parameter_count`; introducing `LocalMoneyScope` specifically to cut
  parameter counts under the project's lint cap).
- **Referee**: 9/9 assertions pass against real captured Postgres output — see Delivered above for the
  exact fixture and Findings #4 for what "the referee" mechanically means in this codebase.
- **Not performed this session**: no simulator walkthrough — nothing in the app's visible surface
  changed (this phase adds a dormant local money-computation layer nothing reads yet). No hosted push —
  entirely client-side; the two server-side scope corrections (deferred `net_worth_daily` deletion, the
  `csv_import_candidate` `needs_review` branch) are documented in `keepo-local-first-plan.md`'s L4
  section rather than requiring any migration this phase.

## Human review stop

Per the plan: **if the referee cannot be made green, the architecture is wrong and we stop here rather
than building on it.** The referee is green — all 9 assertions pass against real Postgres-captured
ground truth, including the full money-rule-5 nil-propagation chain across every function. Reporting
this to the user as the mandatory stop before starting L5.
