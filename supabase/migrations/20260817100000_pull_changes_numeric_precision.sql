-- Local-first L5: pull_changes fix, found before writing a single line of
-- client-side ingestion code. `to_jsonb(row)` converts every `numeric`
-- column of a table into a JSON *number*, not a string — Postgres's own
-- to_json/to_jsonb behavior for `numeric`. `fx_rates.rate_to_eur` and
-- `fi_settings.withdrawal_rate`/`real_return_rate` are the only three
-- remaining `numeric` columns anywhere in the syncable set (every money
-- amount became bigint `_e4` in L1's own migration; these three are rates,
-- not amounts, so L1 deliberately left them numeric). A client decoding
-- that JSON number into a Swift floating-point type before re-encoding it
-- as the local store's TEXT decimal string would silently reintroduce
-- exactly the binary-float imprecision L1 eliminated and L4's referee
-- verified was gone — "0.9000" round-tripping through a JSON number and a
-- Double is not guaranteed to come back out as "0.9000" or even an
-- equivalent decimal. Fixed by overriding just those three keys with an
-- explicit `::text` cast merged onto the row's own `to_jsonb` output,
-- leaving every other column (already bigint/text/uuid/timestamptz, all of
-- which round-trip through JSON exactly) untouched.
--
-- `pull_changes`'s signature is unchanged, so `create or replace` (not a
-- drop-and-recreate) is correct here — same precedent as
-- 20260816100001_sync_primitives_fixes.sql's own header comment about never
-- editing an already-pushed migration file's content in place.

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
security invoker
stable
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'balance_snapshots', coalesce((select jsonb_agg(to_jsonb(bs)) from public.balance_snapshots bs where bs.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('rate_to_eur', fr.rate_to_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(bud)) from public.budgets bud where bud.sync_seq > p_cursor), '[]'::jsonb),
    'fi_settings', coalesce((
      select jsonb_agg(
        to_jsonb(fs) || jsonb_build_object('withdrawal_rate', fs.withdrawal_rate::text, 'real_return_rate', fs.real_return_rate::text)
      )
      from public.fi_settings fs where fs.sync_seq > p_cursor
    ), '[]'::jsonb),
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
    union all select max(sync_seq) from public.balance_snapshots where sync_seq > p_cursor
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.budgets where sync_seq > p_cursor
    union all select max(sync_seq) from public.fi_settings where sync_seq > p_cursor
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

grant execute on function public.pull_changes(bigint, bigint) to authenticated;
