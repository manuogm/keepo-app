-- Archived accounts must not count toward net worth — the original
-- archive_account migration (20260805180000) already promised this in its
-- own comment ("drops out of default list views and net-worth totals... a
-- later phase's job, via include_in_total/archived_at") but nothing ever
-- filtered on it. account_balances_base carries no archived_at column
-- today, so net_worth() has no way to exclude an archived account's
-- balance from its sum. Fix at the source: append archived_at to the view
-- (CREATE OR REPLACE VIEW can only add trailing columns, never remove or
-- reorder — the 7 existing ones are untouched), then filter on it in
-- net_worth()'s three scope branches.
--
-- account_balances itself is deliberately left alone — an archived
-- account's own balance must still resolve correctly wherever it's shown
-- individually (AccountFormView, the Archive screen), just not summed into
-- the total.

create or replace view public.account_balances_base
with (security_invoker = true) as
select
  ab.account_id,
  ab.currency,
  ab.balance_e4,
  a.owner_id,
  p.base_currency,
  public.fx_convert(ab.balance_e4, ab.currency, p.base_currency, current_date) as balance_base_e4,
  ab.balance_e4 is not null
    and public.fx_convert(ab.balance_e4, ab.currency, p.base_currency, current_date) is null as has_missing_rate,
  a.archived_at
from public.account_balances ab
join public.accounts a on a.id = ab.account_id
left join public.profiles p on p.id = (select auth.uid());

create or replace function public.net_worth(p_scope public.account_scope)
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
      where ab.archived_at is null
        and not exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
    )
    when 'household' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where ab.archived_at is null
        and exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
    )
    when 'total' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where ab.archived_at is null
    )
  end;
$$;
