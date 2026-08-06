-- Fixup for 20260806200000, caught before commit: p_expected_last_reconciliation_id
-- needs `default null` — Swift's synthesized Encodable uses encodeIfPresent
-- for Optional properties, so a nil first-reconciliation call omits the key
-- entirely rather than sending JSON null, and PostgREST returns PGRST202
-- without a default (the same lesson keepo-v1-master-plan.md already
-- documents for every other optional RPC parameter in this codebase).
-- 20260806200000 itself was corrected in place for local dev (never
-- committed with the bug); this migration exists only because hosted had
-- already run the uncorrected version by the time the bug was found.

create or replace function reconcile_ledger_account(
  p_account_id uuid,
  p_entered_balance numeric,
  p_expected_last_reconciliation_id uuid default null
)
returns table (conflict boolean, reconciliation public.reconciliations, adjustment public.transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account record;
  v_last_id uuid;
  v_computed numeric(20, 4);
  v_gap numeric(20, 4);
  v_adjustment_category uuid;
  v_reconciliation public.reconciliations;
  v_adjustment public.transactions;
begin
  select id, kind, currency, owner_id into v_account
  from public.accounts
  where id = p_account_id and deleted_at is null;

  if v_account.id is null or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  if v_account.kind <> 'ledger' then
    raise exception 'account % is not a ledger account — use reconcile_valuation_account', p_account_id;
  end if;

  select id into v_last_id
  from public.reconciliations
  where account_id = p_account_id
  order by created_at desc
  limit 1;

  if v_last_id is distinct from p_expected_last_reconciliation_id then
    return query select true, null::public.reconciliations, null::public.transactions;
    return;
  end if;

  v_computed := public.account_balance_on(p_account_id, current_date);
  v_gap := p_entered_balance - v_computed;

  if v_gap <> 0 then
    select id into v_adjustment_category
    from public.categories
    where owner_id = v_account.owner_id
      and system_key = case when v_gap > 0 then 'adjustment_income' else 'adjustment_expense' end;

    insert into public.transactions (
      owner_id, created_by, account_id, category_id, amount, currency, occurred_at, source
    )
    values (
      v_account.owner_id, (select auth.uid()), p_account_id, v_adjustment_category,
      v_gap, v_account.currency, now(), 'adjustment'
    )
    returning * into v_adjustment;
  end if;

  insert into public.reconciliations (
    account_id, currency, entered_balance, computed_balance, adjustment_txn_id, created_by
  )
  values (
    p_account_id, v_account.currency, p_entered_balance, v_computed, v_adjustment.id, (select auth.uid())
  )
  returning * into v_reconciliation;

  return query select false, v_reconciliation, v_adjustment;
end;
$$;

create or replace function reconcile_valuation_account(
  p_account_id uuid,
  p_entered_value numeric,
  p_expected_last_reconciliation_id uuid default null
)
returns table (conflict boolean, reconciliation public.reconciliations)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account record;
  v_last_id uuid;
  v_computed numeric(20, 4);
  v_snapshot_id uuid;
  v_reconciliation public.reconciliations;
begin
  select id, kind, currency into v_account
  from public.accounts
  where id = p_account_id and deleted_at is null;

  if v_account.id is null or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  if v_account.kind <> 'valuation' then
    raise exception 'account % is not a valuation account — use reconcile_ledger_account', p_account_id;
  end if;

  select id into v_last_id
  from public.reconciliations
  where account_id = p_account_id
  order by created_at desc
  limit 1;

  if v_last_id is distinct from p_expected_last_reconciliation_id then
    return query select true, null::public.reconciliations;
    return;
  end if;

  v_computed := public.account_balance_on(p_account_id, current_date);

  insert into public.balance_snapshots (account_id, currency, as_of, value, created_by)
  values (p_account_id, v_account.currency, current_date, p_entered_value, (select auth.uid()))
  returning id into v_snapshot_id;

  insert into public.reconciliations (
    account_id, currency, entered_balance, computed_balance, snapshot_id, created_by
  )
  values (
    p_account_id, v_account.currency, p_entered_value, v_computed, v_snapshot_id, (select auth.uid())
  )
  returning * into v_reconciliation;

  return query select false, v_reconciliation;
end;
$$;
