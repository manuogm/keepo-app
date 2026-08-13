-- Local-first L1: money becomes fixed-point integers (bigint, scale 4).
-- See keepo-local-first-plan.md "Money representation" for the full rationale.
--
-- Every money column is renamed with an explicit _e4 suffix (units of
-- 1/10,000 — 12.34 EUR is stored as 123400) so PostgREST and the Swift
-- compiler surface every call site rather than silently reinterpreting a
-- decimal as an integer wherever one is missed. View-exposed money columns
-- get the same suffix, for the same reason.
--
-- fx_rates.rate_to_eur is NOT migrated — it is a conversion factor, not an
-- amount, and stays numeric(20,4).
--
-- Rounding contract (the one place this migration introduces inexactness):
-- fx_convert divides/multiplies against the numeric rate and rounds
-- **half away from zero** (Postgres round()'s default behavior, matching
-- Swift Decimal's `.plain` rounding mode) to bigint at the final step only.
-- Every other operation here — addition, subtraction, comparison — is exact
-- bigint arithmetic with no rounding at all.

-- ============================================================
-- 1. Drop views and functions whose signatures must change
-- ============================================================

drop view if exists public.needs_review;
drop view if exists public.accounts_with_balances;
drop view if exists public.account_balances_base;
drop view if exists public.account_balances;
drop view if exists public.transactions_with_details;

drop function if exists public.account_balance_on(uuid, date);
drop function if exists public.fx_convert(numeric, text, text, date);
drop function if exists public.net_worth(public.account_scope);
drop function if exists public.net_worth_series(public.account_scope, date, date);
drop function if exists public.spending_by_category(public.account_scope, date, date);
drop function if exists public.income_expense_series(public.account_scope, date, date, text);
drop function if exists public.unrealized_gain(uuid);
drop function if exists public.budget_progress(date);
drop function if exists public.fi_metrics(public.account_scope);
drop function if exists public.set_account_balance(uuid, numeric, uuid);
drop function if exists public.update_transaction(uuid, integer, uuid, uuid, numeric, text, timestamptz, text);
drop function if exists public.create_transfer(uuid, uuid, numeric, numeric, timestamptz, uuid, uuid);
drop function if exists public.update_transfer(uuid, integer, integer, numeric, numeric, timestamptz);
drop function if exists public.capture_transaction(uuid, text, text, text, numeric, timestamptz, text);
drop function if exists public.check_transfer_rate_divergence(text, text, numeric, numeric, timestamptz);

-- ============================================================
-- 2. Migrate the 8 money columns to bigint e4
-- ============================================================
-- Source is numeric(20,4), so multiplying by 10^4 and rounding to the
-- nearest integer is exact (there is nothing to round away).

alter table public.accounts rename column opening_balance to opening_balance_e4;
alter table public.accounts
  alter column opening_balance_e4 type bigint using round(opening_balance_e4 * 10000)::bigint;

alter table public.balance_snapshots rename column value to value_e4;
alter table public.balance_snapshots
  alter column value_e4 type bigint using round(value_e4 * 10000)::bigint;

alter table public.budgets rename column amount to amount_e4;
alter table public.budgets
  alter column amount_e4 type bigint using round(amount_e4 * 10000)::bigint;

alter table public.csv_import_candidates rename column amount to amount_e4;
alter table public.csv_import_candidates
  alter column amount_e4 type bigint using round(amount_e4 * 10000)::bigint;

alter table public.fi_settings rename column target_annual_spend to target_annual_spend_e4;
alter table public.fi_settings
  alter column target_annual_spend_e4 type bigint using round(target_annual_spend_e4 * 10000)::bigint;

alter table public.net_worth_daily rename column balance to balance_e4;
alter table public.net_worth_daily
  alter column balance_e4 type bigint using round(balance_e4 * 10000)::bigint;

alter table public.recurring_rules rename column amount to amount_e4;
alter table public.recurring_rules
  alter column amount_e4 type bigint using round(amount_e4 * 10000)::bigint;

alter table public.transactions rename column amount to amount_e4;
alter table public.transactions
  alter column amount_e4 type bigint using round(amount_e4 * 10000)::bigint;

-- ============================================================
-- 3. Recreate functions against bigint columns
-- ============================================================

create function public.account_balance_on(p_account_id uuid, p_date date)
returns bigint
language sql
stable
set search_path = ''
as $$
  select
    case a.kind
      when 'ledger' then a.opening_balance_e4 + coalesce((
        select sum(t.amount_e4)
        from public.transactions t
        where t.account_id = a.id
          and t.deleted_at is null
          and t.status = 'confirmed'
          and t.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
      ), 0)
      when 'valuation' then (
        select bs.value_e4 + coalesce((
          select sum(t2.amount_e4)
          from public.transactions t2
          where t2.account_id = a.id
            and t2.deleted_at is null
            and t2.status = 'confirmed'
            and t2.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
            and t2.occurred_at > bs.created_at
        ), 0)
        from public.balance_snapshots bs
        where bs.account_id = a.id and bs.as_of <= p_date
        order by bs.as_of desc, bs.created_at desc
        limit 1
      )
    end
  from public.accounts a
  where a.id = p_account_id;
$$;

revoke all on function public.account_balance_on(uuid, date) from public;
grant execute on function public.account_balance_on(uuid, date) to authenticated;

-- fx_rate_on is untouched (fx_rates.rate_to_eur stays numeric) — fx_convert
-- is the only place a bigint e4 amount and a numeric rate meet, and the
-- only place in this whole layer that is not exact.
create function public.fx_convert(p_amount_e4 bigint, p_from text, p_to text, p_date date)
returns bigint
language sql
stable
set search_path = ''
as $$
  select case
    when p_from = p_to then p_amount_e4
    else round(p_amount_e4::numeric / public.fx_rate_on(p_from, p_date) * public.fx_rate_on(p_to, p_date))::bigint
  end;
$$;

revoke all on function public.fx_convert(bigint, text, text, date) from public;
grant execute on function public.fx_convert(bigint, text, text, date) to authenticated;

-- ============================================================
-- 5. Recreate views against the new bigint columns
-- ============================================================

create view public.account_balances
with (security_invoker = true) as
select id as account_id, currency, public.account_balance_on(id, current_date) as balance_e4
from public.accounts
where deleted_at is null;

create view public.account_balances_base
with (security_invoker = true) as
select
  ab.account_id,
  ab.currency,
  ab.balance_e4,
  a.owner_id,
  p.base_currency,
  public.fx_convert(ab.balance_e4, ab.currency, p.base_currency, current_date) as balance_base_e4,
  ab.balance_e4 is not null
    and public.fx_convert(ab.balance_e4, ab.currency, p.base_currency, current_date) is null as has_missing_rate
from public.account_balances ab
join public.accounts a on a.id = ab.account_id
left join public.profiles p on p.id = (select auth.uid());

create view public.accounts_with_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.name,
  a.kind,
  a.subtype,
  a.currency,
  c.minor_unit,
  a.include_in_total,
  a.counts_toward_fi,
  a.archived_at,
  ab.balance_e4,
  abb.base_currency,
  bc.minor_unit as base_minor_unit,
  abb.balance_base_e4,
  abb.has_missing_rate,
  a.version,
  (exists (select 1 from public.household_accounts ha where ha.account_id = a.id)) as is_shared
from public.accounts a
join public.account_balances ab on ab.account_id = a.id
join public.currencies c on c.code = a.currency
join public.account_balances_base abb on abb.account_id = a.id
left join public.currencies bc on bc.code = abb.base_currency;

create view public.transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount_e4,
  t.currency,
  cur.minor_unit,
  t.occurred_at,
  t.merchant_raw,
  t.merchant_normalized,
  t.transfer_group_id,
  t.source,
  t.status,
  case
    when t.transfer_group_id is not null then 'transfer'
    when t.amount_e4 < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version,
  p.base_currency,
  bc.minor_unit as base_minor_unit,
  public.fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) as amount_base_e4,
  public.fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) is null as has_missing_rate,
  t.recurring_rule_id
