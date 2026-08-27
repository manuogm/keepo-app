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

---

# Dashboard polish pass 2 — 2026-08-26

Second round of user-driven refinement on the widget redesign, plus the
resolution of the `EXC_BREAKPOINT` crash that had been open since 2026-08-25.

## The crash (was "still open")

**Root cause: a donut with exactly one slice.** `SectorMark` given a single
value spans the whole circle, so its start and end angles are the same angle.
`angularInset: 1.2` then has to cut a gap out of a shape with no gap, and
`cornerRadius` has to round a corner between an edge and itself. Swift Charts
resolves that to a non-finite number and converts it to `Int` — a hard trap:

```
Swift/IntegerTypes.swift:8835: Fatal error: Double value cannot be converted
to Int because it is either infinite or NaN
```

The whole stack is inside `Charts` under `CanvasDisplayList.updateValue()`;
no frame of ours appears, and the `.ips` carries no message. It reproduced as
"tapping a bar in Cashflow kills the app" because tapping a bar reloads the
breakdown, and a period with one category reduces the donut to one slice. The
user's original report — "tapping on this month's bar" — was that exact case.

Fixed in `DonutChartView`: one slice is drawn as a stroked `Circle`, not as a
sector. A full circle has no neighbour to be separated from, so an angular
inset has nothing to mean; the ring is the honest shape and cannot go
non-finite.

**How it was found**, since none of it was visible from the crash report:
`xcrun simctl launch --console-pty` prints the Swift runtime's fatal-error
message, which the `.ips` does not carry. Then bisect by widget — Net Worth
(line) fine, Investing Ratio (bars) fine, Cashflow only — then instrument the
two `Chart`s on screen with `print` in the body. The donut's slice count going
2 → 1 immediately before the trap was the whole answer.

## Programmatic scrolling was landing an inset short

`ScrollGeometry.contentOffset` and `ScrollPosition.scrollTo(y:)` are **not the
same coordinate space**: the former is measured inside the content insets, the
latter from the top of the content. On Home they differ by 116pt (status bar +
header). Reading an offset and writing it back therefore moved the dashboard
116pt too far up, every time.

It never looked like a coordinate bug — the expansion scroll moved, and moved
roughly the right way, it just always stopped one header short. The symptom was
"an expanded widget sits too close to the tab bar", which reads as a margin
problem, and increasing the margin changed nothing (see below). Measured by
asking for 652 and watching `contentOffset` settle at 536.

`DashboardScrollGeometry` now carries `insetTop` and owns the conversion
(`scrollTarget(for:)`); both call sites — expansion scroll and drag
auto-scroll — go through it.

## Expansion scroll: centre when the margin can't fit

The clearance below an expanded tile is three grid rows. The tallest widget is
six rows, and 6 + 3 rows exceeds the viewport, so `clearingBottom` always won
and resolved to the cap — pinning the tile's top to the top of the screen with
all the slack dumped underneath. `scrollToFit` now checks whether the margin
*fits* first, and centres the tile when it doesn't. Raising the margin 2 → 3
rows on its own did nothing at all, for this reason.

## Charts

- **Pinch-zoom removed.** Two-finger gesture inside a card inside a scrolling,
  reorderable grid: fussy to start, easy to trigger by accident, competing with
  the horizontal scroll for the same touches. W/M/Y says the same thing in one
  tap. `SeriesWidgetState.didPinch`/`zoom(to:)`/`applyZoom()` went with it —
  the granularity now has exactly one source, so the flag that stopped the two
  controls undoing each other has nothing left to arbitrate.
- **Tap to select.** `chartXSelection` alone gates selection behind a long
  press on a scrollable chart (it must, or scrubbing would fight the pan).
  `.chartGesture { proxy in SpatialTapGesture().onEnded { proxy.selectXValue(at:
  $0.location.x) } }` adds a plain tap *alongside* the scroll, which the
  `chartOverlay` plate that was removed last round could never do.
