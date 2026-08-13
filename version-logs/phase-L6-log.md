# Phase L6 — Read-path rewrite

The largest phase in the local-first rebuild by file count (~20 screens, 66 App files touched or
adjacent) — sub-phased L6a–L6f, the same precedent Phase 7 set for the master plan's own largest
phase, so each sub-phase could land as its own reviewable, independently-verified commit rather than
one enormous diff.

## Delivered

- **L6a** — `App/LocalTableQueries.swift`: local reads for every plain-table screen (categories,
  budgets, recurring rules, currencies, single account/transaction, households), reusing generated
  `PublicSchema.*Select` types via `FetchableRecord` instead of a parallel struct per table.
- **Outbox optimistic write-through** (`App/OutboxLocalWrite.swift`) — not in the plan's original
  text, found necessary while starting the screen cutover: without it, deleting `PendingOverlay`
  (which the plan does call for) would have been a real offline-correctness regression. See Findings
  below.
- **L6b** — `AccountsListView`/`HomeView` cut to local reads; new `App/LocalAccountRow.swift`
  replicates `accounts_with_balances`' RLS visibility (owned or shared into the viewer's household)
  and per-account base-currency conversion locally.
- **L6c** — `TransactionsListView` (+ its Loading/NeedsReview extensions) and
  `TransactionRegisterView` cut to local reads; new `App/LocalTransactionRow.swift` builds
  `transactions_with_details`/`needs_review` row shapes from local data via an `AnyJSON` → JSON
  round-trip (see Findings). The "Pending sync" section and `PendingOverlayAdapter`'s row-state
  overlay were removed outright here, not just switched to a local source — write-through already
  makes them redundant.
- **L6d** — `InsightsView`/`BudgetsView`/`FISettingsView` cut over, reusing L4's
  `LocalMoneyConversion` functions directly (the server-decoded KeepoCore result types matched the
  local ones field-for-field, so this was call-site rewiring, not new logic).
- **L6e** — the remaining screens: `CategoriesView`, `RecurringRulesView`/`RecurringRuleFormView`,
  `BudgetFormView`, `AccountFormView`, `TransactionFormView`, `OnboardingView`, `ExportView`,
  `CSVImportView`. `CategoryFormView` needed zero changes — it already took its row as a parameter.
  Deleted `AccountFormCache.swift`/`TransactionFormCache.swift` (disk-cache fallbacks for a network
  fetch that could fail or be slow; a local read is neither).
- **L6f** — `HouseholdView`/`HouseholdViewLoader` cut over (`events` stays network, see Findings);
  found and fixed `NeedsReviewView` (the standalone tab, missed by the original per-screen pass) and
  `PreferencesView`'s remaining `CurrencyCache` use; deleted every now-dead file:
  `PendingOverlayAdapter.swift`, `PayloadCache.swift`, `FxRateCache.swift`, `CurrencyCache.swift`,
  `DataStore.swift`, `AccountFormCache.swift`, `TransactionFormCache.swift`, and KeepoCore's
  `PendingOverlay.swift` + its test file; removed `Outbox.pendingCreateTransactions`/
  `queuedKindsAndPayloads()` (both existed solely for the deleted overlay adapter).

## Findings

1. **The plan's own text was wrong about `LocalFxConvert`** — it listed it under "delete", but that's
   the shared, unit-tested FX-conversion function `LocalMoneyConversion`/`LocalMoneyQueries` (L4)
   call at the display boundary. Corrected in the plan rather than silently deleted.
2. **A real gap the plan's prose glossed over, found while starting the actual screen cutover:**
   `Outbox` sent writes straight to Postgres and only *queued* locally on failure — it never wrote
   into the local mirror either way, online or offline. Once every screen reads local-only, an
   offline (or even a fast, just-submitted online) write would have been invisible until the next
   `SyncEngine.pull()` — exactly the divergence this rebuild exists to close, just relocated rather
   than fixed. Confirmed with the user before building (a real architectural fork, not an
   implementation detail) and fixed with optimistic write-through: every `Outbox.submitX` now applies
   its payload into the local mirror via `SyncApply.upsertRow` — the same upsert the real pull uses —
   immediately, success or queued, before/regardless of the network attempt. The eventual pull
   overwrites the optimistic row with the authoritative one at the same primary key, so this is never
   a second source of truth, only a temporary stand-in. 6 unit tests
   (`KeepoTests/OutboxLocalWriteTests.swift`) confirm local balances reflect create/delete/transfer/
   account-balance writes immediately, before any pull.