from public.transactions t
join public.accounts a on a.id = t.account_id
left join public.categories c on c.id = t.category_id
join public.currencies cur on cur.code = t.currency
left join public.profiles p on p.id = (select auth.uid())
left join public.currencies bc on bc.code = p.base_currency
where t.deleted_at is null;

create view public.needs_review
with (security_invoker = true) as
select
  'sync_conflict' as kind,
  sc.id as item_id,
  case sc.table_name
    when 'accounts' then sc.row_id
    when 'transactions' then (select t.account_id from public.transactions t where t.id = sc.row_id)
    else null::uuid
  end as account_id,
  sc.created_at as occurred_at,
  'Sync conflict — ' || sc.table_name as title,
  'your version ' || sc.client_version || ' vs. the saved version ' || sc.server_version as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from public.sync_conflicts sc
where sc.resolved_at is null
union all
select
  'pending_capture' as kind,
  t.id as item_id,
  t.account_id,
  t.occurred_at,
  'Review capture — ' || coalesce(t.merchant_raw, 'Unknown merchant') as title,
  case when c.is_default then 'Uncategorized' else 'Suggested: ' || c.name end as subtitle,
  t.amount_e4,
  t.currency
from public.transactions t
join public.categories c on c.id = t.category_id
where t.source = 'capture' and t.status = 'pending' and t.deleted_at is null
union all
select
  'ambiguous_card' as kind,
  cm.id as item_id,
  null::uuid as account_id,
  cm.created_at as occurred_at,
  'Unmapped card — ' || cm.card_identifier as title,
  null::text as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from public.card_mappings cm
where cm.account_id is null
union all
select
  'csv_import_candidate' as kind,
  ic.id as item_id,
  ic.account_id,
  ic.occurred_at,
  'Import row — ' || coalesce(ic.merchant_raw, 'no description') as title,
  case when ic.matched_transaction_id is not null then 'Possible duplicate of an existing transaction' else null end
    as subtitle,
  ic.amount_e4,
  ic.currency
