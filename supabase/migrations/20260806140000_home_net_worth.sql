-- Phase 8: Home dashboard & net worth trajectory.
--
-- H11: account_balances was hardcoded to current_date/now(), so a
-- historical trajectory couldn't reuse it without duplicating the one
-- ledger/valuation CASE that is this codebase's single most invariant-
-- critical piece of SQL. Extracted here into account_balance_on(account_id,
-- date); account_balances becomes a thin wrapper at current_date. This
-- migration's own pgTAP suite asserts the wrapper is byte-identical to the
-- pre-refactor view for every account already covered by earlier phases'
-- tests — this is a refactor, not a behavior change.
--
-- app-architecture.md §3 named account_balances as "where money rule 1's
-- two balance formulas actually live, in exactly one place" — amended
-- below (and in the doc itself) to name account_balance_on as that one
-- place instead, with account_balances as its current-date special case.
--
-- net_worth_daily is built exactly as app-architecture.md §3 specifies:
-- materialized per account, per day, in that account's own currency, never
-- pre-converted — conversion happens on read, at that day's rate, so a
-- base-currency change never rewrites history. No pg_cron exists yet
-- (Phase 13), so refresh_net_worth_daily() is called directly by the
-- client before rendering the trajectory; Phase 13's cron takes over that
-- job without this table's shape or RLS needing to change at all.
--
-- H15: fx_convert gains a same-currency short-circuit. Every other call
-- site tolerated resolving fx_rate_on(x, x) as "the same rate twice, which
-- cancels out" — fine as long as a rate row for that date existed. A
-- 365-point single-currency trajectory needs a resolvable rate on every
-- one of those dates or the whole chart renders "—"; converting a currency
-- to itself should never depend on fx_rates having a row at all.

-- ============================================================================
-- account_balance_on — the one ledger/valuation CASE, now parameterized by
-- date instead of hardcoded to current_date/now(). For p_date = today, this
-- must produce EXACTLY what account_balances always has — including the
-- future-dated guard ("a not-yet-materialized recurring row can never move
-- today's balance", migration 002's own comment). `least(p_date + 1 day,
-- now())` is what makes both cases the same expression: for any date
-- strictly before today, `p_date + 1 day` is always < now(), so the
-- LEAST picks it (the whole historical day counts). For p_date = today,
-- `p_date + 1 day` is tomorrow midnight, always > now(), so the LEAST
-- picks now() instead — reproducing `occurred_at <= now()` exactly, byte
-- for byte, which is what this migration's pgTAP suite actually checks
-- rather than trusts.
-- ============================================================================

create function account_balance_on(p_account_id uuid, p_date date)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select
    case a.kind
      when 'ledger' then a.opening_balance + coalesce((
        select sum(t.amount)
        from public.transactions t
        where t.account_id = a.id
          and t.deleted_at is null
          and t.status = 'confirmed'
          and t.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
      ), 0)
      when 'valuation' then (
        select bs.value + coalesce((
          select sum(t2.amount)
          from public.transactions t2
          where t2.account_id = a.id
            and t2.deleted_at is null
            and t2.status = 'confirmed'
            and t2.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
            and t2.occurred_at > bs.created_at
        ), 0)
        from public.balance_snapshots bs
        where bs.account_id = a.id and bs.as_of <= p_date
        order by bs.as_of desc
        limit 1
      )
    end
  from public.accounts a
  where a.id = p_account_id;
$$;

revoke all on function account_balance_on(uuid, date) from public;
grant execute on function account_balance_on(uuid, date) to authenticated, service_role;

-- account_balances: now a one-line wrapper. Same three columns, same order,
-- same types — every dependent view (account_balances_base,
-- accounts_with_balances) keeps working unchanged.
create or replace view account_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.currency,
  account_balance_on(a.id, current_date) as balance
from accounts a
where a.deleted_at is null;