- **Axis labels are centred on their ticks** via `AxisValueLabel(anchor: .top)`.
  With custom content the default anchor puts the label's *leading* edge on the
  tick, so every label sat half its own width right of the bar it named —
  confirmed with a temporary `AxisGridLine`: gridlines landed exactly on the
  marks, labels landed 14pt right of the gridlines.
- **Every bucket gets a label**, written at whichever form fits its slot:
  `MetricGranularity.axisLabelCandidates` returns a ladder (`["Jan", "J"]`,
  `["2026", "'26"]`, week → both ends → start → day) and `ChartAxisLabels.fitted`
  measures against `UIFont.preferredFont` and picks one tier for the whole
  axis. Replaces thinning labels + insetting them off their own buckets.
- **Half a bucket of peek** past the visible window (`chartXVisibleDomain(length:
  visibleLength + 0.5)`) whenever there is more data, so the scroll is visible.
- **Bars**: capped-proportional width (58% of slot, max 16pt) with fully rounded
  ends (`cornerRadius(barWidth / 2)`).
- **Dotted gridlines on line charts only.** A bar is already a vertical mark
  standing on its own label; a rule through it takes contrast away. Every
  bucket where the slot is ≥ 24pt, every other below that.

## Chrome

- Title: `.caption`, no glyph, and the header is **exactly as tall as its
  title** in both states. Pinned to a constant instead, the title stopped
  moving but sat centred in a taller row, which put visible dead space above
  it. The timeframe filter overflows the row rather than setting it, and still
  sits in the `HStack` so it reserves its width.
- `View.hitTarget(_:)` — grows a touch area to 44pt via an overlay, so HIG's
  minimum no longer drives layout height. This is what let the filter become a
  tab bar.
- Trend badge: caption never dropped or abbreviated; `ViewThatFits` wraps it to
  two lines on a 2×1 rather than truncating. FX Rate's collapsed tile carries
  no badge at all (user's call — the pair badges plus a pill made three stacked
  objects on one column); it returns when expanded.
- Legibility scrim behind figures drawn over a chart: a gradient **in the
  card's own fill**, not a material. A material lightens what it covers, so the
  top of the card came out a different tone from the bottom and looked like a
  panel. Never bleeds upwards — it is a background of the *content*, which is
  laid out after the header, so anything above the content's top paints over
  the title (it did).
- One type scale: `WidgetStyle.metric` / `.metricExpanded` for every headline.
  The six had drifted to 36/34/30/28. All spacing is on a 4pt grid; card
  padding is 16.

## Widget guide (ⓘ)

New `WidgetGuide` in KeepoCore: one-line summary, a **visual key** (marks drawn
again with two or three words each), and one-line notes with SF Symbols. First
version was three paragraphs of prose and the user rejected it as too much to
read mid-task — the tests now cap summary/key/note lengths so it cannot drift
back. Reached from the widget's header **and** from the catalogue, which
dropped its per-row description line in favour of the same button.

## Catalogue

Three collapsible groups — Keepo Widgets (addable), Your Widgets (empty,
future), Used Widgets (already placed, shut by default) — each with its own
blank state. "Already on your dashboard" stopped being an unavailability
*reason* and became a group; `unavailableWidgets` now carries missing-data
reasons only, and `placedWidgets` is separate.

## Verification

- KeepoCore 183/183, KeepoTests pass, `swiftlint --strict` clean bar the same
  pre-existing violation in uncommitted work in `LocalAccountRowTests`.
- On device simulator: tap-to-select on line and bar charts, horizontal scroll
  (labels shift a week), peek at both edges, expansion centring, catalogue
  groups, both ⓘ entry points, and the previously-crashing June bar.

# Cashflow Breakdown redesign — 2026-08-26

Second pass on this one widget only, to the user's spec.

## Collapsed

- The period moved **into the header**, as a bordered pill in the exact slot
  the timeframe filter takes when the widget opens. The two are mutually
  exclusive by construction (`SeriesWidgetChrome.collapsedAccessory`, read only
  while closed) because they answer the same question. Both draw on the shared
  `WidgetHeaderTrack` so the header does not change shape on expand.
