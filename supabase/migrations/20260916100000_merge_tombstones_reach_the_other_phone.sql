-- Merging two categories worked on the server and did nothing on the phone.
--
-- ============================================================================
-- The defect
-- ============================================================================
--
-- `apply_category_merges` retires the two redundant twins like this:
--
--     set deleted_at = now(), shared_group_id = null, merge_origin = null
--
-- and `can_read_category` admits another member's category only while
-- `c.shared_group_id is not null`. So the statement that deletes the row is
-- the same statement that makes it unreadable to the member who needs to hear
-- about the deletion.
--
-- `pull_changes` is an incremental pull under RLS: it sends the rows you can
-- **see** whose `sync_seq` is past your cursor. A tombstone you cannot see is
-- not a tombstone you receive. So the other member's device never learns the
-- twin is gone and keeps it — live, inside the merged group — for good.
--
-- This is why a merge "did nothing" on screen. The report re-reads the local
-- mirror after the RPC returns, and the mirror still holds the pre-merge
-- shape: the phantom twin sits in the group alongside the two rows that
-- actually merged, and the household reads as one category more than it has.
-- Nothing errors, and the fix is not a client-side filter — the invariant
-- broke here, in the statement that revoked read access to its own delete.
--
-- ============================================================================
-- The rule this migration writes down
-- ============================================================================
--
-- **A soft delete must stay readable to everyone who could read the row.**
-- A tombstone is not a row of data, it is a message, and revoking access to
-- it in the act of writing it means the message is never delivered. So the
-- twin keeps its `shared_group_id`: nothing reads a deleted category (every
-- query filters `deleted_at is null`, on both sides), the propagate trigger
-- already skips deleted siblings, and there is no unique index over
-- `(shared_group_id, owner_id)` for a retired row to collide with.
--
-- Where visibility genuinely *is* being revoked — a row released back to
-- private, an unshare, an unmerge — the row stays alive and the other
-- member is no longer entitled to it, so there is no tombstone to send and
-- no way to say so incrementally. That is exactly what `sync_epoch` is for,
-- and the three sites below now bump it.
-- ============================================================================

-- ============================================================================
-- 1. One place that bumps a household's epochs
--
-- Fifth call site for this statement (`create_household`, `accept_invite`,
-- `leave_household` already carry their own copies), and the third being
-- written today — CLAUDE.md's "two can stay duplicated, a third is the
-- signal". The three existing ones are deliberately left alone: restating
-- two long, security-critical function bodies to route them through a
-- helper is churn with real risk and no behaviour change.
-- ============================================================================