3. **Two generated types (`TransactionsWithDetailsSelect`, `NeedsReviewSelect`) have no public
   initializer reachable from the App target** — plain `Codable` structs in the `KeepoCore` package
   with no custom `init`, so only their compiler-synthesized `public init(from decoder:)` crosses the
   module boundary (confirmed by the fact `FetchableRecord`'s default `Decodable`-based row decoding,
   used successfully in L6a, relies on exactly that synthesized initializer). For the 1:1-table types
   this was free reuse via `FetchableRecord`; for these two computed/joined view types, a raw SQL
   `Row` decode doesn't apply (FX conversion has to happen in Swift, at the display boundary, per L4),
   so `LocalTransactionRow` instead builds an `AnyJSON` object with the view's own snake_case keys and
   decodes through `JSONEncoder`/`JSONDecoder` — unusual, but it means every downstream consumer
   (`TransactionRow`, `TransactionFormView`, `MapCardSheet`, `NeedsReviewRow`) needed zero changes.
4. **A version conflict interacts with write-through in a way that needs an extra step.** `Outbox`
   already applied the user's (about-to-be-rejected) edit to the local mirror optimistically before
   the conflict was known — so `AccountFormView`/`TransactionFormView`'s post-conflict reload must
   call `session.syncEngine?.pull()` before re-reading locally, or it just shows the same wrong guess
   back. A plain local re-read, which would have been the "obvious" L6 cutover of the old
   network-refetch reload, would have silently been wrong here.
5. **`NeedsReviewView` — the standalone Needs Review tab, distinct from `TransactionsListView`'s
   inline section already cut over in L6c — was missed by the original screen inventory** and only
   found by grepping for `DataStore`/`CurrencyCache` usage before deleting those files. A reminder
   that "grep for the thing you're about to delete" is a real completeness check, not just cleanup
   hygiene, on a phase this wide.
6. **`household_events` has no local table and was never in L3's schema scope** — `HouseholdView` is
   the one screen L6 leaves partially online-first, by design: every other field on it is a local
   read, `events` alone is a best-effort network call that never blocks the rest of the screen.
7. **Deleting `PayloadCache` needed one small addition, not just removal** — `OfflineStatusBar`'s
   "Last synced …" read `PayloadCache.latestFetchedAt()`. Replaced with a `lastSyncedAt` field added
   to `SyncCursorStore` (persisted in `UserDefaults`, set alongside cursor/epoch on every successful
   pull) rather than reintroducing any cache. `OfflineSchemaV1`'s `CachedPayload` SwiftData model
   stays declared (removing a model from a versioned schema without a migration stage is its own
   hazard) even though nothing writes to it anymore — same posture the pre-existing `OutboxItem`
   legacy model already had after L3.

## Verification

- `xcodebuild -scheme Keepo -destination 'generic/platform=iOS Simulator' build` — clean, at every
  sub-phase.
- `xcodebuild ... test -only-testing:KeepoTests` — 44/44 at phase end, across 11 suites (new this
  phase: `OutboxLocalWriteTests` (6), `LocalTableQueriesTests`, `LocalAccountRowTests`,
  `LocalTransactionRowTests`; zero regressions in any pre-existing suite along the way).
- `swift test` (KeepoCore) — 63/63 (down from 74: `PendingOverlayTests` — 11 tests — removed with the
  KeepoCore `PendingOverlay.swift` it tested, once its last consumer, `PendingOverlayAdapter`, was
  deleted).
- `swiftlint lint --strict` — 0 violations across 116 files (down from 128 at the phase's start,
  reflecting net file deletions).
- **Not performed this session**: no pgTAP re-run (no migration touched this phase — pure Swift/App
  target work) and no simulator walkthrough (deferred to L7, which is explicitly the
  airplane-mode/two-device verification phase this whole rebuild has been building toward).