- That is also what fixed the headline size. It was already
  `WidgetStyle.metric`, but it shared its line with the period label, so
  `minimumScaleFactor` shrank it — Cashflow's net was visibly smaller than
  every other tile's headline while nominally being the same number.
- `CashflowPeriod.label` for a month now carries the year ("July 26"). Reads as
  redundant in August and is the whole point in January.
- "kept x% of what came in" is gone, and its guide note with it.
- Money In / Money Out are now a **bar diverging from the tile's centre**:
  in grows leftward, out rightward, both scaled against the larger of the two
  (`CashflowMetrics.fill`, unchanged), each with its direction over its own
  total at the outer end. The left half is the shared `WidgetFillBar`
  mirrored with `scaleEffect(x: -1)` — not a second bar type, so track weight,
  corner and the leftover-track rule cannot drift between the halves.
- Those totals use the new `MoneyFormatter.compact`: no cents under a
  thousand, ICU compact notation past it ("$4.2K"). New `MoneySignStyle
  .magnitude` — the word directly above already names the direction, so
  `.ledger`'s `+` would be a third statement of it.

## Expanded

- The highlighted bucket's name is gone from the headline row; the timeframe
  filter governs.
- The donut is gone, replaced by **one full-width bar** under the divider,
  segmented per category in the category's own colour, largest first. Shares
  are taken against the direction's SQL-computed total (money rule 3), never a
  client-side sum — which is also what makes the honest case right: a category
  with no rate contributes no segment while the denominator still counts it,
  so the bar stops short of the end by exactly the unresolvable share.
- The In/Out toggle moved below the divider and became a **nav row** directly
  on top of that bar: In far left, Out far right, the selected side's total
  centred. Centring is two equal flexible frames rather than an overlay, so a
  long figure pushes the buttons instead of drawing over them.
- The list gets the full width back, which is what stops long category names
  and amounts wrapping.
- `DonutChartView` deleted — nothing else drew one. (Its single-slice crash fix
  is recorded in lessons-learned; the failure mode outlived the file.)

## Verification

- KeepoCore 187/187 (four new `MoneyFormatter.compact`/`.magnitude` cases),
  build clean, `swiftlint --strict` clean.
- On device simulator: collapsed pill and diverging bar, expand, nav row
  centring, In/Out switch, and the one-category case that used to be the
  donut's crash — now just a single full-width segment.
- `Package.swift` macOS floor 13 → 15: `FormatStyle.notation` is macOS 15 /
  iOS 18. Host-only concern; the app has always been iOS 18.

# Cashflow flicker, privacy mode, Currency Exposure — 2026-08-26 (later)

## The In/Out toggle's "flicker"

Diagnosed rather than guessed at: prints on the load key, the scroll-position
binding, the load path and the chart body showed **no reload and no data gap**
on a direction change — one re-render, all three series present. So it was not
the staged companion load (which *is* visible on first expand: net, then money
in, then money out, three renders).

It was the animation. The toggle ran inside `withAnimation(.snappy)`, `.snappy`
is a spring, and what was being sprung is a **colour** — the two bar series
trade full strength for `opacity(0.3)`. A spring overshoots; an overshoot on an
interpolated colour clamps at each end and comes back, so both series bounced
past their target and settled. Confirmed by slowing the animation to 4s and
capturing frames through `simctl io … screenshot` in a loop: mid-animation the
bars sit at intermediate tones and the breakdown's text is cross-fading against
itself, two amounts stacked on the same line.

Fixed by not animating the change at all. Consistent, too: the W/M/Y segments
in the same card's header have never animated, and these are the same control.

## Privacy mode

Only the *headline* on each tile honoured it. Everything smaller stayed
readable, so switching privacy on blanked one number per widget and left the
breakdown fully legible — a larger font, not privacy.