from public.csv_import_candidates ic
where ic.status = 'pending';

-- Views are dropped and recreated above, which drops their grants too.
grant select on public.account_balances to authenticated;
grant select on public.account_balances_base to authenticated;
grant select on public.accounts_with_balances to authenticated;
grant select on public.transactions_with_details to authenticated;
grant select on public.needs_review to authenticated;

-- Remaining functions that depend on the views/base functions above.

create function public.net_worth(p_scope public.account_scope)
returns bigint
language sql
stable
set search_path = ''
as $$
  select case p_scope
    when 'me' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where not exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
    )
    when 'household' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
    )
    when 'total' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
    )
  end;
$$;

revoke all on function public.net_worth(public.account_scope) from public;
grant execute on function public.net_worth(public.account_scope) to authenticated;

create function public.net_worth_series(p_scope public.account_scope, p_from date, p_to date)
returns table(as_of date, total_e4 bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_base text;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());

  return query
  select
    nwd.as_of,
    case
      when bool_or(public.fx_convert(nwd.balance_e4, nwd.currency, v_base, nwd.as_of) is null) then null
      else sum(public.fx_convert(nwd.balance_e4, nwd.currency, v_base, nwd.as_of))::bigint
    end as total_e4
  from public.net_worth_daily nwd
  where nwd.as_of between p_from and p_to
    and (
      (p_scope = 'me' and not exists (
        select 1 from public.household_accounts ha where ha.account_id = nwd.account_id
      ))
      or (p_scope = 'household' and exists (
        select 1 from public.household_accounts ha where ha.account_id = nwd.account_id
      ))
      or p_scope = 'total'
    )
  group by nwd.as_of
  order by nwd.as_of;
end;
$$;

revoke all on function public.net_worth_series(public.account_scope, date, date) from public;
grant execute on function public.net_worth_series(public.account_scope, date, date) to authenticated;

create function public.spending_by_category(p_scope public.account_scope, p_from date, p_to date)
returns table(category_id uuid, category_name text, total_e4 bigint, currency text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_base text;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());

  return query
  select
    c.id,
    c.name,
    case
      when bool_or(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null) then null
      else sum(abs(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date)))::bigint
    end,
    v_base
  from public.transactions t
  join public.categories c on c.id = t.category_id
  where t.deleted_at is null and t.status = 'confirmed' and c.kind = 'expense'
    and t.occurred_at::date between p_from and p_to
    and (
      (p_scope = 'me' and not exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id))
      or (
        p_scope = 'household'
        and exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id)
      )
      or p_scope = 'total'
    )
  group by c.id, c.name
  order by 3 desc nulls last;
end;
$$;

revoke all on function public.spending_by_category(public.account_scope, date, date) from public;
grant execute on function public.spending_by_category(public.account_scope, date, date) to authenticated;

create function public.income_expense_series(
  p_scope public.account_scope, p_from date, p_to date, p_granularity text
)
returns table(bucket_start date, income_e4 bigint, expense_e4 bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_base text;
  v_trunc text;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());
  v_trunc := case when p_granularity = 'monthly' then 'month' else 'week' end;

  return query
  select
    date_trunc(v_trunc, t.occurred_at)::date,
    case
      when bool_or(t.amount_e4 > 0 and public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case when t.amount_e4 > 0 then public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) else 0 end
      )::bigint
    end,
    case
      when bool_or(t.amount_e4 < 0 and public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case
          when t.amount_e4 < 0 then abs(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date))
          else 0
        end
      )::bigint
    end
  from public.transactions t
  where t.deleted_at is null and t.status = 'confirmed' and t.category_id is not null
    and t.occurred_at::date between p_from and p_to
    and (
      (p_scope = 'me' and not exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id))
      or (
        p_scope = 'household'
        and exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id)
      )
      or p_scope = 'total'
    )
  group by 1
  order by 1;
end;
$$;

revoke all on function public.income_expense_series(public.account_scope, date, date, text) from public;
grant execute on function public.income_expense_series(public.account_scope, date, date, text) to authenticated;

