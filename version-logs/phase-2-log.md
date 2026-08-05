# Phase 2 — Categories and Transactions

Reconstructed after the fact (see `lessons-learned.md`). Sourced from the commit body of `a876d01`, the migration's own inline comments, and `~/.claude/plans/enumerated-floating-quasar.md`.

## Delivered

- `categories` + `transactions` tables, `bump_version()` trigger (retrofitted onto `accounts`, applied to `transactions`), `set_transaction_derived_columns()`, deferred constraint trigger `check_transfer_integrity()`.
- Views: `transactions_with_details`; `account_balances` extended to a complete ledger/valuation `CASE`.
- RPC `create_transfer(...)` — the only transaction kind needing one; expense/income are a plain insert, backed by the `sign_matches_category_kind` CHECK.
- Client: `AmountParser`, `CategoryRepository`, `TransactionRepository`, `TransactionFormView` (one component, three kinds), `TransactionsListView`, `CategoriesView`, `TabView` shell (Accounts | Transactions | Categories).
- Migration: `supabase/migrations/20260804192805_categories_and_transactions.sql`.

## Bugs found only by testing against a live database

1. **`SECURITY DEFINER` + self-reference breaks `INSERT ... RETURNING`.** `accounts`' own `accounts_select`/`accounts_update` policies routed through `can_read_account`/`can_write_account`, which re-query `accounts` — the very table whose policy calls them. Breaks specifically for a row written earlier in the same command; confirmed empirically, ruled out `STABLE`/`VOLATILE` and SQL/plpgsql as the cause. Fix: those two policies compare `owner_id` inline instead of calling the shared predicate — the one documented exception to "every policy upgrades via one function-body edit" (Phase 7 will need to edit these two directly, in addition to the function body).
2. Valuation balance formula compared `occurred_at::date > as_of`, silently dropping same-day transfers (`today > today` is false). Fixed to compare against the snapshot's `created_at` timestamp instead.

## Design refinements applied to `app-architecture.md`

- `transaction_kind` is derived in `transactions_with_details`, not a stored `GENERATED ALWAYS` column — generation expressions need an `IMMUTABLE` cast and `enum_in` is only `STABLE`.
- No auto-snapshot when transferring into a valuation account — would double-count against the "snapshot + transfers after" balance formula.
- Expense/income are a plain insert, not an RPC — the `sign_matches_category_kind` CHECK makes a wrong sign structurally impossible.

## Deferred, deliberately

- Editing transactions → Phase 3 (this is where the `version`/optimistic-concurrency machinery it depends on lands).
- Merchant→category auto-suggestion / `merchant_category_map` → Phase 8 (needs capture volume).
- Recurring rules → own phase.
- FX conversion of the list → Phase 4.