New `PrivateText` (+ `PrivacyMask.hidden`) in `App/Common/Components`. It
replaced the four inline `isPrivacyMode ? "••••" : …` ternaries that were
already there (`TransactionRow`, `AccountRowView` ×2, `MetricHeadline`) and now
carries every money figure on the dashboard: Cashflow's Money In/Out, the
expanded direction total, category amounts, upcoming rows, currency totals and
account balances. **Shares are not masked** — a percentage says how the money
splits, not how much there is, and blanking it would leave a bar explaining a
breakdown whose rows had all become bullets.

## Currency Exposure

- **One hue, ranked.** `CurrencyColor` (a per-code hue via `StableSeed`) is
  gone, replaced by `WidgetPalette.shade(rank:)` — a ramp of the neutral chart
  colour, darkest for the largest share, floored at 0.25 so the fifth currency
  and beyond stay visible. Four unrelated hues on a 2×1 read as four
  categories; the bar only ever claimed "this one is bigger than that one".
- Collapsed: bar moved to the bottom edge, and the caption above it became a
  row of flag + code + share. One currency shows nothing; two or three show
  themselves; more than three show the second plus a globe-badged "REST"
  carrying the **combined** share of the remainder, so the row's percentages
  still add up with the headline's.
- Expanded: a closed currency's bar is **its share of everything held**, in
  its shade from the collapsed tile — the length matches the percentage
  printed beside it and the shade is what lets someone recognise the band
  they tapped. It filled the whole track at first, which said nothing and
  contradicted that figure. Opening it switches the denominator: the bar
  fills the track and subdivides by account in the user's own colours,
  matching the per-account percentages in the list, which are shares of that
  currency.
- The dashed "owed" swatch and its caption are gone, and with them
  `FillSegment.isNegative`. A card offsets holdings rather than being a slice
  of them, so it had no honest length, and at a realistic magnitude it drew as
  a three-point dash too short to show a dash pattern. Those accounts are in
  the list with a red figure and a "—" share, which says it without a key.
- Investment accounts wear their badge **under** the name; beside it, it
  pushed long names into an ellipsis.
- `CurrencyAccountLocal` gained `kind` (query, sample data and tests updated) —
  presentational only, never near a balance (money rule 1).
- The guide's donut vocabulary went with the donut: `.slice`/`.restSlice` are
  removed from `WidgetGuideMark`, and the key now explains the ramp.

## Verification

Build clean, `swiftlint --strict` clean, KeepoCore 187/187, KeepoTests pass. On
device: collapsed ramp and minority row, expanded shades, opening a currency
swapping to account colours, the investment badge, the red net-short row, and
privacy mode blanking every figure while leaving shares.

## Staged load (the second flicker)

Cashflow's chart is three series from one read, and `loadVisibleWindow`
assigned each as it arrived. Every `await` is a suspension point, so each
assignment published on its own and the chart drew three times per load — net
line alone, then one bar series, then both. Instrumented before and after:

```
before   net:3 → moneyIn:3,net:3 → moneyIn:3,moneyOut:3,net:3
after    (nothing) → moneyIn:3,moneyOut:3,net:3
```

Fixed by gathering the companions into a local and assigning `points`,
`companionPoints` and `loadedWindow` with no `await` between them, so SwiftUI
sees one complete set. Replacing `companionPoints` wholesale rather than keying
into it also drops entries left over from a previous granularity.

A fourth publish went with it: the default highlight was settled *after* the
load, in its own render, so the chart drew once with every bar dimmed and again
with one lit. It only reads `buckets`, so it now happens in `rebuildBuckets`
beside the domain it indexes into.

**Note for whoever reads the diff:** `SeriesWidgetState.swift` briefly lost the
pinch-zoom removal from the earlier polish pass — a `git checkout` used to strip
debug prints reverted the whole file to HEAD. Restored by hand (`didPinch`,
`zoom(to:)`, `applyZoom()` and their doc comments are gone again). `MetricZoom`
in KeepoCore stays: `MetricTimeframe` still uses it to derive a granularity for
custom and all-time ranges.

## Per-widget polish pass 3

Three widgets, all layout and formatting — no new queries except one that got
narrower rather than wider.

### Investing Ratio