create function public.unrealized_gain(p_account_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select
    (
      select bs.value_e4 from public.balance_snapshots bs
      where bs.account_id = p_account_id
      order by bs.as_of desc, bs.created_at desc
      limit 1
    )
    - coalesce(
      (
        select sum(t.amount_e4) from public.transactions t
        where t.account_id = p_account_id and t.deleted_at is null and t.status = 'confirmed'
          and t.occurred_at <= now()
      ),
      0
    )
  where exists (select 1 from public.balance_snapshots bs where bs.account_id = p_account_id);
$$;

revoke all on function public.unrealized_gain(uuid) from public;
grant execute on function public.unrealized_gain(uuid) to authenticated;

create function public.budget_progress(p_period_month date)
returns table(
  budget_id uuid, category_id uuid, category_name text, budgeted_e4 bigint, spent_e4 bigint, currency text
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_base text;
  v_month_start date := date_trunc('month', p_period_month)::date;
  v_month_end date := (date_trunc('month', p_period_month) + interval '1 month' - interval '1 day')::date;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());

  return query
  select
    b.id,
    b.category_id,
    c.name,
    public.fx_convert(b.amount_e4, b.currency, v_base, current_date),
    (
      select case
        when coalesce(bool_or(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null), false)
          then null
        else coalesce(sum(abs(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date))), 0)::bigint
      end
      from public.transactions t
      join public.categories tc on tc.id = t.category_id
      where t.owner_id = b.owner_id
        and tc.kind = 'expense'
        and t.deleted_at is null and t.status = 'confirmed'
        and t.occurred_at::date between v_month_start and v_month_end
        and (b.category_id is null or t.category_id = b.category_id)
    ),
    v_base
  from public.budgets b
  left join public.categories c on c.id = b.category_id
  where b.owner_id = (select auth.uid()) and b.period_month = v_month_start
  order by b.category_id nulls first;
end;
$$;

revoke all on function public.budget_progress(date) from public;
grant execute on function public.budget_progress(date) to authenticated;

create function public.fi_metrics(p_scope public.account_scope default 'total'::public.account_scope)
returns table(
  annual_spend_e4 bigint, fi_number_e4 bigint, current_net_worth_e4 bigint, percent_progress numeric,
  annual_savings_e4 bigint, years_to_fi numeric, coast_fi_number_e4 bigint
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_base text;
  v_settings record;
  v_annual_spend bigint;
  v_annual_income bigint;
  v_annual_savings bigint;
  v_net_worth bigint;
  v_fi_number bigint;
  v_years numeric;
  v_coast bigint;
  v_r numeric;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());
  select * into v_settings from public.fi_settings where owner_id = (select auth.uid());
  v_r := coalesce(v_settings.real_return_rate, 0.05);

  select
    case
      when coalesce(bool_or(t.amount_e4 > 0 and public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null), false)
        then null
      else coalesce(
        sum(case when t.amount_e4 > 0 then public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) else 0 end), 0
      )
    end,
    case
      when coalesce(bool_or(t.amount_e4 < 0 and public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null), false)
        then null
      else coalesce(
        sum(case when t.amount_e4 < 0 then abs(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date)) else 0 end), 0
      )
    end
  into v_annual_income, v_annual_spend
  from public.transactions t
  where t.deleted_at is null and t.status = 'confirmed' and t.category_id is not null
    and t.occurred_at::date between current_date - 365 and current_date
    and (
      (p_scope = 'me' and not exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id))
      or (
        p_scope = 'household'
        and exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id)
      )
      or p_scope = 'total'
    );

  if v_settings.target_annual_spend_e4 is not null then
    v_annual_spend := v_settings.target_annual_spend_e4;
  end if;

  v_annual_savings := case when v_annual_income is null or v_annual_spend is null then null
    else v_annual_income - v_annual_spend end;

  select case
    when count(*) = 0 then 0
    when bool_or(ab.balance_base_e4 is null) then null
    else sum(ab.balance_base_e4)
  end
  into v_net_worth
  from public.account_balances_base ab
  join public.accounts a on a.id = ab.account_id
  where a.counts_toward_fi and a.deleted_at is null
    and (
      (p_scope = 'me' and not exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id))
      or (
        p_scope = 'household'
        and exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
      )
      or p_scope = 'total'
    );

  v_fi_number := case
    when v_annual_spend is null or v_settings.withdrawal_rate is null or v_settings.withdrawal_rate = 0 then null
    else round(v_annual_spend::numeric / v_settings.withdrawal_rate)::bigint
  end;

  -- Years to FI, contributions included: solve (1+r)^t for t, where the
  -- future value of today's net worth plus t years of annual_savings
  -- (compounding at r) equals fi_number. Already-FI or a non-positive
  -- rate both fall back to the cases below rather than dividing by zero
  -- or taking ln() of a non-positive argument. This step works in numeric,
  -- not bigint, since it is a ratio/exponent computation, not money
  -- addition — the bigint inputs are cast once at the boundary.
  if v_fi_number is null or v_net_worth is null then
    v_years := null;
  elsif v_net_worth >= v_fi_number then
    v_years := 0;
  elsif v_annual_savings is null or v_annual_savings <= 0 then
    v_years := null;
  elsif v_r = 0 then
    v_years := (v_fi_number - v_net_worth)::numeric / v_annual_savings::numeric;
  else
    v_years := ln(
      (v_fi_number::numeric + v_annual_savings::numeric / v_r) / (v_net_worth::numeric + v_annual_savings::numeric / v_r)
    ) / ln(1 + v_r);
  end if;

  v_coast := case
    when v_fi_number is null or v_years is null then null
    when v_r = 0 then v_fi_number
    else round(v_fi_number::numeric / power(1 + v_r, v_years))::bigint
  end;

  return query select
    v_annual_spend,
    v_fi_number,
    v_net_worth,
    case when v_fi_number is null or v_fi_number = 0 or v_net_worth is null then null
      else v_net_worth::numeric / v_fi_number::numeric end,
    v_annual_savings,
    v_years,
    v_coast;
