-- Sync Ritual is removed (product decision — it was creating too much
-- confusion). Everything built for it in migration 20260806200000 and
-- touched since goes with it: the reconciliations table, both
-- reconcile_*_account() RPCs, account_staleness(), the accounts_sync_status
-- view, and the reconciliation_gap branch of needs_review. The client side
-- (SyncRitualView, StalenessBadge) is already gone.
--
-- Alongside that: "system categories" (Adjustment ×2, Uncategorized) are
-- removed as a concept. "Other" (is_default) becomes the single fallback
-- for everything that used to have its own system category — captured/CSV
-- transactions with no learned merchant mapping, and (historically)
-- reconciliation adjustments. A category is either the one default per
-- kind, or an ordinary user category; there is no third tier.

-- ============================================================================
-- 1. Drop the reconciliation_gap branch from needs_review, and repoint the
--    capture-review subtitle at is_default instead of system_key. This is
--    the full current body of the view (last defined in
--    20260809100000_csv_import_export.sql, five branches) minus the
--    reconciliation_gap/accounts_sync_status branch, so it must be dropped
--    before accounts_sync_status itself.
-- ============================================================================

-- Dropped and recreated, not CREATE OR REPLACE: removing the
-- reconciliation_gap branch (whose amount column was plain `numeric`,
-- from accounts_sync_status.balance) changes the view's resolved amount
-- column back to numeric(20,4), and Postgres refuses to change a view
-- column's type via REPLACE.
drop view if exists needs_review;
create view needs_review
with (security_invoker = true) as
select
  'sync_conflict'::text as kind,
  sc.id as item_id,
  case sc.table_name
    when 'accounts' then sc.row_id
    when 'transactions' then (select t.account_id from transactions t where t.id = sc.row_id)
  end as account_id,
  sc.created_at as occurred_at,
  'Sync conflict — ' || sc.table_name as title,
  'your version ' || sc.client_version || ' vs. the saved version ' || sc.server_version as subtitle,
  null::numeric(20, 4) as amount,
  null::text as currency
from sync_conflicts sc
where sc.resolved_at is null

union all

select
  'pending_capture'::text as kind,
  t.id as item_id,
  t.account_id,
  t.occurred_at,
  'Review capture — ' || coalesce(t.merchant_raw, 'Unknown merchant') as title,
  case when c.is_default then 'Uncategorized' else 'Suggested: ' || c.name end as subtitle,
  t.amount,
  t.currency
from transactions t
join categories c on c.id = t.category_id
where t.source = 'capture' and t.status = 'pending' and t.deleted_at is null

union all

select
  'ambiguous_card'::text as kind,
  cm.id as item_id,
  null::uuid as account_id,
  cm.created_at as occurred_at,
  'Unmapped card — ' || cm.card_identifier as title,
  null::text as subtitle,
  null::numeric(20, 4) as amount,
  null::text as currency
from card_mappings cm
where cm.account_id is null

union all

select
  'csv_import_candidate'::text as kind,
  ic.id as item_id,
  ic.account_id,
  ic.occurred_at,
  'Import row — ' || coalesce(ic.merchant_raw, 'no description') as title,
  case when ic.matched_transaction_id is not null then 'Possible duplicate of an existing transaction' end as subtitle,
  ic.amount,
  ic.currency
from csv_import_candidates ic
where ic.status = 'pending';

grant select on needs_review to authenticated, service_role;

-- ============================================================================
-- 2. fork_household_accounts (the shared core behind leave_household() and
--    erase_own_account(), migration 20260810100000): repoint the transfer-
--    leg-becomes-adjustment category lookup at is_default — the
--    adjustment_expense/adjustment_income categories it used are dropped
--    below — and drop the reconciliations fork block entirely, since the
--    table it copies from is dropped below too. Everything else here is
--    unchanged from the original.
-- ============================================================================

