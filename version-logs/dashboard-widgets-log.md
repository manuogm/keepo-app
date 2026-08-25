# Home dashboard — user-customizable widgets (2026-08-20, session 5)

User-driven feature, not a phase from the master plan: Home's hard-coded net-worth card became a widget dashboard the user arranges themselves. Spec came from the user across several rounds of chat (grid rules, placement edge cases, expansion behavior), captured in `app-architecture.md` §2's "Home dashboard" paragraph — read that first.

## Delivered

- **Layout engine** — `DashboardArrangement`/`DashboardLayout` in `KeepoCore`, pure and unit-tested (24 tests). Absolute `(row, column)` placement, not flow-packed, per explicit user requirement: a lone 1×1 can sit in the right column with the left cell deliberately blank, and a hole between two wide tiles survives normalization rather than being auto-filled. Only fully-empty rows compact. Drop resolution: free cells win; a 1×1 onto a 1×1 makes room (slides sideways into a free cell in the row if one exists, otherwise swaps); anything else onto an occupied cell inserts a new row and pushes down, never sideways.
- **Edit mode** — long-press (`.onLongPressGesture`, not a `DragGesture` — see Findings) jiggles every tile (period derived from a stable hash of the tile's id via `StableSeed`, never its index) and shows minus badges; drag-to-reorder only attaches while editing.
- **Catalogue** — `DashboardCatalogView`, whose previews are the actual widget views (`DashboardWidgetView`) rendered against `DashboardData.sample`, not a parallel mock. Picking a widget drops straight into edit mode with it already placed.
- **Five widgets**: Net Worth, Upcoming Bills, Currency Exposure, Cashflow, Investing Ratio. Every widget's data is a local derivation of already-refereed L4 primitives (`LocalDashboardQueries`, `LocalDashboardQueries+Cashflow`) — no migration, no new RPC, no fresh SQL that bypasses `LocalMoneyConversion.convert`.
- **New KeepoCore types**: `DashboardArrangement`/`DashboardLayout`, `RecurrenceSchedule` (client-side occurrence projection, the local counterpart to `next_occurrences()`), `CashflowPeriod` (always the last *complete* month/year, never partial), `StableSeed` (extracted after a third call site needed the same stable hash — was inlined twice before, in `CreditCardFace` and this feature's own jiggle timing).
- **CLAUDE.md amended**: money rule 1's `kind` clause now explicitly allows `kind` as a display-only classifier (Investing Ratio sums `kind = 'investment'` balances) while still forbidding it from branching balance computation.

## Findings

1. **A per-tile `DragGesture`, even `.sequenced(before:)` behind a `LongPressGesture`, silently takes the touch from an enclosing `ScrollView` before either gesture has recognized anything** — the whole dashboard stopped scrolling, with nothing in the code suggesting why. Found by bisection (removing `GeometryReader`, then the tile gesture, one at a time) after reading the code found nothing. Fixed by never attaching the drag gesture outside edit mode — a bare `.onLongPressGesture` to *enter* edit mode coexists with the scroll pan the way every iOS context-menu gesture does; the drag is only live once editing. **Known limitation left open on the user's call**: dragging still claims the touch while editing, so there's no auto-scroll near the top/bottom edge — a dashboard taller than one screen can't be rearranged past the fold yet.
2. **A date-only column decoded in one calendar and formatted in another shifts by a day for any zone west of the decoding zone.** `recurring_rules.next_due_at` is decoded in `utcCalendar` (required — that's the zone the local SQLite store compares date strings in), but `Date.formatted()` defaults to the device's zone. Every upcoming bill rendered one day early in CDT. Fixed at the root: `PostgresDate.dateOnlyLabel(_:calendar:)` renders in the calendar it was decoded with, backed by a new `DateFormatter` cache in `FormatterCache` (per that file's own header, formatter construction-per-render is this app's known "feels laggy" mechanism). Two regression tests pin it. `RecurringRulesView` was not affected — it decodes and formats both in local, so it happened to round-trip.
3. **`.task(id:)` cancellation is a routine, expected event that was being shown to the user as a red error.** Once Home's task id included the mounted-widget set (needed so adding/removing a widget reloads), *every* widget add cancelled the in-flight load and `catch { errorMessage = UserFacingError.describe(error) }` rendered `CancellationError()` as "Something went wrong." Fixed generally: `UserFacingError.isCancellation(_:)` in `KeepoCore`, mirroring the existing `isOffline` precedent rather than changing `describe`'s signature (several call sites need a non-optional message and can't take an `Optional` return). **Only applied at the one site that hit it this session** (`HomeView`) — grepped and found ~22 other `errorMessage = UserFacingError.describe(error)` call sites across the app that share the same latent gap, unaudited. Worth a dedicated pass before this class of bug is found live again elsewhere.
4. **`AreaMark`'s default fill anchors at zero**, which drags the whole Y-domain down with it — a real $2k month of net-worth movement rendered as a flat line pinned near the top of the chart. Fixed by anchoring the area's `yStart` to the chart's own computed domain floor instead of to zero; `LineMark` was never the problem, only the fill.
5. **Two points is not a trajectory.** The spec says never show a flat trend line; the initial `hasTrajectory` check (`count >= 2`) still let exactly two points draw a single straight segment, which looks like a real chart while carrying no more information than the trend badge above it. Raised to `count >= 3`.

## Verification

- KeepoCore: 132/132 (was 105 before this feature — `DashboardArrangementTests` 24, `RecurrenceScheduleTests` 8, `CashflowPeriodTests` 8, `StableSeedTests` 5, `UserFacingErrorCancellationTests` 2, plus a `DashboardData`-adjacent addition).
- KeepoTests (app target): 87/87, including new `DashboardDataTests`.
- `swiftlint --strict`: 0 violations.
- Every widget exercised on-device in every state (collapsed, expanded, Cashflow's 3×2 breakdown, edit mode add/remove/drag, blank state) via the iOS Simulator, cross-checked against `docker exec ... psql` queries against the local dev stack — e.g. Cashflow's net total matched Postgres's own `sum(fx_convert(...))` to the cent, and Currency Exposure's two slices summed to exactly the Net Worth widget's own figure.
- Not performed: a real-device walkthrough (simulator only, this session); an audit of the other ~22 `UserFacingError.describe` call sites for the same cancellation gap (Finding 3).

## Notes for whoever picks this up next

- The widget catalogue (`DashboardWidgetKind`) is designed to grow — a new case plus a `DashboardWidgetView` branch is the whole integration surface. Nothing about the layout engine assumes today's five.
- `LocalDashboardQueries` and `LocalDashboardQueries+Cashflow` are the pattern for any future widget's data: derive from `LocalMoneyQueries`/`LocalMoneyConversion` primitives, never re-implement FX conversion.
- Budgets was deliberately **not** built as a widget this session — it's owner-scoped only server-side (no household clause), so it can't honor the scope filter every other widget does. The user wants it shared with a household first; see the memory note `budgets-household-sharing-first` for why.

---

# Widget redesign — shared kit, charts, and six rebuilt widgets (2026-08-25)

Second pass over the same dashboard, user-driven again. The five widgets above were replaced (and a sixth added) on top of a **shared widget kit**, and the architecture changed from "a widget is a SwiftUI view" to **"a widget is a definition plus a config"** — the groundwork for the user's stated long-term goal of blank *template* widgets a Keepo user configures themselves. Full spec and the thirteen locked design decisions are in `keepo-v1-master-plan.md` § "Widget redesign workstream". Read that before changing anything here.

## Delivered

- **Shared kit** (`App/Features/Home/Dashboard/Widgets/Kit/`) — `WidgetPalette` (every colour decision in one place; `CurrencyColor`/`CashflowPalette` moved out of `DonutChartView`), `HighlightableChart` (scroll + pinch-zoom + tap-to-highlight), `SeriesWidgetState` (the state machine every charting widget shares), `SeriesWidgetChrome`, `TimeframeFilterView`, `WidgetSegment`, `MetricHeadline`, `WidgetSparkline`, `WidgetFillBar`, `CurrencyBadge`, `DaySplitRing`.
- **New KeepoCore types** — `MetricGranularity` (one definition of a bucket, its evaluation date, and its axis label), `MetricTimeframe`/`MetricZoom`/`SeriesWindow`, `CurrencyRegion` (currency code → flag emoji), `WidgetConfig`/`MetricKind` (the template hook — `Codable`, but deliberately never persisted).
- **Windowed series pipeline** — `DashboardMetricSeries` + `MetricSeriesCache`. Never loads a whole timeline: the visible bucket range plus one window either side, re-windowed on scroll. Cache is **in-memory, keyed on the refresh token**, not a persisted rollup table — see Findings.
- **Six widgets**: Networth Analysis, Currency Exposure, FX Rate (new), Investing Ratio, Cashflow Breakdown, Transactions Next 2 Weeks.
- **Cross-scope transfers now count as cashflow.** A transfer leg counts only when its counterparty account is **outside the current scope**, surfaced under a "Transfers" pseudo-category. Total scope sees nothing (both legs cancel); Personal sees a household→personal move as real inflow.
- **Upcoming stopped being expense-only.** Its headline is now the fortnight's **net**, so a two weeks containing a salary can read positive. Transfers can never appear there — `recurring_rules.category_id` is `not null` and a transfer leg has no category, so the third ring colour is structurally unreachable.
- **Tab-switch navigation** — `AppNavigation` in the environment, `TabView(selection:)`. Cashflow's category chevron switches to Transactions with the category and the highlighted bucket's period applied.

## Findings

1. **`BarMark(width: .ratio(_:))` silently resolves to zero width on a continuous x scale.** A ratio is a fraction of the scale's *step*, and this chart's x axis is a continuous `Double` domain (which is what makes exact `chartXVisibleDomain` lengths and uniform bar widths possible in the first place) — so it has no step. **No bar chart on the dashboard drew a single bar**, and it looked like a data problem rather than a layout one because the y axis still scaled to include the bar values. Fixed by measuring the plot with a `GeometryReader` and passing `.fixed(width)`. This had shipped unnoticed through a previous session's "verified on device" for Investing Ratio — a chart with an empty plot area reads as "no data yet", which is exactly what a young account is expected to look like.
2. **Swift Charts stacks `BarMark`s that share an x position and a sign.** Investing Ratio draws its invested bar over a net-worth backdrop; stacked, the two summed and the invested bar was pushed above the top of the y domain, leaving a sliver. Fixed with the explicit `yStart:`/`yEnd:` form, which does not stack.
3. **Mark identity is scoped to the whole `Chart`, not to a series.** Three series each numbering their own marks `0, 1, 2` collide. Found while chasing (1); fixed by prefixing the series id. Not the cause of the missing bars, but a real bug that would have surfaced the moment two series overlapped.
4. **A `.onChange(of: period)` cannot tell a user's tap from a programmatic assignment.** The Transactions screen opened its custom-range sheet over a list another screen had just navigated it to. Fixed at the root: the sheet now belongs to the `Picker`'s *binding setter*, which only runs when the control writes it.
5. **UTC bucket bounds handed to a `Calendar.current` screen shift by a day at each end.** A July bucket arrived as "Jun 30 – Jul 30". `TransactionsRequest` now carries the day across as year/month/day components rather than as an instant, and extends `through` to the end of its day (the screen filters `occurred_at <= through`, so a midnight bound dropped the whole last day).
6. **Finding 3 of the session above came due.** Handing the Transactions screen a filter *and* a period in one turn changes its `.task(id:)` twice, cancelling the first load — and that screen was one of the ~22 unaudited `UserFacingError.describe` call sites. It rendered "Something went wrong" under a perfectly loaded list. Fixed there with `UserFacingError.isCancellation`. **The remaining call sites are still unaudited.**
7. **A dashed segment two percent wide is not a dashed segment.** The locked decision "a negative account inside a positive currency is an outlined segment, never stacked" first shipped as a second scaled bar; a credit card offsetting 2% of a currency rendered as a three-point dash that read as a rendering fault. Replaced with a labelled outline swatch — legible at any magnitude, and the figure beside it says what the length could not.
8. **An average is not a partial period.** `MetricKind` originally had `isFlow`, which made the FX widget default to the last *closed* bucket and open showing last month's rate. A sum over a period is partial mid-month; an average is scale-free and directly comparable. Renamed to `currentBucketIsPartial`, with a regression test.
9. **`fx_rates.rate_to_eur` is misnamed** (pre-existing, no numerical impact). `sync-fx-rates` fetches Frankfurter `?base=EUR`, which returns *units of X per EUR*, and writes it to a column called `rate_to_eur`. `fx_convert` and `LocalFxConvert` both read it as per-EUR, so the arithmetic is correct and consistent end to end — only the name is wrong. It cost most of an hour to confirm the FX widget was not inverted. Renaming it is a migration nobody has scheduled; knowing about it is the point of this entry.

## Verification

- KeepoCore 173/173, KeepoTests 128/128, `swiftlint --strict` clean (bar one pre-existing violation in uncommitted work in `LocalAccountRowTests.swift`).
- New DB-backed suite `DashboardCashflowScopeTests` pins the transfers rule at all three scopes against a purpose-built two-pocket fixture (`DashboardScopeFixture`) — deliberately separate from `RefereeFixture`, whose numbers are pinned to a real Postgres capture and must not gain rows.
- Every widget exercised on the iPhone 17 Pro simulator in both states, including the Cashflow → Transactions tab switch (the handed-over period and category matched the widget's own figure to the cent).
- Not performed: real-device walkthrough; a measurement pass on series cost (see below).

## Notes for whoever picks this up next

- **The series cache is in-memory and correct by construction**, not a persisted rollup: a write bumps the refresh token, every key minted afterwards is a different key, and stale entries become unreachable rather than wrong. A persisted version drops in behind `DashboardMetricSeries.load` without any widget changing, *if measurement ever says so*. Nobody has measured yet.
- **One read can answer several metrics.** `flows` computes money in, money out and the net in one pass and files all three under their own requests, so the Cashflow chart's three series cost one query per bucket. `DashboardWidgetKind.companionMetrics` is how a widget declares the extras — as part of its *definition*, not wired up in `.onAppear` (which raced the first load and shipped a chart with both bar series missing).
- **Where daily granularity would have been cheap, and why it is still not built.** The user's instruction was to report this and never implement it. FX is the only metric where daily is nearly free: `LocalDashboardQueries.fxTrend` already walks day by day and the bucket layer just averages, so a `.day` case would add no queries — the per-day rate is already being computed and thrown away. Every other metric is the opposite: a daily net-worth point recomputes every account's balance and converts it, so a year of daily points is ~365× the most expensive read on the dashboard. Cashflow sits in between (one transaction scan per bucket, so daily is ~30× monthly). **Weekly remains the floor. Do not add `.day` to `MetricGranularity` without the user asking.**
- Currency Exposure's expanded tile is deliberately sparse for a user holding two currencies. That is the declared 4×2 size and it fills with the account lists open; do not "fix" it by shrinking the widget.

---

# Dashboard polish pass — 2026-08-25 (later)

Six items raised from device use, after the widget redesign shipped.

## Delivered

1. **Grid spacing is uniform, structurally.** The gap around "Transactions Next 2 Weeks" looked tighter on device but correct in the simulator. The arithmetic was innocent — the gap between any two tiles is exactly `spacing` for every row span (now pinned by `DashboardGeometryTests`). The cause was that tile being the only half-height one (`rows: 1`): at a larger Dynamic Type setting its content no longer fitted the ~27pt a single row leaves after padding and header, and `WidgetChrome` painted its background at the frame size without clipping, so the overflow drew straight through the gutter. Two fixes: `WidgetChrome` now clips to its rounded rect, and `upcomingBills.baseSize` is `.wide` like every other widget (`expandedSizes` grew to match). The collapsed tile gained the day-ring carousel with the extra room.
2. **The trend badge stays below the metric, in a tinted pill.** It used to sit below when collapsed and jump into an `HStack` beside the figure when expanded. New shared `MetricHeadlineBlock` owns the arrangement, with a `trailing` slot for what legitimately belongs on the figure's line (the bucket label, Investing Ratio's drivers chevron). Pill is tinted by the trend, not flat grey, so up/down/unknown still reads without the caption.
3. **Type up one step across the dashboard, 44pt targets.** `caption2 → caption`, `caption → subheadline`, the 9–10pt fixed sizes → `caption2`, headlines up ~15%. Every row, segment, chevron and picker now carries a ≥44pt hit area via `WidgetStyle.minimumTarget` — as a `contentShape`, not visible furniture, so a 44pt capsule doesn't swamp a widget header.
4. **Charts scroll horizontally.** Two independent causes, both below.
5. **Expansion centres the tile with two grid rows of clearance** (was one), and only moves a tile that isn't already fully visible.
6. **The timeframe control has a grey capsule border** and bigger segments, so it reads as one control rather than four loose letters.

## Findings

1. **The x axis was `Int` where everything around it was `Double`.** Marks plotted `.value("Period", entry.index)` as `Int`, while `chartXScale` took a `ClosedRange<Double>`, `AxisMarks` took `[Double]`, and `chartScrollPosition(x:)` bound a `Double`. Axis labels still resolved (`Int`'s primitive plottable *is* `Double`), which is why it looked correctly wired — but a scroll-position binding whose type doesn't match the x scale cannot resolve, so every drag was reset.
2. **`chartOverlay` content blocks the chart's own scroll view.** This was the bigger half of item 4. The transparent `contentShape`d plate used for tap-to-highlight is layered over the plot as a *sibling* of the scroll view Swift Charts creates for `chartScrollableAxes`, not a descendant of it. It wins the hit test, and gesture recognizers are only collected from the hit view and its ancestors — so the pan recognizer was never in the chain and no touch on the plot ever reached it. Replaced with `chartXSelection(value:)`. **Interaction changed as a consequence: highlighting is now press-and-hold (and drag to scrub), not tap.** That is the platform-standard resolution — Health, Stocks and Fitness all work this way — and there is no way to keep a tap-anywhere plate *and* scrolling on the same surface.
3. **`scrollTo(y:)` is clamped to the content height at the moment it is called.** The expansion scroll ran inside the same `withAnimation` that grew the tile, so the system clamped it to the pre-expansion content — and on a dashboard already scrolled near its end, that clamp swallowed it entirely and nothing moved. Moved into the animation's `completion:`. An `onScrollGeometryChange` hook was tried first and is *not* sufficient: the content grows gradually over the animation, so the first geometry change fires while it is still short.
4. **The bigger type broke the badge caption on 1-column tiles.** "-2.2 pts vs last month" truncated to "vs last mo…". Investing Ratio and FX Rate now drop the caption when collapsed — truncated text tells the reader less than absent text — and state the comparison in full when expanded.
5. **`Int(_:)` on a non-finite `Double` is a hard trap, not a wrong answer.** Two sites took a `Double` produced by the framework (an inverted scale, a scroll position) straight into `Int(_:)`. Both are now guarded with `isFinite` at the point the value enters, and the scroll-position binding rejects non-finite writes rather than every reader defending itself. Related to the unresolved crash below.
6. **Rounding away from zero dropped taps on the newest bar.** The x domain runs half a slot past the last bucket, so a tap on the outer half of the newest bar resolved to `buckets.count` and was silently rejected. Clamped into range instead.

## Verification

- KeepoCore 174/174, KeepoTests 132/132, `swiftlint --strict` clean (bar the same pre-existing violation in uncommitted work in `LocalAccountRowTests.swift`).
- New `DashboardGeometryTests` pins the gap between adjacent tiles at exactly `spacing` for every row span, at five screen widths — the property item 1 was actually asking for. New `everyBaseSizeIsOneWidgetTall` stops the half-height tile coming back.
- On the iPhone 17 Pro simulator against real local data: horizontal scroll confirmed on the FX chart at weekly resolution (axis moved from "12–Jul 18 / 2–Aug 8 / 23–Aug" back to "21–Jun 27 / 12–Jul 18"); press-and-hold scrub confirmed (headline 0.9255 → 0.8713, badge → "vs prev. week average"); expansion scroll confirmed on Cashflow, which now lands fully visible.
- **Not verified:** the original device report (spacing under a large Dynamic Type setting) — the fix is structural but was reproduced by reasoning, not on a device with that setting.

## Still open

- The `EXC_BREAKPOINT` the user hit tapping the current month's bar in the Cashflow chart is **unresolved** — no console message was available. Ruled out: the breakdown query (already run for that bucket when the chart loaded), the empty-donut path (a resolvable net means every category total resolves), NULL category columns (inner join), duplicate bucket keys. The two unguarded `Int(_:)` conversions in that path have since been guarded, and the tap plate that ran the arithmetic is gone entirely, so the most likely candidates no longer exist — but this was not confirmed against the actual failure.
- The ~21 other `UserFacingError.describe` call sites still have the unguarded-cancellation gap.
- `fx_rates.rate_to_eur` is still misnamed.

---

# Currency flags — vendored artwork (2026-08-25, later still)

`CurrencyBadge` drew flags as emoji. It now draws HatScripts' `circle-flags`
SVGs out of the app bundle. `CurrencyRegion`'s own header had predicted this
swap ("a real flag image set replaces this later — every caller goes through
`flag(for:)`"), and that held: the change was one function plus the badge.

## Delivered

- `App/Resources/Flags.xcassets` — 265 imagesets, `flag-<alpha2>`, one per
  ISO 3166-1 alpha-2 region. 231 KB in the repo.
- `App/Resources/ThirdPartyLicenses/circle-flags/` — the MIT licence plus a
  README recording the upstream commit, what was and wasn't taken, and how to
  refresh. Wired into `project.yml` as a **folder reference**, so it ships
  inside `Keepo.app` with its path intact.
- `CurrencyRegion.flag(for:)` (emoji) → `flagAssetName(for:)` (`"flag-us"`).
  The region rule and the `nil`-rather-than-a-wrong-flag contract are unchanged.

## Findings

1. **A 512pt intrinsic size costs 28 MB of `Assets.car`.** Asset catalogues
   rasterise 1x/2x/3x fallbacks from the SVG's intrinsic size *even with*
   `preserves-vector-representation`, so each flag was also being stored as a
   1536px bitmap. Rewriting the root `width`/`height` to 48 (leaving `viewBox`,
   so the artwork is untouched) took it to **1.6 MB** — a 17× reduction for a
   two-attribute change. Worth checking on any SVG that arrives at icon scale.
2. **All 265 regions are bundled, not just today's 31 currencies.** The
   supported set lives in Postgres and reaches the client by sync; there is no
   compile-time list to update. Bundling only the current currencies would mean
   a future migration silently degrading to the grey globe on a shipped build.
   The whole alpha-2 space is 159 KB of SVG, so the failure mode costs more
   than the bytes.
3. **`Image(_:)` with a name it can't find draws nothing, silently.** Since
   `CurrencyRegion` derives a name from the code's own letters, it will name
   `flag-zz` for a code whose first two letters aren't a real region. The badge
   asks `UIImage(named:)` first and falls back to the globe, so an unknown
   currency looks like every other unknown currency rather than like a hole.
4. **A licence copied as an ordinary resource is flattened to the bundle root**,
   where the next dependency's `LICENSE.md` would collide with it. A folder
   reference (`type: folder` in project.yml) keeps
   `ThirdPartyLicenses/circle-flags/LICENSE.md` addressable.
5. **`eu.svg` is a symlink** to `european_union.svg` upstream (one of ~20).
   Vendored with `cp -L`; a plain `cp` leaves dangling links that build fine
   and fail at runtime for the euro specifically — the app's most common
   currency.

## Verification

- KeepoCore 174/174, KeepoTests 136/136, `swiftlint --strict` clean (bar the
  same pre-existing violation in uncommitted work in `LocalAccountRowTests`).
- New `CurrencyFlagAssetTests` (app target) checks each of the 31 supported
  currencies against the **real bundle**, spot-checks ten regions no current
  currency uses, and fails if the licence stops being bundled. The set list
  lives there and nowhere else — `CurrencyRegionTests` in KeepoCore tests the
  region *rule* only, since a list checked without a bundle cannot catch a
  missing flag.
- On device simulator: EUR and USD render as crisp circles at 22pt (FX Rate
  pair) and 24pt (expanded Currency Exposure rows).