end;
$$;

revoke all on function public.fi_metrics(public.account_scope) from public;
grant execute on function public.fi_metrics(public.account_scope) to authenticated;

-- set_account_balance also gains p_expected_version (LH6): today it takes no
-- expected version, so two concurrent balance edits both apply silently and
-- the first vanishes with nothing logged. Matches every other write RPC's
-- versioned-conflict pattern now.
create function public.set_account_balance(
  p_account_id uuid, p_new_balance_e4 bigint, p_expected_version integer, p_id uuid default null
)
returns table(transaction_id uuid, snapshot_id uuid, conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account record;
  v_current bigint;
  v_gap bigint;
  v_category_id uuid;
  v_id uuid := coalesce(p_id, gen_random_uuid());
  v_txn_id uuid;
  v_snapshot_id uuid;
  v_owner uuid := (select auth.uid());
begin
  select id, kind, currency, owner_id, version into v_account
  from public.accounts
  where id = p_account_id and deleted_at is null;

  if v_account.id is null or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  -- Idempotency is checked BEFORE the version check, not after: a queued
  -- outbox write retried after a dropped ack must succeed silently even
  -- though the account's version has already moved past what the retry
  -- still claims to expect — it is not a concurrent edit, it is the same
  -- edit arriving twice. Only a v_id genuinely new to this account is
  -- subject to the version check at all.
  if v_account.kind = 'ledger' then
    select id into v_txn_id from public.transactions where id = v_id;
    if v_txn_id is not null then
      return query select v_txn_id, null::uuid, false;
      return;
    end if;
  else
    select id into v_snapshot_id from public.balance_snapshots where id = v_id;
    if v_snapshot_id is not null then
      return query select null::uuid, v_snapshot_id, false;
      return;
    end if;
  end if;

  if v_account.version <> p_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_account_id, v_owner, p_expected_version, v_account.version);
    return query select null::uuid, null::uuid, true;
    return;
  end if;

  if v_account.kind = 'ledger' then
    v_current := public.account_balance_on(p_account_id, current_date);
    v_gap := p_new_balance_e4 - v_current;

    if v_gap = 0 then
      return query select null::uuid, null::uuid, false;
      return;
    end if;

    select id into v_category_id
    from public.categories
    where owner_id = v_account.owner_id
      and kind = case when v_gap > 0 then 'income'::public.category_kind else 'expense'::public.category_kind end
      and is_default and deleted_at is null;

    if v_category_id is null then
      raise exception 'no default category found to file the adjustment under';
    end if;

    insert into public.transactions (
      id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source, status
    )
    values (
      v_id, v_account.owner_id, v_owner, p_account_id, v_category_id, v_gap, v_account.currency,
      now(), 'adjustment', 'confirmed'
    )
    returning id into v_txn_id;

    update public.accounts set updated_at = now() where id = p_account_id;

    return query select v_txn_id, null::uuid, false;
  else
    insert into public.balance_snapshots (id, account_id, currency, as_of, value_e4, created_by)
    values (v_id, p_account_id, v_account.currency, current_date, p_new_balance_e4, v_owner)
    returning id into v_snapshot_id;

    update public.accounts set updated_at = now() where id = p_account_id;

    return query select null::uuid, v_snapshot_id, false;
  end if;
end;
$$;

revoke all on function public.set_account_balance(uuid, bigint, integer, uuid) from public;
grant execute on function public.set_account_balance(uuid, bigint, integer, uuid) to authenticated;

create function public.update_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
begin
  select id, version, account_id, transfer_group_id, deleted_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(v_current.account_id) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.transactions;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text
) from public;
grant execute on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text
) to authenticated;

create function public.create_transfer(
  p_from_account_id uuid, p_to_account_id uuid, p_from_amount_e4 bigint, p_to_amount_e4 bigint default null,
  p_occurred_at timestamptz default now(), p_from_id uuid default null, p_to_id uuid default null
)
returns setof transactions
language plpgsql
set search_path = ''
as $$
declare
  v_from_owner uuid;
  v_from_currency text;
  v_to_owner uuid;
  v_to_currency text;
  v_to_amount_e4 bigint;
  v_group uuid := gen_random_uuid();
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 then
    raise exception 'from_amount must be a positive magnitude';
  end if;

  select owner_id, currency into v_from_owner, v_from_currency
  from public.accounts where id = p_from_account_id;
  select owner_id, currency into v_to_owner, v_to_currency
  from public.accounts where id = p_to_account_id;

  if v_from_currency is null or v_to_currency is null then
    raise exception 'one or both accounts were not found or are not accessible';
  end if;

  v_to_amount_e4 := coalesce(
    p_to_amount_e4,
    case when v_from_currency = v_to_currency then p_from_amount_e4 end
  );
  if v_to_amount_e4 is null or v_to_amount_e4 <= 0 then
    raise exception 'to_amount is required for cross-currency transfers and must be a positive magnitude';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id, source
  )
  values
    (
      coalesce(p_from_id, gen_random_uuid()), v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount_e4, v_from_currency, p_occurred_at, v_group, 'manual'
    ),
    (
      coalesce(p_to_id, gen_random_uuid()), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount_e4, v_to_currency, p_occurred_at, v_group, 'manual'
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;

revoke all on function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid) from public;
grant execute on function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid) to authenticated;