create or replace function bump_household_sync_epochs(p_household_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles set sync_epoch = sync_epoch + 1
  where id in (
    select hm.user_id from public.household_members hm
    where hm.household_id = p_household_id and hm.deleted_at is null
  );
$$;

revoke all on function bump_household_sync_epochs(uuid) from public;

comment on function bump_household_sync_epochs(uuid) is
  'Forces both members to wipe and re-pull. For changes that REMOVE visibility, which an incremental pull can never deliver.';

-- ============================================================================
-- 2. The merge keeps its tombstones readable
--
-- Restated from `pg_get_functiondef` with two changes and nothing else —
-- 20260911100000's lesson, re-earned in 20260914100000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.apply_category_merges(p_merges jsonb, p_automatic boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_merge jsonb;
  v_mine public.categories;
  v_theirs public.categories;
  v_group_id uuid;
  v_name text;
  v_icon text;
  v_color text;
  v_applied integer := 0;
  v_released integer := 0;
begin
  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  if public.household_owner_id(v_household_id) <> v_me then
    raise exception 'only the household owner can merge categories';
  end if;

  if not public.ops_check_own_rate_limit('apply_category_merges', 60, 60) then
    raise exception 'rate limit exceeded';
  end if;

  for v_merge in select * from jsonb_array_elements(coalesce(p_merges, '[]'::jsonb))
  loop
    select * into v_mine from public.categories
    where id = (v_merge->>'mine')::uuid and deleted_at is null;
    select * into v_theirs from public.categories
    where id = (v_merge->>'theirs')::uuid and deleted_at is null;

    if v_mine.id is null or v_theirs.id is null then
      raise exception 'category not found';
    end if;

    -- Each row must belong to a live member of *this* household. Without
    -- this an owner could name any uuid they had ever seen and rewrite a
    -- stranger's category, which is precisely what SECURITY DEFINER removes
    -- the database's own protection against.
    if not exists (
      select 1 from public.household_members
      where household_id = v_household_id and user_id = v_mine.owner_id and deleted_at is null
    ) or not exists (
      select 1 from public.household_members
      where household_id = v_household_id and user_id = v_theirs.owner_id and deleted_at is null
    ) then
      raise exception 'both categories must belong to members of your household';
    end if;

    if v_mine.owner_id = v_theirs.owner_id then
      raise exception 'a category cannot be merged with another of your own';
    end if;

    if v_mine.kind <> v_theirs.kind then
      raise exception 'an expense category cannot be merged with an income one';
    end if;

    -- The two "Other" rows are each member's own fallback. Merging one would
    -- leave a member with no default of that kind, and
    -- `categories_one_default_per_kind` would refuse the repair.
    if v_mine.is_default or v_theirs.is_default then
      raise exception 'the default category cannot be merged';
    end if;

    -- Either row may already be in a group — the ceremony shares categories
    -- before it merges them, so both usually are. Reuse the caller's group
    -- and fold the other row into it, so a merge never strands a group id
    -- that some third row still points at.
    v_group_id := coalesce(v_mine.shared_group_id, v_theirs.shared_group_id, gen_random_uuid());

    v_name := coalesce(nullif(btrim(v_merge->>'name'), ''), v_mine.name);
    v_icon := coalesce(nullif(v_merge->>'icon', ''), v_mine.icon);
    v_color := coalesce(nullif(v_merge->>'color', ''), v_mine.color);

    -- Both rows usually arrive already in groups of their own, because the
    -- ceremony shares categories before it merges them and `share_category`/
    -- `ensure_category_twin` create the other member's row when there is no
    -- exact name match. So "Dine Out" and "Dining Out" each spawn a twin, and
    -- this merge is precisely the statement that those four rows were only
    -- ever two categories.
    --
    -- The two redundant twins are **soft-deleted, not released**. Releasing
    -- them would leave each member holding a private copy of the other's
    -- original spelling — the exact duplication the merge was performed to
    -- remove, now wearing a different label. They are deleted only when
    -- nothing has been filed under them, which for a twin minted seconds ago
    -- by the sharing step is always; a row that somehow carries history is
    -- released to private instead and shows up in the report's Extra list,
    -- where the owner can see it and decide.
    --
    -- `shared_group_id` is deliberately LEFT IN PLACE on the tombstone. It is
    -- the only thing `can_read_category` admits another member's row by, and
    -- a delete the other phone cannot read is a delete it never receives —
    -- see this migration's header. Nothing reads a deleted category on either
    -- side, so the retired link costs nothing and carries the message.
    update public.categories c
    set deleted_at = now(), merge_origin = null
    where c.shared_group_id is not null
      and c.shared_group_id in (v_mine.shared_group_id, v_theirs.shared_group_id)
      and c.id not in (v_mine.id, v_theirs.id)
      and c.deleted_at is null
      -- Never a row that was itself merged. `merge_origin` is only set on a
      -- pair somebody joined deliberately, so a row carrying one is a real
      -- category of that member's — the previous partner of a merge being
      -- re-pointed at somebody else, say. Those are released to private. Only
      -- a plain twin, minted by the sharing step and used by nobody, is
      -- deleted.
      and c.merge_origin is null
      and not exists (
        select 1 from public.transactions t where t.category_id = c.id and t.deleted_at is null
      )
      -- `recurring_rules` has no `deleted_at` — it retires a rule with
      -- `active = false` and keeps the row — so presence, not liveness, is
      -- what disqualifies a twin here.
      and not exists (
        select 1 from public.recurring_rules r where r.category_id = c.id
      )
      and not exists (
        select 1 from public.merchant_category_map m where m.category_id = c.id
      );

    -- Whatever survived that guard still cannot stay in the group: one row
    -- per member is the invariant every reader depends on. This one *is* a
    -- revocation — the row stays alive and stops being shared — so it is
    -- counted, and the epochs are bumped once at the end.
    with released as (
      update public.categories
      set shared_group_id = null, merge_origin = null
      where shared_group_id is not null
        and shared_group_id in (v_mine.shared_group_id, v_theirs.shared_group_id)
        and id not in (v_mine.id, v_theirs.id)
        and deleted_at is null
      returning 1
    )
    select v_released + count(*) into v_released from released;

    -- `p_merges` elements carry no origin: the automatic pass and the
    -- owner's own manual merge call the same RPC, and which one it was is
    -- decided by `p_automatic` for the whole batch. The automatic pass is one
    -- batch made without anybody being asked; a manual merge is one element
    -- the owner filled in by hand.
    update public.categories
    set shared_group_id = v_group_id, name = v_name, icon = v_icon, color = v_color,
        merge_origin = case when p_automatic then 'automatic'::public.category_merge_origin
                            else 'manual'::public.category_merge_origin end
    where id in (v_mine.id, v_theirs.id);

    v_applied := v_applied + 1;
  end loop;

  -- Only when something was actually un-shared. The common path — every twin
  -- retired as a tombstone — leaves both mirrors reconcilable by the ordinary
  -- incremental pull, and forcing a full re-pull per merge would make the
  -- owner's report stutter through the wipe on every tap.
  if v_released > 0 then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;

  return v_applied;
end;
$function$;

-- ============================================================================
-- 3. Unmerging and unsharing are revocations, and say so
--
-- Both take a live row out of a shared group, which is the one change an
-- incremental pull cannot express: the row simply stops being visible, and
-- "stops being visible" arrives as silence. Both members re-pull in full.
-- ============================================================================

create or replace function unmerge_category_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
begin
  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  if public.household_owner_id(v_household_id) <> v_me then
    raise exception 'only the household owner can unmerge categories';
  end if;

  if not exists (
    select 1 from public.categories c
    join public.household_members m
      on m.user_id = c.owner_id and m.household_id = v_household_id and m.deleted_at is null
    where c.shared_group_id = p_group_id and c.deleted_at is null
  ) then
    raise exception 'no such shared category in your household';
  end if;

  update public.categories set shared_group_id = null, merge_origin = null
  where shared_group_id = p_group_id;

  perform public.bump_household_sync_epochs(v_household_id);
end;
$$;

create or replace function unshare_category(p_category_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source record;
  v_household_id uuid := public.my_household_id();
begin
  select * into v_source from public.categories where id = p_category_id and deleted_at is null;
  if v_source.id is null or v_source.owner_id <> (select auth.uid()) then
    raise exception 'category not found or not owned by you';
  end if;

  if v_source.shared_group_id is null then
    return;
  end if;

  update public.categories set shared_group_id = null, merge_origin = null
  where shared_group_id = v_source.shared_group_id;

  if v_household_id is not null then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;
end;
$$;

revoke all on function unshare_category(uuid) from public;
grant execute on function unshare_category(uuid) to authenticated, service_role;
revoke all on function unmerge_category_group(uuid) from public;
grant execute on function unmerge_category_group(uuid) to authenticated, service_role;
revoke all on function apply_category_merges(jsonb, boolean) from public;
grant execute on function apply_category_merges(jsonb, boolean) to authenticated, service_role;

-- ============================================================================
-- 4. `pull_changes` at 30 a minute is a limit the app itself trips
--
-- It was set when a pull was a screen-level event: foreground, connectivity
-- regained, sign-in. It is now the *last step of every mutation* — the
-- local-first write path is "call the RPC, pull, re-read the mirror" — and a
-- household is the densest run of those in the app. The setup ceremony spends
-- about six on its own (an epoch mismatch costs two, since the first response
-- is what reports the mismatch), and the report that follows spends one per
-- merge, per unmerge, per tag pruned, per account toggled.
--
-- A tripped limit raises, `SyncEngine.pull()` catches it into
-- `lastErrorMessage`, and the only thing that renders that is
-- `OfflineStatusBar` — which lives in `MainTabView`, underneath the setup
-- sheet and underneath the report's full-screen cover. So for the whole of
-- the one flow that can realistically trip it, the failure is invisible: the
-- RPC succeeded, the pull did not, the screen re-read a mirror from before
-- the write, and the user watched their merge do nothing.
--
-- 120 a minute is still a bound (this returns every row past a cursor, so an
-- unbounded loop is a real cost) and is four times what the busiest legitimate
-- minute in the app actually spends. Restated verbatim from
-- `pg_get_functiondef` with the one number changed.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pull_changes(p_cursor bigint DEFAULT 0, p_global_cursor bigint DEFAULT 0)
 RETURNS TABLE(payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  if not public.ops_check_own_rate_limit('pull_changes', 120, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());
  v_epoch := coalesce(v_epoch, 0);

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
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
$function$;
