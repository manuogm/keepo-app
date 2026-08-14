-- L7 UX pass: a valuation account's net worth series went blank on every
-- date before the account's own opening (e.g. an investment account opened
-- this month poisoning a chart spanning the last 90 days). account_balance_on
-- only ever looked for a snapshot with as_of <= p_date; for any earlier date
-- that's nothing, so the CASE expression returned NULL, which correctly
-- means "unknown" per money rule 5 but was too aggressive here — a ledger
-- account in the same situation falls back to opening_balance_e4 and stays
-- computable, so a valuation account should symmetrically fall back to its
-- own earliest snapshot rather than going unknown for its entire pre-history.
-- Still NULL if the account has no snapshot at all.
create or replace function account_balance_on(p_account_id uuid, p_date date)
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
        where bs.account_id = a.id
        -- Prefer the latest snapshot at-or-before p_date (original
        -- behavior); if none exists, fall back to the account's earliest
        -- snapshot overall instead of returning nothing.
        order by
          case when bs.as_of <= p_date then 0 else 1 end,
          case when bs.as_of <= p_date then bs.as_of end desc,
          case when bs.as_of <= p_date then bs.created_at end desc,
          case when bs.as_of > p_date then bs.as_of end asc,
          case when bs.as_of > p_date then bs.created_at end asc
        limit 1
      )
    end
  from public.accounts a
  where a.id = p_account_id;
$$;

revoke all on function account_balance_on(uuid, date) from public;
grant execute on function account_balance_on(uuid, date) to authenticated, service_role;
