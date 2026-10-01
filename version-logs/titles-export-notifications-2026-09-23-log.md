# Notification replica, transaction titles, export redesign — 2026-09-23

Written for the next agent. Three items the user asked for together, each
proposed in chat and approved item by item (A1–A2, B1–B5, C1–C5) before any
file changed; the decision record is the workstream section of
`keepo-v1-master-plan.md`. One migration, `20261005100000_a_transaction_has_a_title.sql`,
**pushed to hosted 2026-09-23** (before the client commit, per CLAUDE.md).

---

## A — Onboarding notification cards

`SetupNotificationShowcase.swift` (split out of the step file). Each still is
now the real banner — app icon, bold title, age at the trailing edge, body,
frosted `.regularMaterial` platter — plus iOS's long-press action list as a
second, narrower platter. Copy and actions still come from
`CaptureNotificationCopy.showcase` + `CaptureQuickActions.build`, so a card
cannot promise a shape production does not send.

- **Measured, not guessed.** From the user's device screenshot: icon 32pt
  (`Size.icon`), radius 20 (`Radius.surface`), insets `l`/`m`, title
  `labelEmphasis`, body `label`. No new token was needed.
- **Material needs something behind it.** Over the flat canvas a material is a
  grey card. A `MeshGradient` of `scopeTotal` → `scopePrivate` in
  **perceptual** colour space sits behind the strip (sRGB mango→indigo passes
  through mud).
- **The wallpaper bleeds edge to edge** (user correction, same day). A rounded
  panel inside the step's margin put two insets between screen and banner;
  bled, the banner has one — the real one — and fits "✅ $12.34 Logged
  successfully" on one line at 19/20 width.
- **`LazyHStack` sized the strip from estimates** and left a band of empty
  wallpaper under every card. Four cards: plain `HStack`.
- `NotificationIcon.imageset` is the app icon downscaled to 32/64/96px, not
  the 1024 original (the Assets.car bloat lesson).

## B — Transaction title

`transactions.title` / `recurring_rules.title`: nullable, CHECK trimmed and
1–80 chars, so "no title" is always null. Every write path carries it —
manual insert, `update_transaction`, `review_capture_transaction`, both
transfer RPCs (both legs, like notes), `materialize_recurring` (every
occurrence, both legs), `fork_one_account`. **Capture never sets one.**

- **Ledger row**: the title replaces the category name (or "Transfer"); the
  category moves to the second line ("Dining Out · Checking") rather than off
  the row. Same rule in the Recurring list and the Upcoming Bills widget. The
  Recurring row splits its second line into a truncatable lead and a
  fixed-size schedule, so a long category/account never eats the date.
- **Form**: bare `TextField("Title")` in `cardTitle`, under the date and above
  the account+amount block, in both forms. "Make recurring" carries it.
  `TransactionTitle.stored` (KeepoCore) is the one trim/cap/nil rule both
  forms and every payload use.
- **Title memory** — no new table; derived from the owner's titled rows,
  keyed through `MerchantNormalizer` (`TitleMatching` in KeepoCore, the reads
  in `LocalTitleMemory`). Never written into `merchant_category_map`.
  - Form: at each leading-word prefix, longest first, the user's own history
    with that title, then a learned merchant. Pre-selects only while the
    category is still a guess (new entry or capture review) **and** the user
    has not tapped a category; on an ordinary edit it is only the first chip —
    retitling must not re-file.
  - Capture: an unlearned merchant matching a title **exactly** (no prefixes —
    nobody is watching). The device resolves it; the server receives the
    result as `capture_transaction(p_category_hint)`, which
    `resolve_category_for_merchant` uses after its merchant map and before the
    default, only for a live category of the right kind the owner owns. One
    implementation (Swift), same order on both sides, no flip on the next pull.
    `Outbox.submitCaptureTransaction` builds the hinted payload from
    `Resolution.categoryFromTitle`; the legacy-capture repair sends the local
    row's category as the hint for the same reason.
- Local mirror: `title` columns, `SyncApply` whitelist, `v20` rebuild.
  Search matches titles (local and PostgREST paths).
- **Pre-existing bug fixed on the path**: editing a transfer never prefilled
  its note, so saving any transfer edit silently wiped it (`update_transfer`
  stores exactly what it is sent). `applyTransfer` now prefills note and title.

## C — Export