- The collapsed bar rotated into a **vertical bar up the right-hand edge**,
  full content height. A ratio is a height, not a distance, and it rhymes with
  the run of columns the widget becomes when it opens.
- Added "Across N accounts" under the trend badge, collapsed only. Expanded it
  would look like a property of the highlighted bar rather than of today.
- `LocalDashboardQueries.hasInvestmentAccounts` → `investmentAccountCount`, and
  `InvestingRatioMetrics.hasInvestmentAccounts` is now derived from it. It was
  already a `COUNT(*)` folded to a `Bool`; two callers now want different
  things from the same number, and asking twice would have been two queries for
  one fact. `DashboardCapabilities` still stores the `Bool` — it has no use for
  the count.
- Wording: "Across 3 accounts", not "3 investment accounts". The tile leaves
  ~145pt once the bar takes its column and the longer form only fits by
  shrinking the type; the widget's title already says "investment".

### Transactions Next 2 Weeks

- The in/out counts moved onto the headline's own line, at the far end, and the
  day rings grew 40 → 46pt. The counts had a line to themselves and it cost the
  rings ~20pt of height for two short labels that fit in space the figure was
  already leaving empty.
- Collapsed and expanded now share one `header(_:size:)`, so the only thing
  that changes on expand is the figure's size.

### Currency Exposure

- Collapsed: headline badge 22 → 26, minority row 18 → 24 with `.caption`
  shares, and 6pt of extra air above the bar so the row stops reading as a
  label *on* it.
- The minority row **sizes itself to its entry count** (24pt disc/`.caption` for
  one, 18pt/`.caption2` for two, with tighter spacing). Two entries plus their
  percentages do not fit 144pt at the larger size — and could not before this
  pass either: the catalogue's three-currency preview had been rendering
  "USD 2…". The disc is what steps down rather than the type, because it is the
  one element `minimumScaleFactor` cannot shrink, so at a fixed diameter every
  point it takes comes out of the numbers.
- Expanded: the bar moved **inline**, between the currency badge and its
  figures. It used to sit on its own line under the row, which made a currency
  two lines tall and put its bar nearer the *next* currency's badge than its
  own. A net-short currency draws a `Spacer` in the bar's place so its figures
  still line up with everyone else's.
- **Native figure leads, converted figure follows**, for slices and accounts
  alike — the one place on the dashboard where that order is inverted, because
  it is the one widget whose whole subject is that the money isn't in the base
  currency. Both are `MoneyFormatter.compact` ("$49.1K"): two money figures, a
  percentage and a bar share one row. VoiceOver reads the unabbreviated figure.
  A slice already in the base currency shows one figure, not the same number
  twice.
- A guide note says shares are worked out on the converted values.
- `CurrencyExposureLocal` gained `currencyInfo` (replacing the bare `currency`
  string, which is now computed from it) and `nativeAmountE4`. The slice must
  be able to round itself by its own `minor_unit` (money rule 2) rather than
  reaching into its first account.
- `DashboardSampleData.currency(_:_:)` no longer takes a stated total — both
  totals are summed from the accounts it is given, so a preview can no longer
  disagree with itself. The foreign samples now carry distinct native amounts,
  so the catalogue shows the two-figure row the real widget draws.