create function public.update_transfer(
  p_transfer_group_id uuid, p_from_expected_version integer, p_to_expected_version integer,
  p_from_amount_e4 bigint, p_to_amount_e4 bigint, p_occurred_at timestamptz
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 or p_to_amount_e4 is null or p_to_amount_e4 <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

  select id, version, account_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true, null::public.transactions;
    return;
  end if;

  update public.transactions set amount_e4 = -p_from_amount_e4, occurred_at = p_occurred_at
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set amount_e4 = p_to_amount_e4, occurred_at = p_occurred_at
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

revoke all on function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz) from public;
grant execute on function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz) to authenticated;

create function public.capture_transaction(
  p_id uuid, p_card_identifier text, p_merchant_raw text, p_merchant_normalized text, p_amount_e4 bigint,
  p_occurred_at timestamptz, p_external_id text
)
returns table(mapped boolean, account_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
  v_recent_count int;
begin
  select count(*) into v_recent_count
  from public.transactions
  where owner_id = v_owner
    and source = 'capture'
    and created_at > now() - interval '1 minute';

  if v_recent_count >= 20 then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier;

  if v_account_id is null then
    return query select false, null::uuid;
    return;
  end if;

  select a.currency into v_currency from public.accounts a where a.id = v_account_id;

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense');

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status, external_id
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, -abs(p_amount_e4), v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, 'capture', 'pending', p_external_id
  );

  return query select true, v_account_id;
end;
$$;

revoke all on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text) from public;
grant execute on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text) to authenticated;

create function public.check_transfer_rate_divergence(
  p_from_currency text, p_to_currency text, p_from_amount_e4 bigint, p_to_amount_e4 bigint,
  p_occurred_at timestamptz
)
returns table(diverges boolean, implied_rate numeric, market_rate numeric, pct_diff numeric)
language sql
stable
set search_path = ''
as $$
  select
    abs(implied - market) / market > 0.10 as diverges,
    implied as implied_rate,
    market as market_rate,
    (implied - market) / market as pct_diff
  from (
    select
      p_to_amount_e4::numeric / p_from_amount_e4::numeric as implied,
      public.fx_convert(1, p_from_currency, p_to_currency, p_occurred_at::date)::numeric as market
  ) rates
  where market is not null;
$$;

revoke all on function public.check_transfer_rate_divergence(text, text, bigint, bigint, timestamptz) from public;
grant execute on function public.check_transfer_rate_divergence(text, text, bigint, bigint, timestamptz)
  to authenticated;

-- ============================================================
-- 4. Body-only updates (no signature change) for functions with
--    explicit numeric(20,4) locals that must become bigint
-- ============================================================

create or replace function public.check_transfer_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_leg_count integer;
  v_distinct_accounts integer;
  v_distinct_owners integer;
  v_distinct_currencies integer;
  v_sum bigint;
  v_account_ids uuid[];
begin
  v_group := coalesce(new.transfer_group_id, old.transfer_group_id);
  if v_group is null then
    return null;
  end if;

  select
    count(*), count(distinct account_id), count(distinct owner_id), count(distinct currency), sum(amount_e4),
    array_agg(distinct account_id)
  into v_leg_count, v_distinct_accounts, v_distinct_owners, v_distinct_currencies, v_sum, v_account_ids
  from public.transactions
  where transfer_group_id = v_group and deleted_at is null;

  if v_leg_count not in (0, 2) then
    raise exception 'transfer % must have exactly 2 legs, found %', v_group, v_leg_count;
  end if;

  if v_leg_count = 2 then
    if v_distinct_accounts <> 2 then
      raise exception 'transfer % legs must reference distinct accounts', v_group;
    end if;

    if v_distinct_owners <> 1 then
      if not exists (
        select 1
        from public.household_accounts ha1
        join public.household_accounts ha2 on ha1.household_id = ha2.household_id
        where ha1.account_id = v_account_ids[1] and ha2.account_id = v_account_ids[2]
      ) then
        raise exception 'transfer % legs must share one owner or one household', v_group;
      end if;
    end if;

    if v_distinct_currencies = 1 and v_sum <> 0 then
      raise exception 'transfer % same-currency legs must net to zero', v_group;
    end if;
  end if;

  return null;
end;
$$;