Formats CSV, Excel, PDF (OFX/QIF and JSON considered and left out — see
`ExportFormat`'s header). `ExportView` asks three questions **one per page**
(accounts, period, format) with onboarding's progress dots in the bar, one
bottom button ("Continue", "Continue", "Export"), and on the last page a recap
of the earlier answers (with the count) plus carried filters as removable
chips. Final shape after two same-day revisions is the second bullet below.
The Transactions header's export button (beside the funnel) opens it
pre-filled, on the last page, and shows only while the filter panel is open —
the user's call.

- **Revised the same day on user feedback.** The first build was an accordion
  — three numbered cards on one screen, the open one expanded, a Continue in
  the card and a disabled "Choose a period" in the bar. The user found it
  overwhelming. Now: one question per page; each period shows its dates on
  its own row; the period page shows the live count ("No transactions in this
  period" is found there, not on the last page); the Face ID note appears only
  on the last page. `ProgressDots` moved from `OnboardingChrome` to
  `Common/Components` and takes an index, so both flows share it.
- **Second revision, same day, from the user's list:** no subtitles; "All
  accounts" is a bare `CheckboxRow` over the account card; the period page
  *is* the range calendar (All time checkbox + Jump to + preset pills over
  it, no separate sheet); format options are the Notifications cards
  (`ChoiceCard`, extracted from `NotificationSettingsView`, which now uses
  it too); the button reads "Export" with "Face ID required" over it (only
  while `AppSettings.isFaceIDEnabled` — `stepUp` is a no-op otherwise) and no
  footer; the bar is concentric (`KeepoTabBarMetrics.margin` sides and
  bottom). The calendar moved out of `CustomRangeSheet` into
  `Common/Components/RangeCalendar(+Grid).swift` with a `DayRange` model
  (`select` rules pinned by `DayRangeTests`); the sheet is now draft + All
  Time + Done around it. The period is derived from the calendar's days
  (`ExportPeriod.named`: a preset's exact days take its name), never stored
  beside them. Months now carry their gap as top padding ≥ the top fade, so a
  scrolled-to month's name is readable, and the calendar's bottom fade is
  short (the tab-bar-length default made the last week look disabled).
- **Found while walking it: a main-thread hang.** The bar read its bottom
  inset with `onGeometryChange` and fed it back into its own padding (the
  `OnboardingScaffold` recipe); on the period page the count line changed the
  bar's height and the inset it read oscillated forever — 99% CPU, UI frozen.
  Diagnosed with `sample` + `Self._printChanges()` (`_bottomSafeAreaInset
  changed` × hundreds). Fixed by not measuring: the stack
  `.ignoresSafeArea(.container, edges: .bottom)` and the bar pads `margin`.
- **Pages slide by offset, not by transition.** All three sit side by side in
  a `GeometryReader`, clipped, and `step` moves them. Profile's
  `NavigationStack` path is typed `[ProfileDestination]`, so real pushes would
  have needed Export as a sheet over the Profile sheet. Past page 1 the system
  back is hidden and a toolbar chevron goes back one page (no edge swipe
  between pages, as in onboarding).

- **Built on the device**, from `LocalTransactionRow.filteredSource` — the
  ledger's own `FROM … WHERE …`, extracted for this — so the file, the button's
  count (`LocalExportQueries.entryCount`, transfers counted once) and the PDF
  totals (`LocalExportQueries.totals`, summed in SQL) are one selection. The
  old server fetch (`ExportRepository.fetchTransactions`) and CSV builder are
  gone; `ExportRepository` is just `logExport` now.
- **Accounts are always explicit ids** (`TransactionFilter.accountIds`, new).
  The list's Private/Household card becomes the accounts it shows at hand-over,
  so the export, its audit row and the file never re-derive "all".
- Writers are pure KeepoCore: `CSVWriter` (BOM + CRLF, RFC 4180, formula
  cells defused with `'`), `XLSXWriter` (six-part SpreadsheetML, inline
  strings, built-in number/date formats so the reader's locale formats them),
  `ZipArchive` (stored entries, CRC-32). `MoneyFormatter.plain` is the one
  machine-readable money spelling, rounded like the screen.
- PDF (`ExportPDFRenderer`): light-appearance ink regardless of device mode,
  text styles at the default size, A4 or Letter by measurement system,
  transfers folded to one line, income/expenses/net per currency with
  transfers excluded.
- `CustomRangeSheet` is the range picker (the edit form's calendar is
  single-day). Its All Time checkbox is now the shared `Checkbox`.

## Verification

pgTAP 618 (25 new, `48_transaction_titles.sql`, including a full household
leave for the fork) · `swift test` 356 (30 new: title matching/shape, export
periods, writers, zip — the zip test runs `/usr/bin/unzip -t` on macOS) ·
KeepoTests 248 (9 new, `TransactionTitleLocalTests`) · KeepoUITests green ·
`swiftlint --strict` 0 · codegen re-run and diffed (14 `title` lines only).

Walked in the Simulator on the local stack: the notification step in light and
dark; a titled expense through form → ledger → server row; the export from the
Transactions header (pre-filled, Excel and PDF) and from Profile (steps from
scratch, custom range). The produced `.xlsx` was rendered by Quick Look as a
real spreadsheet (dates and numbers typed) and the PDF previewed; the audit row
landed with the right account id and row count. After the one-per-page
revision: re-walked from Profile (pages 1→2→3, empty-period note, recap row
back to page 2, chevron back to page 1, system back to Profile) and from the
Transactions header with a search filter (lands on page 3 with the chip, PDF
exported to the share sheet), light and dark; KeepoTests 248 and strict lint
re-run clean. After the second revision: re-walked accounts → calendar
(pill, half-made selection, All time, pill again) → format cards → selected
state; Notifications and the ledger's Custom Range sheet re-checked on the
shared components; pre-filled entry lands on page 3 and Back shows the same
range on the calendar. `swift test` 358, KeepoTests 254 (6 new
`DayRangeTests`), strict lint clean.

## Owed

- **`20261005100000` is pushed** (2026-09-23). `db diff --linked --schema
  public` against the migrations shows only Supabase platform extras (`pg_net`,
  the `ensure_rls` event trigger, default sequence privileges), nothing this
  app owns. `gen types --linked` is **not** a usable check here: through the
  CLI's temporary login role it sees none of the public tables. Until a new
  build ships, the build on the phone keeps working (every new parameter
  defaulted, columns nullable) with one known cost: it clears a title when it
  edits a titled transaction, as it would a note it did not know about.
- Not walked: the title→category pre-selection on screen (covered by
  `TransactionTitleLocalTests` and `TitleMatchingTests`), and a real share of
  each format into Numbers/Excel on device.
- Flagged, not fixed (outside this scope): transfer tags can't be edited on an
  existing transfer (`applyTransfer` never sets `editingId`); `fork_one_account`
  drops notes and `original_*`, and conflict "Keep mine" drops `original`.