- Split into `CurrencyExposureWidget+Expanded.swift`; the file went past
  SwiftLint's 400-line `file_length` and the seam was already there (`the
  collapsed tile is one figure with a bar; the expanded one is a list`).
  `openCurrencies` and the formatting helpers became internal for it.

**Carried, not fixed:** `LocalDashboardQueries.currencyExposure` sums its
per-account balances in Swift to build each slice's totals. That predates this
pass — `amountBaseE4` was already built that way — and `nativeAmountE4` follows
the same mechanism in the same place rather than adding a second pattern. It is
still a soft spot against money rule 3; moving the grouping into SQL means
restructuring `accountBalance`, which is a change of its own.

### Verification

Build clean, `swiftlint --strict` clean, KeepoCore 187/187, KeepoTests pass. On
device: all three collapsed tiles, Investing Ratio and Transactions expanded,
Currency Exposure expanded with a currency opened (account colours, investment
badge, the red net-short row with its "—" share), privacy mode blanking both
figures in every row while leaving shares, the guide sheet, and the catalogue
previews for all six widgets.

## Per-widget polish pass 4

### Charts — the highlight flicker, fixed once

`HighlightableChart.select` sprang the highlight change with
`withAnimation(.snappy)`. Almost everything a highlight changes is a
**colour** — every mark moves between dimmed and lit through
`WidgetPalette.mark` — and a spring overshoots by design. An overshoot on an
interpolated colour has nowhere to go: it clamps at the end of the ramp and
comes back, which reads as the mark flashing. Same root cause as the Cashflow
direction toggle.

Now one `easeInOut(duration: 0.2)` constant, in `select`, which is the only
place any dashboard chart's highlight is set — so Net Worth, Investing Ratio,
Cashflow and FX all got the fix at once. Deliberately still *animated*, unlike
the Cashflow toggle: the headline rolls its digits through
`contentTransition(.numericText())`, which needs a transaction, and a line
chart's point mark really does change size. Both want a curve; neither wants
bounce.

Verified by slowing the constant to 3s and capturing 60 simulator frames while
tapping a bar: the tapped bar darkens and the previous one lightens
monotonically across the whole transition, with no reversal at any frame.

### Investing Ratio

- Collapsed: "N Accounts" at `.subheadline`, on the tile's own baseline beside
  the bar. Under the trend badge it was a third line in a stack already two
  deep and read as part of the badge's caption.
- Expanded: the drivers chevron sat at the far end of a full-width tile,
  200 points from the percentage it belongs to. `MetricHeadlineBlock`'s extra
  slot moved **before** the `Spacer` (and is now called `adjacent`), so it is
  drawn against the figure. It cannot push the badge anywhere — the badge is
  on the next row of the `VStack`, not in that `HStack`.
- The chevron's 44pt `frame` became `hitTarget()`. A real frame made the
  headline's row 44 points tall, so the expanded trend badge sat visibly lower
  than the collapsed one — a gap that appeared on expand and belonged to
  nothing on screen. (Same lesson the W/M/Y segments already carry.)
- The drivers open **along the figure's line**, to the right of the chevron,
  instead of below the badge. Below, they cost the chart a row of height every
  time they were shown: asking why the ratio moved changed the picture of how
  it moved.

### Networth Analysis — one definition, two states

The figure, the badge and the trajectory were computed three different ways:
today's balance, the balance on this day last month, and ninety *daily* points
bucketed after the fact. So the collapsed badge compared today against the same
day last month while the expanded one compared this month-end against last
month-end, and the two could disagree about which way net worth had gone — and
the collapsed sparkline was a jagged three-month line under a smooth
twelve-month chart.

`netWorthMetrics` now takes **twelve month-end readings** via
`MetricGranularity.month` + `evaluationDate`, the same rule
`DashboardMetricSeries` uses for the expanded chart, and answers all three
questions out of that one array. The states cannot drift, because there is one
definition. It is also cheaper: 12 net-worth computations per refresh instead
of 90.

Confirmed on device: collapsed and expanded both read `$66,513.56 · ↗1.5% vs
last month` with August highlighted, and the two curves are the same shape.

Dead code removed with it: `DashboardDataLoader.netWorthSeries`,
`DashboardDataLoader.fxTrend` (nothing called either — leftovers from before
`DashboardMetricSeries`), the private daily-`series` helper, and
`LocalMoneyConversion.netWorthSeries`. **`DateBucketing` in KeepoCore now has
no app callers** — it keeps its own tests and public API; deleting it is a
separate call.

### Transactions Next 2 Weeks

Rings moved directly under the figure with the slack below them. Pinned to the
bottom they sat about forty points lower than the same rings expanded, so
expanding slid the whole fortnight upwards past the figure — the one thing on
screen that had not changed appeared to move the most. The in/out counts read
**under** the rings when collapsed (they summarise the strip above them);
expanded they stay on the headline's line, where the rings are followed
immediately by a list that needs the width.

### FX Rate

- **The pill could end up empty.** The default pick was keyed on the currency
  list alone, so it fired once at launch and never again — and collapsing calls
  `reset()`, which restores the kind's default config, and that has no currency
  in it. The tile came back from its first expansion showing a globe and a
  dash with nothing that could ever put a currency back. Keyed on the *choice*
  as well now, so the reset is a change it can see.
- The base currency is drawn as a pill too, at a lighter weight and dimmed —
  a bare badge beside a bordered one read as an oversight. Tapping it opens a
  popover: "USD is your default currency" and "Go to settings ›".
- That link needed somewhere to go, so the Profile tab's `NavigationStack` is
  now driven by `AppNavigation.profilePath` and `ProfileView`'s rows are value
  links into one `navigationDestination` table. A row tap and a programmatic
  `openProfile(.preferences)` land on exactly the same view.
- The slash is `.title3` with 8pt either side. It is the only thing saying the
  two currencies are a *ratio* rather than a list.
- Both pills share one `CurrencyPill` modifier, and the quote pill opts out of
  animation (`.transaction { $0.animation = nil }`) and uses `hitTarget()`
  rather than a 44pt frame — the two structural reasons a label swapping three
  letters could re-lay-out over a visible interval. **Not reproduced on this
  data**: the dev account holds one non-base currency, so the picker has a
  single option and the switch can't be exercised. Worth re-checking on an
  account with three or more currencies.

### The FX rate is not inverted — the seed was

Reported as "the rate calculation is wrong". It isn't, and the evidence is
worth keeping:

- `sync-fx-rates` fetches Frankfurter `?base=EUR`, which returns **units of the
  currency per 1 EUR**, and stores it verbatim in `rate_to_eur`.
- `fx_convert` / `LocalFxConvert` compute `amount / rate(from) * rate(to)`,
  which is correct for that direction and is exactly the EUR-pivot the report
  described (`GBP/USD = GBP/EUR × EUR/USD`).
- On device: Pension €18,900 renders as $17,500, which is ×0.9255 — the stored
  rate used as USD-per-EUR. Inverted it would have shown $20,421.
- `version-logs/phase-18-log.md` §5 states the same convention, pinned by a
  pgTAP test.

The number on the dev device is a **placeholder**, and provably so: `fx_rates`
held 75 rows over 75 consecutive calendar days — eleven Saturdays and eleven
Sundays among them — all tagged `source = 'ecb'`. The ECB publishes on business
days only, so a gapless daily series cannot have come from it. The widget's
`0.9485` is the honest August mean of that series once `fx_rate_on` carries the
last row (19 Aug, `0.9255`) forward over the seven days to the 26th:
`(0.957 × 19 + 0.9255 × 7) / 26 = 0.9485`. Every step checks out; the input
does not. Settings → Data & Privacy → sync exchange rates replaces it with a
400-day Frankfurter pull.

What *is* wrong is that the column is named for the opposite direction, and
that the seeds state their numbers in that opposite sense. `supabase/seed.sql`
had USD at `0.92` — read correctly, "a euro buys 92 cents" — so every dev
dashboard has been quoting EUR/USD about 20% low. Fixed to `1.1654`, with the
direction spelled out. `LocalMoneyRefereeFixture`'s JPY `0.0060` is the same
mistake but is pinned to a captured Postgres run and asserts nothing, so it
carries a comment rather than a new value.

**Still open:** renaming `fx_rates.rate_to_eur`. It is a migration plus
`supabase gen types swift` plus the local schema and the sync column list, and
it is the root cause of everyone reading this backwards — twice now.

### Verification

Build clean, `swiftlint --strict` clean, KeepoCore 187/187, KeepoTests pass. On
device: all six collapsed tiles, Net Worth and Investing Ratio expanded with
matching badges, bar highlighting frame-by-frame, the FX popover and its push
into Preferences with a working back button.

## `fx_rates.rate_to_eur` → `units_per_eur`

The rename the previous entry left open, done. **No values change** — every
stored number already meant what the new name says.

Settled first, against the live API rather than from memory. The exact
endpoint `sync-fx-rates` calls answers:

```
GET api.frankfurter.dev/v1/2026-08-24..2026-08-26?base=EUR&symbols=USD,GBP
{"amount":1.0,"base":"EUR","rates":{"2026-08-26":{"GBP":0.85613,"USD":1.1669}}}
```

`amount: 1.0, base: "EUR"` — units of the currency **per one euro**. GBP
lands at 0.856, which is why a sub-1 value reads like an inverse and isn't.
That is what `fx_convert`'s `amount / rate(from) * rate(to)` requires, and
what the column has always held.

Migration `20260905100000_fx_rate_units_per_eur.sql`:

- `alter table fx_rates rename column`.
- `upsert_fx_rate` **dropped and recreated** — Postgres cannot rename an input
  parameter through `CREATE OR REPLACE` ("cannot change name of input
  parameter"), and the Edge Function calls it with named arguments.
- `fx_rate_on` and `pull_changes` restated in full (their bodies name the
  column, and a function body resolves at run time). `pull_changes` keeps its
  `::text` override — `to_jsonb` renders `numeric` as a JSON *number*, which
  supabase-swift would decode through `Double`.
- `fx_convert` untouched: it only calls `fx_rate_on`.

Client: `LocalSchemaV1`, `SyncApply`'s column whitelist,
`LocalMoneyConversion.fxRateOn`, `FxRateRepository`, the referee fixture, and
`Generated/SupabaseSchema.swift` — **actually regenerated**
(`supabase gen types --lang swift --local`, then `internal` → `public`, which
is the only post-processing this project applies; confirmed by diffing a fresh
generation against the checked-in file). The generator sorts fields
alphabetically, so `unitsPerEur` moves to the end of `FxRates*` — a hand-edit
in place would have drifted from the next regeneration.

Local devices upgrade through `v7_rebuild_syncable_tables`, the existing
drop-and-repull. A stale device would otherwise keep `rate_to_eur`, lose every
pulled rate to `SyncApply`'s whitelist∩local-schema step, and hit a NOT NULL
violation.

### Verified

Applied to the local stack (`supabase migration up --local`) after a
rollback-wrapped dry run, and the direction checked in SQL:

```
fx_convert(10000,  'EUR','USD') = 11669    -- 1 EUR = 1.1669 USD
fx_convert(1000000,'USD','EUR') = 856971   -- 100 USD = 85.6971 EUR
```

Both match the live API. `pull_changes` mentions the new key and not the old.
pgTAP: `05_fx` and `23_sync_primitives` pass. Upgrade path exercised on device
— the simulator's store rebuilt to `units_per_eur` and re-pulled 75 rates, 5
accounts and 18 transactions, dashboard unchanged.

**One pgTAP failure, pre-existing and environmental:**
`13_ops_platform.sql` test 9, "fx_freshness_check is healthy immediately after
a fresh seed". The local dev database's newest rate is 2026-08-19 and today is
2026-08-26, so the staleness check is correctly unhealthy. That file never
mentions the column, and its own comment says the test assumes a fresh
reset+seed. **Not run: `supabase db reset`** — the local database holds
hand-made dev accounts and 21 transactions that a reset would destroy.

### Deploy order

`supabase db push`, redeploy `sync-fx-rates` (its named argument changed), then
ship the app build. An older client talking to the new schema loses fx rows;
an undeployed Edge Function calling `p_rate_to_eur` gets "function does not
exist".

### Also in this pass

- The FX popover says "base currency", matching the Preferences row it links
  to. One name for one thing.
- **`DateBucketing` deleted**, with its five tests. It derived a weekly/monthly
  granularity from a span, and `MetricGranularity` has replaced every use —
  the last two callers went with the Net Worth month-end change above.
  `app-architecture.md` §5 updated: the "derived from the span, never a user
  control" rule is now stated as history, since the expanded widgets' W/M/Y
  filter reverses it and the collapsed trajectories share those same buckets.
