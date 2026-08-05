-- Phase 5: close a latent integrity gap found while building the pgTAP
-- harness (see version-logs/phase-5-log.md, hazard H12). `transactions`
-- already closes the equivalent hole for accounts via the composite FK
-- `(account_id, owner_id) references accounts (id, owner_id)` — RLS checks
-- auth.uid() on the row being written, not on rows it merely references, so
-- without that FK a user could post a transaction against someone else's
-- account. `categories` never got the same treatment: `transactions_insert`'s
-- WITH CHECK only tests `can_write_account(account_id)` and `created_by`, so
-- a transaction can today reference *another user's* category id (harmless
-- today — you can't read the name, so `category_name` comes back null via
-- the `left join categories` in transactions_with_details — but the exact
-- gap the accounts FK was added to close, and one that becomes live once
-- Phase 19 merges household categories).
--
-- `categories` already has `unique (id, kind)` (for the (category_id,
-- category_kind) composite FK from Phase 2); this adds the second unique
-- target and the composite FK, mirroring the accounts pattern exactly.

alter table categories add constraint categories_id_owner_id_key unique (id, owner_id);

alter table transactions
  add constraint transactions_category_id_owner_id_fkey
  foreign key (category_id, owner_id) references categories (id, owner_id)
  deferrable initially deferred;
