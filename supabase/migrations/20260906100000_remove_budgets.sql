-- Remove budgets entirely — table, RPC, and sync wiring.
--
-- Product decision: the broader concept of **tags** absorbs what budgets
-- did. A budget was a monthly cap on one category (or an overall one); a
-- tag is a free label applied across categories and transaction kinds, and
-- the tracking a user actually wanted from a budget is a question about
-- tagged transactions, not a second table holding a number per month.
--
-- Nothing is migrated forward. A budget row is (category, month, amount) —
-- a tag carries none of those, so there is no shape to translate it into.
-- The Budgets screen was also never reachable from the dashboard: the
-- Budgets widget was deliberately never built because `budgets` is
-- owner-scoped only and could not honour the Total/Private/Household scope
-- filter every other widget respects. Rather than give budgets the
-- household clause it was missing, the feature goes and tags — which are
-- household-aware from the start — take its place.
--
-- Deploy order (CLAUDE.md): this migration first, then the app build that
-- drops `budgets` from `LocalSchemaV1`/`SyncApply`. An older client pulling
-- against this schema simply stops receiving a `budgets` key, which
-- `SyncApply.apply` already skips silently (it iterates the payload's own
-- keys and ignores any table it doesn't know), so the ordering is safe in
-- both directions rather than merely tolerable in one.

-- ============================================================================
-- The read side goes first — budget_progress is the only caller of the
-- table that isn't the table's own triggers.
-- ============================================================================

drop function if exists budget_progress(date);

-- `cascade` carries the three policies, the two partial unique indexes, the
-- sync_seq index and the four triggers with it. Named here for the record
-- rather than dropped one by one, since dropping the table is what the
-- change actually is: budgets_select/insert/update, budgets_category_month_idx,
-- budgets_overall_month_idx, budgets_sync_seq_idx, budgets_bump_version,
-- budgets_set_updated_at, budgets_normalize_period_month, budgets_stamp_sync_seq.
drop table if exists budgets cascade;

-- Trigger function, orphaned by the table above — its only trigger was
-- budgets_normalize_period_month, confirmed against pg_trigger before this
-- migration was written. Nothing else in the schema normalizes a month.
drop function if exists normalize_budget_period_month();

-- ============================================================================
-- pull_changes — restated in full from the 20260905100000 definition, minus
-- the two budgets branches (the payload key and the cursor union arm),
-- re-read end to end rather than patched from an excerpt, per
-- version-logs/lessons-learned.md.
--
-- The fx_rates `::text` override stays exactly as it was: `to_jsonb` renders
-- a `numeric` as a JSON *number*, which supabase-swift would decode through
-- Double, losing precision before the value exists (money rule 3).
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