create or replace function public.savings_rate(p_scope public.account_scope, p_from date, p_to date)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v_base text;
  v_income bigint;
  v_expense bigint;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());

  select
    case
      when bool_or(t.amount_e4 > 0 and public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case when t.amount_e4 > 0 then public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) else 0 end
      )
    end,
    case
      when bool_or(t.amount_e4 < 0 and public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case
          when t.amount_e4 < 0 then abs(public.fx_convert(t.amount_e4, t.currency, v_base, t.occurred_at::date))
          else 0
        end
      )
    end
  into v_income, v_expense
  from public.transactions t
  where t.deleted_at is null and t.status = 'confirmed' and t.category_id is not null
    and t.occurred_at::date between p_from and p_to
    and (
      (p_scope = 'me' and not exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id))
      or (
        p_scope = 'household'
        and exists (select 1 from public.household_accounts ha where ha.account_id = t.account_id)
      )
      or p_scope = 'total'
    );

  if v_income is null or v_expense is null or v_income = 0 then
    return null;
  end if;

  return (v_income - v_expense)::numeric / v_income::numeric;
end;
$$;

create or replace function public.import_csv_rows(p_account_id uuid, p_filename text, p_rows jsonb)
returns setof csv_import_candidates
language plpgsql
set search_path = ''
as $$
declare
  v_batch_id uuid;
  v_row jsonb;
  v_occurred_at timestamptz;
  v_amount_e4 bigint;
  v_currency text;
  v_matched uuid;
begin
  if not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  insert into public.csv_import_batches (account_id, filename)
  values (p_account_id, p_filename)
  returning id into v_batch_id;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_occurred_at := (v_row ->> 'occurred_at')::timestamptz;
    v_amount_e4 := (v_row ->> 'amount_e4')::bigint;
    v_currency := v_row ->> 'currency';

    select t.id into v_matched
    from public.transactions t
    where t.account_id = p_account_id
      and t.deleted_at is null
      and t.amount_e4 = v_amount_e4
      and t.currency = v_currency
      and t.occurred_at between v_occurred_at - interval '3 days' and v_occurred_at + interval '3 days'
    limit 1;

    insert into public.csv_import_candidates (
      batch_id, account_id, owner_id, raw_row, occurred_at, amount_e4, currency,
      merchant_raw, merchant_normalized, matched_transaction_id
    )
    select
      v_batch_id, p_account_id, b.owner_id, v_row, v_occurred_at, v_amount_e4, v_currency,
      v_row ->> 'merchant_raw', v_row ->> 'merchant_normalized', v_matched
    from public.csv_import_batches b
    where b.id = v_batch_id;
  end loop;

  return query select * from public.csv_import_candidates where batch_id = v_batch_id;
end;
$$;



-- ============================================================
-- 6. Fixes found on a systematic re-scan for raw references to the
--    renamed columns (word-boundary grep over every function body) that
--    section 3/4 missed: functions accessing a renamed column through a
--    `record`/`%ROWTYPE` field (no explicit numeric local to have flagged
--    them the first pass), and update_account's own numeric param.
-- ============================================================

drop function if exists public.update_account(uuid, integer, text, account_subtype, numeric, boolean, boolean);