-- ============================================================================
-- net_worth_daily — one row per account per day, in that account's own
-- currency. RLS mirrors can_read_account, not owner_id = auth.uid(): a
-- household member must be able to read a shared account's history for the
-- 'household'/'total' trajectory scopes, exactly as for the account itself.
-- No INSERT/UPDATE/DELETE grant to authenticated — every write goes
-- through refresh_net_worth_daily(), same "write only through a vetted
-- function" precedent as sync_conflicts and fx_rates.
-- ============================================================================

create table net_worth_daily (
  account_id uuid not null references accounts (id) deferrable initially deferred,
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  currency text not null,
  as_of date not null,
  balance numeric(20, 4),
  updated_at timestamptz not null default now(),
  primary key (account_id, as_of)
);

create index net_worth_daily_owner_as_of_idx on net_worth_daily (owner_id, as_of);

alter table net_worth_daily enable row level security;

create policy net_worth_daily_select on net_worth_daily
  for select to authenticated
  using (can_read_account(account_id));

grant select on net_worth_daily to authenticated, service_role;

-- refresh_net_worth_daily — populates/updates every day in [p_from, p_to]
-- for every account p_user owns (not "can read" — a household member
-- refreshes their own accounts' rows, never their partner's; the read side
-- is what crosses that boundary). SECURITY DEFINER so it can write despite
-- the table having no direct grant; still restricted to refreshing your
-- own data — auth.uid() is null under service_role (no user JWT), which is
-- how Phase 13's cron will call this for every user in turn without this
-- check ever standing in its way.
create function refresh_net_worth_daily(p_user uuid, p_from date, p_to date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null and (select auth.uid()) <> p_user then
    raise exception 'cannot refresh another user''s net worth history';
  end if;

  insert into public.net_worth_daily (account_id, owner_id, currency, as_of, balance)
  select a.id, a.owner_id, a.currency, gs.day::date, public.account_balance_on(a.id, gs.day::date)
  from public.accounts a
  cross join generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as gs (day)
  where a.owner_id = p_user and a.deleted_at is null
  on conflict (account_id, as_of) do update
  set balance = excluded.balance, currency = excluded.currency, updated_at = now();
end;
$$;

revoke all on function refresh_net_worth_daily(uuid, date, date) from public;
grant execute on function refresh_net_worth_daily(uuid, date, date) to authenticated, service_role;

-- ============================================================================
-- fx_convert: same-currency short-circuit (H15).
-- ============================================================================

create or replace function fx_convert(p_amount numeric, p_from text, p_to text, p_date date)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when p_from = p_to then p_amount
    else p_amount / public.fx_rate_on(p_from, p_date) * public.fx_rate_on(p_to, p_date)
  end;
$$;

-- ============================================================================
-- net_worth_series(scope, from, to) — the read side. SECURITY INVOKER: a
-- plain read over net_worth_daily (RLS already scopes it) plus the
-- viewer's own base_currency, no privilege bypass needed, same reasoning
-- as net_worth() and fx_convert/fx_rate_on before it. Per-day null
-- propagation mirrors net_worth(): a day with any unconvertible account in
-- scope renders NULL (→ "—", money rule 5), never a silently-partial sum.
-- A day with literally zero accounts in scope simply doesn't appear as a
-- row (GROUP BY can't produce an empty group) — the client treats "no rows
-- for this scope" as "nothing to plot," not as a flat, misleading $0 line.
-- ============================================================================

create function net_worth_series(p_scope account_scope, p_from date, p_to date)
returns table (as_of date, total numeric)
language plpgsql
security invoker
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
      when bool_or(public.fx_convert(nwd.balance, nwd.currency, v_base, nwd.as_of) is null) then null
      else sum(public.fx_convert(nwd.balance, nwd.currency, v_base, nwd.as_of))
    end as total
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

revoke all on function net_worth_series(account_scope, date, date) from public;
grant execute on function net_worth_series(account_scope, date, date) to authenticated, service_role;
