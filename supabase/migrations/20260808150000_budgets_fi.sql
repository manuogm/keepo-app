-- Phase 16: Budgets & FI.
--
-- Doc amendment (H13, app-architecture.md line 108): `budgets` stores
-- `amount` + `currency` as typed, never `amount_base` — a converted amount
-- stored on write would violate money rule 6 (no converted amount is ever
-- stored) and can't satisfy "budgets: viewer's base currency" once two
-- household members with different bases exist, since a single stored
-- `amount_base` can only ever be correct for one of them. Converted on
-- read via `fx_convert`, same as every other money value in this schema.

-- ============================================================================
-- budgets — calendar month, no rollover in v1 (spec). `category_id null`
-- means an overall monthly budget, not tied to one category. Two partial
-- unique indexes stand in for one constraint because a plain
-- `unique (owner_id, category_id, period_month)` would silently allow
-- multiple `category_id IS NULL` (overall) rows per month — NULL is never
-- equal to NULL in a unique constraint, only a partial index scoped to
-- each case actually closes both gaps.
-- ============================================================================

create table budgets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  category_id uuid,
  period_month date not null,
  amount numeric(20, 4) not null check (amount > 0),
  currency text not null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (category_id, owner_id) references categories (id, owner_id) deferrable initially deferred
);

alter table budgets enable row level security;

create policy budgets_select on budgets
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy budgets_insert on budgets
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy budgets_update on budgets
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, insert, update on budgets to authenticated, service_role;

create unique index budgets_category_month_idx
  on budgets (owner_id, category_id, period_month)
  where category_id is not null;

create unique index budgets_overall_month_idx
  on budgets (owner_id, period_month)
  where category_id is null;

-- `period_month` is always the first of its month — enforced here rather
-- than trusted from the client, since a mid-month value would silently
-- dodge both partial unique indexes above and let two "January" budgets
-- coexist.
create function normalize_budget_period_month()
returns trigger
language plpgsql
as $$
begin
  new.period_month := date_trunc('month', new.period_month)::date;
  return new;
end;
$$;

create trigger budgets_normalize_period_month
  before insert or update on budgets
  for each row execute function normalize_budget_period_month();

create trigger budgets_set_updated_at
  before update on budgets
  for each row execute function set_updated_at();

create trigger budgets_bump_version
  before update on budgets
  for each row execute function bump_version();

-- ============================================================================
-- budget_progress(period_month) — the read side. Actual spend excludes
-- transfers (category_id is not null, same reasoning as every Phase 15
-- function) and is scoped to confirmed, non-deleted transactions in that
-- exact calendar month. Money rule 5: a category whose spend can't be
-- converted renders null, distinguished from "genuinely zero spend so
-- far" — `bool_or(...)`/`sum(...)` both return null over zero matching
-- rows, so each is explicitly coalesced to a real, distinguishable default
-- (`false`/`0`) before the null-means-unconvertible check runs, or the two
-- cases would be indistinguishable.
-- ============================================================================

create function budget_progress(p_period_month date)
returns table (budget_id uuid, category_id uuid, category_name text, budgeted numeric, spent numeric, currency text)
language plpgsql
security invoker
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
    public.fx_convert(b.amount, b.currency, v_base, current_date),
    (
      select case
        when coalesce(bool_or(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null), false)
          then null
        else coalesce(sum(abs(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date))), 0)
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

revoke all on function budget_progress(date) from public;
grant execute on function budget_progress(date) to authenticated, service_role;

-- ============================================================================
-- fi_settings — one row per user, seeded at signup (same as `profiles`) so
-- there is always exactly one editable row to show; no upsert-on-first-
-- view logic anywhere. Every constant `fi_metrics()` uses below is a
-- column here, editable in Settings — never a hidden literal (spec).
-- ============================================================================

create table fi_settings (
  owner_id uuid primary key references auth.users (id) deferrable initially deferred,
  target_annual_spend numeric(20, 4),
  withdrawal_rate numeric(6, 4) not null default 0.04 check (withdrawal_rate > 0),
  real_return_rate numeric(6, 4) not null default 0.05,
  updated_at timestamptz not null default now()
);

alter table fi_settings enable row level security;

create policy fi_settings_select on fi_settings
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy fi_settings_update on fi_settings
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, update on fi_settings to authenticated, service_role;

create trigger fi_settings_set_updated_at
  before update on fi_settings
  for each row execute function set_updated_at();

