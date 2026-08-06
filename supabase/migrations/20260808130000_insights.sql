-- Phase 15: Insights & savings rate. Four SECURITY INVOKER read functions —
-- RLS on `transactions`/`categories`/`balance_snapshots` already scopes
-- every one of these correctly (household-aware, via the same
-- can_read_account machinery every other read already relies on), so
-- there's no privilege bypass to reason about, same as fx_convert/
-- net_worth_series before them. All bucketing/summing happens here, never
-- client-side (money rule 3) — Swift only ever plots numbers this file
-- already computed.
--
-- A transfer has `category_id is null` (the CHECK constraint's own
-- "exactly one of transfer_group_id/category_id" rule) — filtering on
-- `category_id is not null` is what excludes both transfers AND valuation-
-- account activity (valuation accounts take transfers only, money rule 1)
-- from every function below, with no separate "is this a valuation
-- account" check needed anywhere.

-- ============================================================================
-- spending_by_category(scope, from, to) — expense categories only, summed
-- in the viewer's base currency. Per money rule 5: a category where ANY
-- contributing transaction can't be converted (a missing fx_rate) renders
-- null (→ "—" client-side), never a silently-partial sum — same
-- null-propagation shape as net_worth_series.
-- ============================================================================

create function spending_by_category(p_scope account_scope, p_from date, p_to date)
returns table (category_id uuid, category_name text, total numeric, currency text)
language plpgsql
security invoker
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
      when bool_or(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null) then null
      else sum(abs(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date)))
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

revoke all on function spending_by_category(account_scope, date, date) from public;
grant execute on function spending_by_category(account_scope, date, date) to authenticated, service_role;

-- ============================================================================
-- income_expense_series(scope, from, to, granularity) — granularity ('weekly'
-- /'monthly') is chosen client-side from the span via KeepoCore's existing
-- DateBucketing.granularity(from:through:) and passed in, never computed
-- twice — the exact "derived from the span, never a user control" rule
-- (app-architecture.md §5) this project already applies to Home's own
-- trajectory chart.
-- ============================================================================

create function income_expense_series(p_scope account_scope, p_from date, p_to date, p_granularity text)
returns table (bucket_start date, income numeric, expense numeric)
language plpgsql
security invoker
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
      when bool_or(t.amount > 0 and public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case when t.amount > 0 then public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) else 0 end
      )
    end,
    case
      when bool_or(t.amount < 0 and public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case
          when t.amount < 0 then abs(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date))
          else 0
        end
      )
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

revoke all on function income_expense_series(account_scope, date, date, text) from public;
grant execute on function income_expense_series(account_scope, date, date, text) to authenticated, service_role;

-- ============================================================================
-- savings_rate(scope, from, to) — (income - expense) / income, excluding
-- transfers and valuation changes (spec: otherwise moving money into
-- savings reads as an expense, and a market dip reads as a bad month).
-- Null (never 0, never a divide-by-zero) when income is zero or any
-- contributing amount can't be converted — money rule 5.
-- ============================================================================

create function savings_rate(p_scope account_scope, p_from date, p_to date)
returns numeric
language plpgsql
security invoker
stable
set search_path = ''
as $$
declare
  v_base text;
  v_income numeric;
  v_expense numeric;
begin
  select base_currency into v_base from public.profiles where id = (select auth.uid());

  select
    case
      when bool_or(t.amount > 0 and public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case when t.amount > 0 then public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) else 0 end
      )
    end,
    case
      when bool_or(t.amount < 0 and public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date) is null)
        then null
      else sum(
        case
          when t.amount < 0 then abs(public.fx_convert(t.amount, t.currency, v_base, t.occurred_at::date))
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

  return (v_income - v_expense) / v_income;
end;
$$;

revoke all on function savings_rate(account_scope, date, date) from public;
grant execute on function savings_rate(account_scope, date, date) to authenticated, service_role;

-- ============================================================================
-- unrealized_gain(account_id) — latest valuation minus every transfer ever
-- (spec: the cost basis is already in the ledger, so this metric is free).
-- Every transaction on a valuation account IS a transfer, by money rule 1 —
-- summing all of them is summing all transfers ever, with no separate
-- "is this a transfer leg" filter needed. Future-dated transfers excluded
-- via `occurred_at <= now()`, same guard account_balance_on already uses,
-- for the same reason: a not-yet-due row must never move a live number.
-- ============================================================================

create function unrealized_gain(p_account_id uuid)
returns numeric
language sql
security invoker
stable
set search_path = ''
as $$
  select
    (
      select bs.value from public.balance_snapshots bs
      where bs.account_id = p_account_id
      order by bs.as_of desc, bs.created_at desc
      limit 1
    )
    - coalesce(
      (
        select sum(t.amount) from public.transactions t
        where t.account_id = p_account_id and t.deleted_at is null and t.status = 'confirmed'
          and t.occurred_at <= now()
      ),
      0
    )
  where exists (select 1 from public.balance_snapshots bs where bs.account_id = p_account_id);
$$;

revoke all on function unrealized_gain(uuid) from public;
grant execute on function unrealized_gain(uuid) to authenticated, service_role;
