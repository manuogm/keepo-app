-- A partner is handed what they can see.
--
-- Phase 2 of the "Transfers & household sharing" workstream
-- (keepo-v1-master-plan.md), and review finding #9. Like Phase 1 it changes
-- nothing a user can see today — no share has a start date yet — except that
-- rows which should always have reached the other phone now do.
--
-- ============================================================================
-- 1. The partner's opening balance is the balance carried into the start date
-- ============================================================================
--
-- A device computes a balance as `opening_balance_e4 + SUM(amount_e4)` over
-- the rows it holds (money rule 1). A partner holds only rows from the start
-- date on, so `pull_changes` hands them the account with an opening that is
-- the balance carried into that moment, dated on the owner's calendar day it
-- began. The same formula then lands on the true balance, with no second
-- formula on the device. The figure is computed on every read and never
-- stored: it moves whenever the owner changes anything before the start date,
-- and a stored copy would be one more thing to keep in step.
--
-- `account_balance_through(account, moment)` is now the one statement of the
-- formula. `account_balance_on` (a calendar day, capped at now) and the
-- carried opening (everything strictly before the start date) are both
-- calls to it.
--
-- ============================================================================
-- 2. A change before the start date re-sends the account
-- ============================================================================
--
-- The partner never receives those rows, so without help their device would
-- keep the old carried opening forever. A trigger re-stamps the account
-- whenever a transaction before a start date is created, or changes amount,
-- status, account, date or deletion. The partner re-pulls the row, and
-- `pull_changes` computes the new figure.
--
-- ============================================================================
-- 3. What a share reveals is re-sent with it (#9)
-- ============================================================================
--
-- `pull_changes` sends rows whose `sync_seq` is past the device's cursor, so a
-- row that becomes visible without changing is never sent. `share_account`
-- re-stamped the account, its transactions and its rules. It skipped
-- everything visible only *because of* them: the transactions' tag links, the
-- tags and categories they wear, and the rules' tag links. Those reached the
-- partner only when something else happened to touch them. Two later events
-- have the same gap, and each gets a trigger:
--
--   * a tag applied to a transaction the household sees (the partner's own
--     tag on the owner's account, or an old tag of either) re-sends the tag;
--   * a category starting to label a transaction the household sees re-sends
--     the category.
--
-- Re-stamping sends one small row to every device again. It never changes a
-- version or a value.
--
-- `accept_invite` already re-sends everything by bumping both members' sync
-- epochs; this is for the account shared later, and for the everyday cases.
--
-- ============================================================================
-- 4. The re-stamp flag is restored, not reset
-- ============================================================================
--
-- `keepo.restamp_only` tells `bump_version` that a write only re-sends a row.
-- `restamp_account_for_sync` set it to 'false' when done. Now that a re-stamp
-- can happen inside another (a trigger firing during one), that would switch
-- the flag off halfway through the outer re-stamp, and every later row it
-- touched would get a spurious version bump. `begin_restamp`/`end_restamp`
-- put back whatever was there.

-- ============================================================================
-- The balance formula, once
-- ============================================================================

create function public.account_balance_through(p_account_id uuid, p_through timestamptz)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select a.opening_balance_e4 + coalesce((
    select sum(t.amount_e4)
    from public.transactions t
    where t.account_id = a.id
      and t.deleted_at is null
      and t.status = 'confirmed'
      and t.occurred_at <= p_through
  ), 0)
  from public.accounts a
  where a.id = p_account_id;
$$;

revoke all on function public.account_balance_through(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.account_balance_on(p_account_id uuid, p_date date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select public.account_balance_through(a.id, least(p_date::timestamptz + interval '1 day', now()))
  from public.accounts a
  where a.id = p_account_id
    and ((select auth.uid()) is null or public.can_read_account(a.id));
$$;

-- What the caller's device should hold as this account's opening: `{}` (keep
-- the stored row) for the owner and for a share with full history, or the
-- carried balance for a partner. `timestamptz` has microsecond resolution, so
-- "through one microsecond before the start" is exactly "before the start".
create function public.account_opening_as_seen(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select jsonb_build_object(
      'opening_balance_e4',
      public.account_balance_through(a.id, ha.history_from - interval '1 microsecond'),
      'opening_balance_at',
      (ha.history_from at time zone coalesce(public.safe_time_zone(p.time_zone), 'UTC'))::date
    )
    from public.accounts a
    join public.household_accounts ha
      on ha.account_id = a.id and ha.deleted_at is null and ha.history_from is not null
    join public.profiles p on p.id = a.owner_id
    where a.id = p_account_id
      and a.owner_id <> (select auth.uid())
      and public.can_read_account(a.id)
  ), '{}'::jsonb);
$$;

-- `pull_changes` runs as its caller. It answers only about an account the
-- caller can already read, and only with what `account_balance_on` already
-- gives them.
revoke all on function public.account_opening_as_seen(uuid) from public, anon;
grant execute on function public.account_opening_as_seen(uuid) to authenticated, service_role;

-- ============================================================================
-- pull_changes — the accounts entry only
-- ============================================================================

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table(payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  -- Changed 20261003100000: the budget is the server's, not this call's.
  if not public.ops_check_own_rate_limit('pull_changes') then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());
  v_epoch := coalesce(v_epoch, 0);

  select jsonb_build_object(
    -- Changed 20261010100000: a partner's opening is the balance carried
    -- into the start date.
    'accounts', coalesce((
      select jsonb_agg(to_jsonb(a) || public.account_opening_as_seen(a.id))
      from public.accounts a where a.sync_seq > p_cursor
    ), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('units_per_eur', fr.units_per_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(to_jsonb(tg)) from public.tags tg where tg.sync_seq > p_cursor), '[]'::jsonb),
    'transaction_tags', coalesce((select jsonb_agg(to_jsonb(tt)) from public.transaction_tags tt where tt.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rules', coalesce((select jsonb_agg(to_jsonb(rr)) from public.recurring_rules rr where rr.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rule_tags', coalesce((select jsonb_agg(to_jsonb(rt)) from public.recurring_rule_tags rt where rt.sync_seq > p_cursor), '[]'::jsonb),
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
    union all select max(sync_seq) from public.tags where sync_seq > p_cursor
    union all select max(sync_seq) from public.transaction_tags where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rules where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rule_tags where sync_seq > p_cursor
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

-- ============================================================================
-- Re-stamping
-- ============================================================================

create function public.begin_restamp()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_previous text := coalesce(current_setting('keepo.restamp_only', true), 'false');
begin
  perform set_config('keepo.restamp_only', 'true', true);
  return v_previous;
end;
$$;

create function public.end_restamp(p_previous text)
returns void
language sql
volatile
set search_path = ''
as $$
  select set_config('keepo.restamp_only', p_previous, true);
$$;

revoke all on function public.begin_restamp() from public, anon, authenticated;
revoke all on function public.end_restamp(text) from public, anon, authenticated;

create or replace function public.restamp_account_for_sync(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous text := public.begin_restamp();
begin
  update public.accounts set id = id where id = p_account_id;
  update public.transactions set id = id where account_id = p_account_id and deleted_at is null;
  update public.recurring_rules set id = id
  where account_id = p_account_id or to_account_id = p_account_id;

  -- What those rows reveal (#9).
  update public.transaction_tags tt set tag_id = tag_id
  from public.transactions t
  where t.id = tt.transaction_id and t.account_id = p_account_id and t.deleted_at is null
    and tt.deleted_at is null;

  update public.tags tg set id = id
  where tg.deleted_at is null and exists (
    select 1
    from public.transaction_tags tt
    join public.transactions t on t.id = tt.transaction_id
    where tt.tag_id = tg.id and tt.deleted_at is null
      and t.account_id = p_account_id and t.deleted_at is null
  );

  update public.categories c set id = id
  where c.deleted_at is null and exists (
    select 1 from public.transactions t
    where t.category_id = c.id and t.account_id = p_account_id and t.deleted_at is null
  );

  update public.recurring_rule_tags rt set tag_id = tag_id
  from public.recurring_rules rr
  where rr.id = rt.recurring_rule_id and rt.deleted_at is null
    and (rr.account_id = p_account_id or rr.to_account_id = p_account_id);

  perform public.end_restamp(v_previous);
end;
$$;

-- A transaction write re-sends what it newly reveals to the household.
create function public.restamp_what_a_transaction_reveals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous text;
  v_moved boolean;
  v_newly_labelled boolean;
begin
  -- A re-stamp changes nothing a balance or a household can see.
  if coalesce(current_setting('keepo.restamp_only', true), 'false') = 'true' then
    return null;
  end if;

  v_moved := tg_op = 'INSERT'
    or old.amount_e4 is distinct from new.amount_e4
    or old.status is distinct from new.status
    or old.deleted_at is distinct from new.deleted_at
    or old.account_id is distinct from new.account_id
    or old.occurred_at is distinct from new.occurred_at;

  v_newly_labelled := tg_op = 'INSERT'
    or old.category_id is distinct from new.category_id
    or old.account_id is distinct from new.account_id
    or old.occurred_at is distinct from new.occurred_at
    or (old.deleted_at is not null and new.deleted_at is null);

  if not v_moved and not v_newly_labelled then
    return null;
  end if;

  v_previous := public.begin_restamp();

  -- A partner's carried opening includes every row before the start date,
  -- where it was and where it is now.
  if v_moved then
    update public.accounts a set id = id
    where a.id in (new.account_id, case when tg_op = 'UPDATE' then old.account_id end)
      and exists (
        select 1 from public.household_accounts ha
        where ha.account_id = a.id and ha.deleted_at is null and ha.history_from is not null
          and (
            (a.id = new.account_id and new.occurred_at < ha.history_from)
            or (tg_op = 'UPDATE' and a.id = old.account_id and old.occurred_at < ha.history_from)
          )
      );
  end if;

  -- A category the household had no reason to see until now.
  if v_newly_labelled and new.category_id is not null and new.deleted_at is null
     and public.transaction_shared_into(new.account_id, new.occurred_at) is not null then
    update public.categories set id = id where id = new.category_id;
  end if;

  perform public.end_restamp(v_previous);
  return null;
end;
$$;

revoke all on function public.restamp_what_a_transaction_reveals() from public, anon, authenticated;

create trigger transactions_restamp_what_it_reveals
  after insert or update on public.transactions
  for each row execute function public.restamp_what_a_transaction_reveals();

-- A tag the household had no reason to see until now.
create function public.restamp_what_a_tag_link_reveals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous text;
begin
  if coalesce(current_setting('keepo.restamp_only', true), 'false') = 'true' then
    return null;
  end if;

  if exists (
    select 1 from public.transactions t
    where t.id = new.transaction_id and t.deleted_at is null
      and public.transaction_shared_into(t.account_id, t.occurred_at) is not null
  ) then
    v_previous := public.begin_restamp();
    update public.tags set id = id where id = new.tag_id;
    perform public.end_restamp(v_previous);
  end if;

  return null;
end;
$$;

revoke all on function public.restamp_what_a_tag_link_reveals() from public, anon, authenticated;

create trigger transaction_tags_restamp_what_it_reveals
  after insert or update of tag_id, deleted_at on public.transaction_tags
  for each row
  when (new.deleted_at is null)
  execute function public.restamp_what_a_tag_link_reveals();
