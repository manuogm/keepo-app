# Unify account kinds (ledger/valuation → regular/investment, presentational only)

Product decision: both account kinds now behave identically. Every account takes
income/expense/transfer and can have cards mapped to it; balance for every account
is `opening_balance + SUM(amount)`. `account_kind` stays as a column (values renamed
`ledger`→`regular`, `valuation`→`investment`) but is now purely presentational — it
only drives the permanent "Investment" badge. `account_subtype`
(checking/cash/credit_card/loan/investment) is removed entirely: nothing used it
behaviorally once icon selection stopped deriving from it.

## Backend
- One migration, `supabase/migrations/20260902100000_unify_account_kinds.sql`. Order
  matters: drop dependent views/constraints → rename enum values (`ALTER TYPE ...
  RENAME VALUE`, safe to use immediately in the same migration, unlike `ADD VALUE`) →
  drop `transactions.account_kind` (composite FK + `valuation_transfers_only` CHECK),
  re-add a plain FK on `account_id` → drop `accounts.subtype` + `account_subtype` enum
  → redefine `account_balance_on`/`set_account_balance` to the single formula/path →
  redefine `update_account` (drops `p_subtype`), `link_card_to_account` (drops the
  ledger-only guard), `fork_one_account`, `pull_changes` → drop `balance_snapshots`
  entirely → recreate the three balance views without `subtype`.
- Verified against a local Supabase instance: `supabase db reset` applies cleanly,
  full pgTAP suite (22 files, 314 assertions) green after rewriting the tests that
  covered now-removed behavior. `24_valuation_balance_fallback.sql` deleted outright
  (tested a fallback path that no longer exists).
- `supabase gen types --lang swift --local` regenerated `SupabaseSchema.swift`.

## Client
- New `AccountKindChooserView` (sheet) / `AccountKindPicker` (shared two-card content,
  no chrome) — shown before `AccountFormView` on every create, in both
  `AccountsListView`'s `+` flow (two sequential sheets: chooser dismisses, *then* the
  form sheet opens with the chosen kind) and `OnboardingView`'s first-account step
  (inline, as a new `.accountKind` step).
- `AccountFormView`'s "Type" subtype picker is gone entirely — `Mode.create(kind:)`
  carries the pre-chosen kind in, which stays immutable after creation exactly like
  `currency` did before.
- New `InvestmentBadge` component (`App/Common/Components/`), shown on `AccountRow`
  and in `AccountFormView`'s edit mode whenever `kind == .investment`.
- Removed now-pointless `kind == .ledger` filters: `MapCardSheet`, `AccountFormView+Cards`'s
  Mapped Cards gate, `RecurringRuleFormView`, `CSVImportView` — every account is
  mappable/schedulable/importable-into now.
- `OnboardingView`'s account creation switched from a direct `AccountRepository.create`
  network call to `session.outbox.submitCreateAccount` — fixes a pre-existing
  divergence from `AccountFormView` (the outbox gives offline-safe write-through;
  onboarding had never gone through it before).
- `AccountAppearance.defaultIcon(forSubtype:)` → `defaultIcon(forKind:)` — `.regular`
  defaults to `banknote` (was the checking default), `.investment` unchanged
  (`chart.line.uptrend.xyaxis`).
- `LocalStore` schema: dropped `accounts.subtype`, `transactions.account_kind`, and the
  `balance_snapshots` table/index. New migration `v5_rebuild_syncable_tables` (same
  `rebuildSyncableTables` used by v2–v4) so an already-migrated device picks up the
  change via drop-and-repull.
- `LocalMoneyQueries.accountBalance` collapsed to the single formula, matching the new
  SQL `account_balance_on` exactly.

## Verification
- `supabase test db`: 314/314 pgTAP assertions pass.
- `swift test` (KeepoCore): 71/71 pass.
- `xcodebuild test` (KeepoTests): 80/80 pass, including the L4 referee suite
  (`LocalMoneyRefereeFixture`'s `eurBrokerage` fixture reworked from a
  `balance_snapshots` seed to a plain opening-balance + transaction, pinned value
  unchanged and still matches).
- `xcodebuild build` (Keepo scheme): succeeds. `swiftlint lint`: zero warnings
  repo-wide.
- Not verified: end-to-end in the Simulator/device (user is testing on their own
  device and will give feedback).

## Notes for a future agent
- `keepo-v1-feature-spec.md` §Accounts & Multi-Currency, §Data Model in
  `app-architecture.md`, and money rule 1 in `CLAUDE.md` were updated in place, not
  just this log — read those for the current schema, not this file's summary.
- Two lines in `keepo-v1-feature-spec.md` (staleness thresholds per subtype, §Sync
  Ritual; unrealized-gain, §Insights) were already stale from earlier feature removals
  (Sync Ritual and Insights/FI, see prior change-log entries) and were left untouched —
  pre-existing staleness, out of scope for this pass.