create function public.update_account(
  p_id uuid, p_expected_version integer, p_name text, p_subtype public.account_subtype,
  p_opening_balance_e4 bigint, p_include_in_total boolean, p_counts_toward_fi boolean
)
returns table(conflict boolean, account accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set
    name = p_name,
    subtype = p_subtype,
    opening_balance_e4 = p_opening_balance_e4,
    include_in_total = p_include_in_total,
    counts_toward_fi = p_counts_toward_fi
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.update_account(
  uuid, integer, text, public.account_subtype, bigint, boolean, boolean
) from public;
grant execute on function public.update_account(
  uuid, integer, text, public.account_subtype, bigint, boolean, boolean
) to authenticated;

create or replace function public.delete_transfer(
  p_transfer_group_id uuid, p_from_expected_version integer, p_to_expected_version integer
)
returns table(conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
begin
  select id, version, account_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true;
    return;
  end if;

  update public.transactions set deleted_at = now()
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set deleted_at = now()
  where id = v_to.id and version = p_to_expected_version;

  return query select false;
end;
$$;

create or replace function public.accept_import_candidate(p_id uuid)
returns table(conflict boolean, transaction transactions)
language plpgsql
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_candidate record;
  v_kind public.category_kind;
  v_category_id uuid;
  v_result public.transactions;
begin
  select * into v_candidate from public.csv_import_candidates where id = p_id;

  if v_candidate.id is null or not public.can_write_account(v_candidate.account_id) then
    raise exception 'import candidate not found or not accessible';
  end if;

  if v_candidate.status <> 'pending' then
    raise exception 'import candidate already reviewed';
  end if;

  v_kind := case when v_candidate.amount_e4 < 0 then 'expense' else 'income' end;
  v_category_id := public.resolve_category_for_merchant(v_candidate.owner_id, v_candidate.merchant_normalized, v_kind);

  insert into public.transactions (
    owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status
  ) values (
    v_candidate.owner_id, v_owner, v_candidate.account_id, v_category_id, v_candidate.amount_e4, v_candidate.currency,
    v_candidate.occurred_at, v_candidate.merchant_raw, v_candidate.merchant_normalized, 'csv_import', 'confirmed'
  )
  returning * into v_result;

  update public.csv_import_candidates set status = 'accepted' where id = p_id;

  return query select false, v_result;
end;
$$;

create or replace function public.materialize_recurring(p_through date default current_date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
  v_occurrence date;
  v_inserted integer := 0;
begin
  for v_rule in
    select * from public.recurring_rules where active and next_due_at <= p_through
    order by id
    for update
  loop
    v_occurrence := v_rule.next_due_at;

    while v_occurrence <= p_through loop
      insert into public.transactions (
        id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
        source, external_id, recurring_rule_id
      ) values (
        gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
        v_rule.amount_e4, v_rule.currency, v_occurrence::timestamptz,
        'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
      )
      on conflict (owner_id, source, external_id) where external_id is not null do nothing;

      if found then
        v_inserted := v_inserted + 1;
      end if;

      v_occurrence := public.next_occurrence_date(v_occurrence, v_rule.frequency);
    end loop;

    update public.recurring_rules
    set next_due_at = v_occurrence, last_materialized_at = p_through
    where id = v_rule.id;
  end loop;

  return v_inserted;
end;
$$;

create or replace function public.refresh_net_worth_daily(p_user uuid, p_from date, p_to date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null and (select auth.uid()) <> p_user then
    raise exception 'cannot refresh another user''s net worth history';
  end if;

  insert into public.net_worth_daily (account_id, owner_id, currency, as_of, balance_e4)
  select a.id, a.owner_id, a.currency, gs.day::date, public.account_balance_on(a.id, gs.day::date)
  from public.accounts a
  cross join generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as gs (day)
  where a.owner_id = p_user and a.deleted_at is null
  on conflict (account_id, as_of) do update
  set balance_e4 = excluded.balance_e4, currency = excluded.currency, updated_at = now();
end;
$$;

create or replace function public.validate_recurring_rule_sign()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind public.category_kind;
begin
  select kind into v_kind from public.categories where id = new.category_id;

  if v_kind = 'expense' and new.amount_e4 >= 0 then
    raise exception 'an expense recurring rule''s amount must be negative';
  elsif v_kind = 'income' and new.amount_e4 <= 0 then
    raise exception 'an income recurring rule''s amount must be positive';
  end if;

  return new;
end;
$$;

create or replace function public.fork_household_accounts(p_household_id uuid, p_member_a uuid, p_member_b uuid)
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
      opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
    )
    select p_member_a, p_member_a, kind, subtype, name, currency,
           opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
    from public.accounts where id = v_old_account_id
    returning id into v_new_for_a;

    insert into public.accounts (
      owner_id, created_by, kind, subtype, name, currency,
      opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
    )
    select p_member_b, p_member_b, kind, subtype, name, currency,
           opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
    from public.accounts where id = v_old_account_id
    returning id into v_new_for_b;

    insert into public.transactions (
      owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
      merchant_raw, merchant_normalized, source, status
    )
    select
      fork.fork_owner, t.created_by, fork.fork_account_id,
      case
        when t.transfer_group_id is not null then (
          select id from public.categories
          where owner_id = fork.fork_owner
            and kind = case when t.amount_e4 < 0 then 'expense'::public.category_kind else 'income'::public.category_kind end
            and is_default and deleted_at is null
        )
        else public.fork_category_id(fork.fork_owner, t.category_id)
      end,
      t.amount_e4, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
      case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
      t.status
    from public.transactions t
    cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
    where t.account_id = v_old_account_id and t.deleted_at is null;

    insert into public.balance_snapshots (account_id, currency, as_of, value_e4, created_by)
    select fork.fork_account_id, bs.currency, bs.as_of, bs.value_e4, bs.created_by
    from public.balance_snapshots bs
    cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
    where bs.account_id = v_old_account_id;

    insert into public.recurring_rules (created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at, active)
    select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
           rr.amount_e4, rr.currency, rr.frequency, rr.next_due_at, rr.active
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

revoke all on function public.fork_household_accounts(uuid, uuid, uuid) from public;

-- ============================================================
-- 7. service_role grants that section 3's DROP+CREATE dropped —
--    every one of these originally granted execute to service_role too
--    (ops health checks, refresh_net_worth_daily, and every read RPC
--    Realtime/cron code paths call), and DROP FUNCTION drops all grants,
--    not just the ones this migration meant to change.
-- ============================================================

grant execute on function public.account_balance_on(uuid, date) to service_role;
grant execute on function public.fx_convert(bigint, text, text, date) to service_role;
grant execute on function public.net_worth(public.account_scope) to service_role;
grant execute on function public.net_worth_series(public.account_scope, date, date) to service_role;
grant execute on function public.spending_by_category(public.account_scope, date, date) to service_role;
grant execute on function public.income_expense_series(public.account_scope, date, date, text) to service_role;
grant execute on function public.unrealized_gain(uuid) to service_role;
grant execute on function public.budget_progress(date) to service_role;
grant execute on function public.fi_metrics(public.account_scope) to service_role;