create or replace function fork_household_accounts(p_household_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unregistered text;
  v_old_account_id uuid;
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  select string_agg(c.table_name, ', ') into v_unregistered
  from information_schema.columns c
  join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
  where c.table_schema = 'public' and c.column_name = 'account_id' and t.table_type = 'BASE TABLE'
    and not exists (select 1 from public.fork_handled_tables f where f.table_name = c.table_name);

  if v_unregistered is not null then
    raise exception 'fork_household_accounts: unregistered account_id-bearing table(s): %', v_unregistered;
  end if;

  for v_old_account_id in select account_id from public.household_accounts where household_id = p_household_id
  loop
    insert into public.accounts (
      owner_id, created_by, kind, subtype, name, currency,
      opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    )
    select p_member_a, p_member_a, kind, subtype, name, currency,
           opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    from public.accounts where id = v_old_account_id
    returning id into v_new_for_a;

    insert into public.accounts (
      owner_id, created_by, kind, subtype, name, currency,
      opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    )
    select p_member_b, p_member_b, kind, subtype, name, currency,
           opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    from public.accounts where id = v_old_account_id
    returning id into v_new_for_b;

    insert into public.transactions (
      owner_id, created_by, account_id, category_id, amount, currency, occurred_at,
      merchant_raw, merchant_normalized, source, status
    )
    select
      fork.fork_owner, t.created_by, fork.fork_account_id,
      case
        when t.transfer_group_id is not null then (
          select id from public.categories
          where owner_id = fork.fork_owner
            and kind = case when t.amount < 0 then 'expense'::public.category_kind else 'income'::public.category_kind end
            and is_default and deleted_at is null
        )
        else public.fork_category_id(fork.fork_owner, t.category_id)
      end,
      t.amount, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
      case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
      t.status
    from public.transactions t
    cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
    where t.account_id = v_old_account_id and t.deleted_at is null;

    insert into public.balance_snapshots (account_id, currency, as_of, value, created_by)
    select fork.fork_account_id, bs.currency, bs.as_of, bs.value, bs.created_by
    from public.balance_snapshots bs
    cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
    where bs.account_id = v_old_account_id;

    insert into public.recurring_rules (created_by, account_id, category_id, amount, currency, frequency, next_due_at, active)
    select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
           rr.amount, rr.currency, rr.frequency, rr.next_due_at, rr.active
    from public.recurring_rules rr
    cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
    where rr.account_id = v_old_account_id;

    update public.card_mappings
    set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
    where account_id = v_old_account_id;

    update public.csv_import_batches
    set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
    where account_id = v_old_account_id;

    update public.csv_import_candidates
    set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
    where account_id = v_old_account_id;

    delete from public.net_worth_daily where account_id = v_old_account_id;
    delete from public.household_accounts where account_id = v_old_account_id;
    update public.accounts set archived_at = coalesce(archived_at, now()) where id = v_old_account_id;
  end loop;
end;
$$;

revoke all on function fork_household_accounts(uuid, uuid, uuid) from public;

-- ============================================================================
-- 3. Drop the fork_handled_tables row for reconciliations (table dropped
--    below), then the Sync Ritual objects themselves in dependency order:
--    accounts_sync_status (depends on reconciliations + account_staleness),
--    account_staleness(), both reconcile_*_account() RPCs, then the table.
-- ============================================================================

delete from fork_handled_tables where table_name = 'reconciliations';

drop view if exists accounts_sync_status;
drop function if exists account_staleness(account_subtype, timestamptz);
drop function if exists reconcile_ledger_account(uuid, numeric, uuid);
drop function if exists reconcile_valuation_account(uuid, numeric, uuid);
drop table if exists reconciliations;

-- ============================================================================
-- 4. Category cleanup: reassign every row currently pointing at a system
--    category to the same owner's "Other" of matching kind, across every
--    table with a category_id FK, then drop the system categories and the
--    column that identified them.
-- ============================================================================

update transactions t
set category_id = o.id
from categories sys
join categories o
  on o.owner_id = sys.owner_id and o.kind = sys.kind and o.is_default and o.deleted_at is null
where t.category_id = sys.id and sys.system_key is not null;

update recurring_rules rr
set category_id = o.id
from categories sys
join categories o
  on o.owner_id = sys.owner_id and o.kind = sys.kind and o.is_default and o.deleted_at is null
where rr.category_id = sys.id and sys.system_key is not null;

update budgets b
set category_id = o.id
from categories sys
join categories o
  on o.owner_id = sys.owner_id and o.kind = sys.kind and o.is_default and o.deleted_at is null
where b.category_id = sys.id and sys.system_key is not null;

update merchant_category_map m
set category_id = o.id
from categories sys
join categories o
  on o.owner_id = sys.owner_id and o.kind = sys.kind and o.is_default and o.deleted_at is null
where m.category_id = sys.id and sys.system_key is not null;

delete from categories where system_key is not null;
