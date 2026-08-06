-- Phase 9: Sync Ritual & reconciliations. Closes H14 (the adjustment
-- category can't be a second is_default row) and builds the reconcile-a-
-- balance flow: reconciliations never store a balance themselves (that
-- would compete with SUM(amount) as a second source of truth for ledger
-- accounts) — they record the *event* of reconciling, which is what lets
-- the client render "verified X ago."

-- ============================================================================
-- categories.system_key (H14) — a system category (never user-deletable,
-- never auto-recategorized) that is NOT a second is_default row. is_default
-- means "the category a client falls back to when none is chosen" (Other);
-- system_key means "a category the app itself writes into, off-limits to
-- the user" (Adjustment). The two are orthogonal, hence a second column
-- rather than overloading is_default. Two rows, not one — the adjustment
-- can move a balance in either direction, and sign_matches_category_kind
-- (migration 002) requires the category's kind to agree with the amount's
-- sign, exactly like "Other" already needing one row per kind.
-- ============================================================================

alter table categories add column system_key text;
alter table categories add constraint categories_system_key_unique unique (owner_id, system_key);

-- prevent_default_category_deletion (migration 002) extended: a system
-- category is exactly as undeletable as a default one. Renamed nowhere —
-- same function, same trigger, wider condition.
create or replace function prevent_default_category_deletion()
returns trigger
language plpgsql
as $$
begin
  if (new.is_default or new.system_key is not null) and new.deleted_at is not null then
    raise exception 'this category cannot be deleted';
  end if;
  return new;
end;
$$;

-- handle_new_user() / ensure_user_bootstrap(): seed the two Adjustment rows
-- alongside the two Other rows, same on-conflict-do-nothing idempotency.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (new.id, 'expense', 'Other', true), (new.id, 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  insert into public.categories (owner_id, kind, name, system_key)
  values (new.id, 'expense', 'Adjustment', 'adjustment_expense'), (new.id, 'income', 'Adjustment', 'adjustment_income')
  on conflict (owner_id, system_key) do nothing;

  return new;
end;
$$;

create or replace function ensure_user_bootstrap()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (auth.uid())
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (auth.uid(), 'expense', 'Other', true), (auth.uid(), 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  insert into public.categories (owner_id, kind, name, system_key)
  values (auth.uid(), 'expense', 'Adjustment', 'adjustment_expense'), (auth.uid(), 'income', 'Adjustment', 'adjustment_income')
  on conflict (owner_id, system_key) do nothing;
end;
$$;

-- Backfill for any profile that bootstrapped before this migration.
insert into categories (owner_id, kind, name, system_key)
select p.id, k.kind, 'Adjustment', k.system_key
from profiles p
cross join (
  values ('expense'::category_kind, 'adjustment_expense'), ('income'::category_kind, 'adjustment_income')
) as k (kind, system_key)
on conflict (owner_id, system_key) do nothing;

-- ============================================================================
-- reconciliations — append-only (no update/delete policy), like
-- balance_snapshots and fx_rates: a correction is a new reconciliation, not
-- an edit to a past one. Never stores a balance (see header comment).
-- ============================================================================

create table reconciliations (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  currency text not null,
  as_of date not null default current_date,
  entered_balance numeric(20, 4) not null,
  computed_balance numeric(20, 4) not null,
  adjustment_txn_id uuid references transactions (id),
  snapshot_id uuid references balance_snapshots (id),
  created_by uuid not null references auth.users (id) deferrable initially deferred,
  created_at timestamptz not null default now(),
  foreign key (account_id, currency) references accounts (id, currency)
);

create index reconciliations_account_created_idx on reconciliations (account_id, created_at desc);

alter table reconciliations enable row level security;

create policy reconciliations_select on reconciliations
  for select to authenticated
  using (can_read_account(account_id));

create policy reconciliations_insert on reconciliations
  for insert to authenticated
  with check (can_write_account(account_id) and created_by = (select auth.uid()));

grant select, insert on reconciliations to authenticated, service_role;

-- ============================================================================
-- account_staleness(subtype, last_verified_at) — the one CASE holding every
-- per-subtype threshold. Cash drifts in a day; a mortgage does not move in
-- a month — one global threshold is either always amber or never useful.
-- Pure SQL, no table access, so no SECURITY DEFINER is needed, but
-- search_path is still pinned per this codebase's standing convention for
-- every function.
-- ============================================================================

create function account_staleness(p_subtype account_subtype, p_last_verified_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_last_verified_at < now() - case p_subtype
    when 'checking' then interval '3 days'
    when 'cash' then interval '3 days'
    when 'credit_card' then interval '7 days'
    when 'loan' then interval '30 days'
    when 'investment' then interval '30 days'
  end;
$$;

revoke all on function account_staleness(account_subtype, timestamptz) from public;
grant execute on function account_staleness(account_subtype, timestamptz) to authenticated;

-- accounts_sync_status: per-account freshness for the Sync Ritual screen
-- and Home's staleness banner. "Verified" defaults to the account's own
-- created_at when it has never been reconciled — the opening balance IS a
-- verification event (the spec's own reasoning for requiring one at
-- creation), so a brand-new account starts its staleness clock there
-- rather than reading as infinitely stale from the moment it's created.
create or replace view accounts_sync_status
with (security_invoker = true) as
select
  a.account_id,
  a.name,
  a.kind,
  a.subtype,
  a.currency,
  a.minor_unit,
  a.balance,
  a.include_in_total,
  a.archived_at,
  coalesce(r.last_verified_at, acc.created_at) as last_verified_at,
  account_staleness(a.subtype, coalesce(r.last_verified_at, acc.created_at)) as is_stale
from accounts_with_balances a
join accounts acc on acc.id = a.account_id
left join (
  select account_id, max(created_at) as last_verified_at
  from reconciliations
  group by account_id
) r on r.account_id = a.account_id;

grant select on accounts_sync_status to authenticated, service_role;

-- ============================================================================
-- reconcile_ledger_account — enter balance, review pending transactions
-- (client-side, before calling this), one-tap unlogged adjustment if a gap
-- remains. p_expected_last_reconciliation_id is the concurrency guard:
-- reconciliation is against the LAST reconciliation point, and a stale one
-- is refused rather than blindly written — if the actual latest
-- reconciliation id has moved since the caller started the ritual (another
-- household member reconciled the same shared account in between), this
-- returns conflict = true and writes nothing. The client's natural retry —
-- reload accounts_sync_status, recompute the gap against the now-current
-- state — IS the "rebase" the spec allows; there is no separate rebase code
-- path because a fresh read already produces exactly that.
-- ============================================================================

create function reconcile_ledger_account(
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

revoke all on function reconcile_ledger_account(uuid, numeric, uuid) from public;
grant execute on function reconcile_ledger_account(uuid, numeric, uuid) to authenticated;

-- ============================================================================
-- reconcile_valuation_account — direct balance update writing a snapshot,
-- no transaction review, no adjustment (spec, explicit). Same
-- stale-reconciliation-point guard as the ledger path.
-- ============================================================================

create function reconcile_valuation_account(
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

revoke all on function reconcile_valuation_account(uuid, numeric, uuid) from public;
grant execute on function reconcile_valuation_account(uuid, numeric, uuid) to authenticated;
