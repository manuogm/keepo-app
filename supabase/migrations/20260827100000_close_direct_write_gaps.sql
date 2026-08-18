-- S-02: direct grants that let an authenticated client skip the RPC guards
-- (rate limiting, idempotency, one-and-only-one-default-category, "an
-- unmapped card gets no client-side placeholder") the equivalent RPC
-- enforces. Two different fixes depending on whether the table has a
-- genuine client-side raw-insert path today:
--
-- transactions/categories: TransactionRepository.create and
-- CategoryRepository.create ARE raw PostgREST inserts (never RPCs) — that's
-- the deliberate, sole path for an ordinary manual expense/income or a
-- user-created category, so revoking INSERT outright would break Scenario
-- A. Instead, tighten each policy's WITH CHECK to pin the columns only an
-- RPC should ever set — but only the RPCs that are themselves SECURITY
-- DEFINER (and so already bypass RLS entirely, confirmed empirically: the
-- unmapped-capture case has account_id IS NULL, which would otherwise fail
-- this very policy's own can_write_account(account_id) check). The two
-- write paths that insert into `transactions` as SECURITY INVOKER —
-- create_transfer (transfer_group_id, source='manual') and
-- accept_import_candidate (source='csv_import') — run AS the calling
-- client and so ARE bound by this policy already; both stay allowed
-- explicitly rather than broken. What this closes: a raw insert can no
-- longer forge source='capture' (skipping capture_transaction's rate
-- limiter and idempotency), 'recurring' (skipping materialize_recurring's
-- dedup), or 'adjustment' (a fake balance adjustment tied to no real
-- snapshot), nor set external_id/card_identifier/recurring_rule_id at all
-- — every legitimate writer of those three is SECURITY DEFINER.
-- categories_insert can no longer forge is_default = true (every default
-- category is seeded server-side by ensure_user_bootstrap and friends, all
-- SECURITY DEFINER, none of which go through this policy either).
--
-- card_mappings/merchant_category_map: zero client raw-insert/update call
-- sites exist (confirmed via grep — every write goes through map_card /
-- rename_card_mapping / unmap_card / review_capture_transaction /
-- confirm_capture_transaction, all RPCs, all SECURITY DEFINER), so these
-- two just get the direct grants revoked outright, no WITH CHECK needed.

revoke insert, update on card_mappings from authenticated;
revoke insert, update on merchant_category_map from authenticated;

drop policy transactions_insert on transactions;
create policy transactions_insert on transactions
  for insert to authenticated
  with check (
    can_write_account(account_id) and created_by = (select auth.uid())
    and source in ('manual', 'csv_import') and status = 'confirmed'
    and external_id is null and card_identifier is null and recurring_rule_id is null
  );

drop policy categories_insert on categories;
create policy categories_insert on categories
  for insert to authenticated
  with check (owner_id = (select auth.uid()) and is_default = false);

-- ============================================================================
-- S-06: profiles' raw UPDATE grant is column-unscoped, so profiles_update's
-- row-level `id = auth.uid()` check says nothing about which columns a
-- client may touch. sync_epoch is the one that matters: it's what
-- leave_household/unshare_account/erase_own_account bump to force a
-- departing household member's device to wipe its local mirror and re-pull
-- from zero (app-architecture.md's LH2/LH3). A raw
-- `PATCH /profiles?id=eq.<self>` setting sync_epoch back to whatever the
-- device already has cached lets a removed member suppress that wipe
-- entirely, keep reading the shared account's history already on-device,
-- indefinitely — even though can_read_account has correctly revoked their
-- live access. The same door lets a client set deleted_at directly
-- (skipping whatever erase_own_account does beyond that column) or
-- onboarded_at without ever completing onboarding's own requirements.
--
-- ProfileRepository has exactly two writers (completeOnboarding,
-- updateBaseCurrency) and both only ever set base_currency/onboarded_at —
-- column-scoping the grant to just those two is a no-op for the client.
-- sync_epoch/sync_seq/deleted_at become writable only through the
-- SECURITY DEFINER functions that already own them (all bypass RLS/column
-- grants the same way every other DEFINER write RPC in this file does).
-- ============================================================================

revoke update on profiles from authenticated;
grant update (base_currency, onboarded_at) on profiles to authenticated;