-- Seeded, never client-inserted (no INSERT grant/policy at all — matches
-- `profiles`' own shape, one row per user, created only by the functions
-- below). handle_new_user()/ensure_user_bootstrap() re-defined here in
-- full to add the fi_settings insert alongside everything Phase 9/12/15
-- already put there — fixed forward per this project's established
-- precedent, never editing an already-hosted migration in place.

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);

  insert into public.categories (owner_id, kind, name, is_default)
  values (new.id, 'expense', 'Other', true), (new.id, 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  insert into public.categories (owner_id, kind, name, system_key)
  values
    (new.id, 'expense', 'Adjustment', 'adjustment_expense'),
    (new.id, 'income', 'Adjustment', 'adjustment_income'),
    (new.id, 'expense', 'Uncategorized', 'uncategorized_expense')
  on conflict (owner_id, system_key) do nothing;

  insert into public.fi_settings (owner_id) values (new.id)
  on conflict (owner_id) do nothing;

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
  insert into public.profiles (id)
  values (auth.uid())
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (auth.uid(), 'expense', 'Other', true), (auth.uid(), 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  insert into public.categories (owner_id, kind, name, system_key)
  values
    (auth.uid(), 'expense', 'Adjustment', 'adjustment_expense'),
    (auth.uid(), 'income', 'Adjustment', 'adjustment_income'),
    (auth.uid(), 'expense', 'Uncategorized', 'uncategorized_expense')
  on conflict (owner_id, system_key) do nothing;

  insert into public.fi_settings (owner_id) values (auth.uid())
  on conflict (owner_id) do nothing;
end;
$$;

-- Backfill: every existing profile gets a default fi_settings row.
insert into fi_settings (owner_id)
select p.id from profiles p
on conflict (owner_id) do nothing;

-- ============================================================================
-- fi_metrics(scope) — FI number, current net worth (counts_toward_fi
-- accounts only — a primary residence or a car belongs in net worth but
-- not here, spec), % progress, years-to-FI (with continued contributions
-- at the current trailing-12-month savings rate), and Coast FI (the net
-- worth that alone, growing untouched at the real return rate, reaches
-- the FI number by the SAME date years-to-FI already projects — crossed
-- years earlier than years-to-FI itself, giving a new user something real
-- to show, exactly the spec's own framing).
--
-- annual_spend defaults to the trailing 12 months of real expense activity
-- (excluding transfers, same as savings_rate) when `target_annual_spend`
-- is null — never a hidden literal, always this column or a number derived
-- transparently from the ledger.
-- ============================================================================

create function fi_metrics(p_scope account_scope default 'total')
returns table (
  annual_spend numeric,
  fi_number numeric,
  current_net_worth numeric,
  percent_progress numeric,
  annual_savings numeric,
  years_to_fi numeric,
  coast_fi_number numeric
)
language plpgsql
security invoker
stable
set search_path = ''
as $$
declare
  v_base text;
  v_settings record;
  v_annual_spend numeric;
  v_annual_income numeric;
  v_annual_savings numeric;
  v_net_worth numeric;
  v_fi_number numeric;
  v_years numeric;
  v_coast numeric;
  v_r numeric;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());
  select * into v_settings from public.fi_settings where owner_id = (select auth.uid());
  v_r := coalesce(v_settings.real_return_rate, 0.05);

  select
    case
      when coalesce(bool_or(t.amount > 0 and public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null), false)
        then null
      else coalesce(
        sum(case when t.amount > 0 then public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) else 0 end), 0
      )
    end,
    case
      when coalesce(bool_or(t.amount < 0 and public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null), false)
        then null
      else coalesce(
        sum(case when t.amount < 0 then abs(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date)) else 0 end), 0
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

  if v_settings.target_annual_spend is not null then
    v_annual_spend := v_settings.target_annual_spend;
  end if;

  v_annual_savings := case when v_annual_income is null or v_annual_spend is null then null
    else v_annual_income - v_annual_spend end;

  select case
    when count(*) = 0 then 0
    when bool_or(ab.balance_base is null) then null
    else sum(ab.balance_base)
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
    else v_annual_spend / v_settings.withdrawal_rate
  end;

  -- Years to FI, contributions included: solve (1+r)^t for t, where the
  -- future value of today's net worth plus t years of annual_savings
  -- (compounding at r) equals fi_number. Already-FI or a non-positive
  -- rate both fall back to the cases below rather than dividing by zero
  -- or taking ln() of a non-positive argument.
  if v_fi_number is null or v_net_worth is null then
    v_years := null;
  elsif v_net_worth >= v_fi_number then
    v_years := 0;
  elsif v_annual_savings is null or v_annual_savings <= 0 then
    v_years := null;
  elsif v_r = 0 then
    v_years := (v_fi_number - v_net_worth) / v_annual_savings;
  else
    v_years := ln((v_fi_number + v_annual_savings / v_r) / (v_net_worth + v_annual_savings / v_r)) / ln(1 + v_r);
  end if;

  v_coast := case
    when v_fi_number is null or v_years is null then null
    when v_r = 0 then v_fi_number
    else v_fi_number / power(1 + v_r, v_years)
  end;

  return query select
    v_annual_spend,
    v_fi_number,
    v_net_worth,
    case when v_fi_number is null or v_fi_number = 0 or v_net_worth is null then null else v_net_worth / v_fi_number end,
    v_annual_savings,
    v_years,
    v_coast;
end;
$$;

revoke all on function fi_metrics(account_scope) from public;
grant execute on function fi_metrics(account_scope) to authenticated, service_role;
