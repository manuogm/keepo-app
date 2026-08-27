-- fx_rates.rate_to_eur -> fx_rates.units_per_eur
--
-- The column has always held **units of the currency per 1 EUR** — the shape
-- Frankfurter returns for `?base=EUR`, which sync-fx-rates stores verbatim,
-- and the shape fx_convert's `amount / rate(from) * rate(to)` requires. Its
-- name says the opposite ("multiply by this to get EUR"), and that has now
-- cost two separate readers an hour each of proving the conversion chain was
-- not inverted — see version-logs/phase-18-log.md §5, which had to restate
-- the convention in prose precisely because the name would not.
--
-- Worse than wasted reading: the seeds followed the name rather than the
-- data. supabase/seed.sql wrote USD at 0.92, which read correctly says a euro
-- buys 92 cents, so every dev dashboard quoted EUR/USD about 20% low while
-- the arithmetic around it was perfectly correct.
--
-- **No values change.** This is a rename and three function bodies. Every
-- stored number already means what `units_per_eur` says.
--
-- DEPLOY ORDER: this migration first, then the client. The rename changes the
-- key `pull_changes` emits for fx rows, and the argument name the
-- sync-fx-rates Edge Function passes to upsert_fx_rate() — an older client or
-- an undeployed function talks to the new schema in the old vocabulary and
-- gets a "function does not exist" or a silently dropped column. Deploy
-- sync-fx-rates alongside this, and ship the app build that carries the
-- matching LocalSchemaV1 in the same release.

alter table fx_rates rename column rate_to_eur to units_per_eur;

-- ============================================================================
-- upsert_fx_rate — recreated rather than replaced. Postgres cannot rename an
-- input parameter through CREATE OR REPLACE ("cannot change name of input
-- parameter"), and the Edge Function calls this with *named* arguments, so
-- the parameter has to change with the column or the call stops resolving.
-- Body is otherwise the 20260805152725 definition verbatim: still the only
-- way anything writes to fx_rates, still owning the "later fetched_at wins"
-- rule as a real WHERE clause, still SECURITY DEFINER because fx_rates has no
-- INSERT/UPDATE grant to anyone.
-- ============================================================================

drop function if exists upsert_fx_rate(text, date, numeric, fx_source, timestamptz);

create function upsert_fx_rate(
  p_currency text,
  p_rate_date date,
  p_units_per_eur numeric,
  p_source fx_source default 'ecb',
  p_fetched_at timestamptz default now()
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.fx_rates (currency, rate_date, units_per_eur, source, fetched_at)
  values (p_currency, p_rate_date, p_units_per_eur, p_source, p_fetched_at)
  on conflict (currency, rate_date) do update
  set units_per_eur = excluded.units_per_eur,
      source = excluded.source,
      fetched_at = excluded.fetched_at
  where excluded.fetched_at > public.fx_rates.fetched_at;
$$;

revoke all on function upsert_fx_rate(text, date, numeric, fx_source, timestamptz) from public;
grant execute on function upsert_fx_rate(text, date, numeric, fx_source, timestamptz) to service_role;

-- ============================================================================
-- fx_rate_on — the column reference in the body resolves at run time, so the
-- rename would break it. Restated in full rather than patched from an
-- excerpt.
--
-- **Returns units of p_currency per 1 EUR.** EUR is structurally 1, which is
-- why it is never stored. fx_convert reads this as
-- `amount / rate(from) * rate(to)`: divide out of the source currency into
-- euros, multiply into the target. That is the EUR pivot, and it is the only
-- direction consistent with what upsert_fx_rate writes.
-- ============================================================================

create or replace function fx_rate_on(p_currency text, p_date date)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when p_currency = 'EUR' then 1
    else (
      select fr.units_per_eur
      from public.fx_rates fr
      where fr.currency = p_currency and fr.rate_date <= p_date
      order by fr.rate_date desc
      limit 1
    )
  end;
$$;

revoke all on function fx_rate_on(text, date) from public;
grant execute on function fx_rate_on(text, date) to authenticated, service_role;

-- ============================================================================
-- pull_changes — the fx_rates branch names the column twice: once as the key
-- it overrides and once as the value it casts. Restated in full from the
-- 20260902100000 definition, re-read end to end rather than patched from an
-- excerpt, per version-logs/lessons-learned.md.
--
-- The `::text` cast is not incidental: `to_jsonb` renders a `numeric` as a
-- JSON *number*, and supabase-swift would decode that through Double, which
-- has already lost precision by the time it exists (money rule 3). The
-- override re-renders it as a string. See 20260817100000.
-- ============================================================================

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  if not public.ops_check_own_rate_limit('pull_changes', 30, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('units_per_eur', fr.units_per_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(bud)) from public.budgets bud where bud.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rules', coalesce((select jsonb_agg(to_jsonb(rr)) from public.recurring_rules rr where rr.sync_seq > p_cursor), '[]'::jsonb),
    'card_mappings', coalesce((select jsonb_agg(to_jsonb(cm)) from public.card_mappings cm where cm.sync_seq > p_cursor), '[]'::jsonb),
    'merchant_category_map', coalesce((select jsonb_agg(to_jsonb(mcm)) from public.merchant_category_map mcm where mcm.sync_seq > p_cursor), '[]'::jsonb),
    'sync_conflicts', coalesce((select jsonb_agg(to_jsonb(sc)) from public.sync_conflicts sc where sc.sync_seq > p_cursor), '[]'::jsonb),
    'households', coalesce((select jsonb_agg(to_jsonb(h)) from public.households h where h.sync_seq > p_cursor), '[]'::jsonb),
    'household_members', coalesce((select jsonb_agg(to_jsonb(hm)) from public.household_members hm where hm.sync_seq > p_cursor), '[]'::jsonb),
    'household_accounts', coalesce((select jsonb_agg(to_jsonb(ha)) from public.household_accounts ha where ha.sync_seq > p_cursor), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(to_jsonb(p)) from public.profiles p where p.sync_seq > p_cursor), '[]'::jsonb)
  ) into v_payload;

  select coalesce(max(m), p_cursor) into v_next_cursor from (
    select max(sync_seq) as m from public.accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.transactions where sync_seq > p_cursor
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.budgets where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rules where sync_seq > p_cursor
    union all select max(sync_seq) from public.card_mappings where sync_seq > p_cursor
    union all select max(sync_seq) from public.merchant_category_map where sync_seq > p_cursor
    union all select max(sync_seq) from public.sync_conflicts where sync_seq > p_cursor
    union all select max(sync_seq) from public.households where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_members where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.profiles where sync_seq > p_cursor
  ) s;

  select coalesce(max(m), p_global_cursor) into v_next_global_cursor from (
    select max(sync_seq) as m from public.currencies where sync_seq > p_global_cursor
    union all select max(sync_seq) from public.fx_rates where sync_seq > p_global_cursor
  ) g;

  return query select v_payload, v_next_cursor, v_next_global_cursor, v_epoch;
end;
$$;

revoke all on function public.pull_changes(bigint, bigint) from public, anon;
grant execute on function public.pull_changes(bigint, bigint) to authenticated;
