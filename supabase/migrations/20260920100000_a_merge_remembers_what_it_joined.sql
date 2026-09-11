-- A merge overwrote the two things it was made of.
--
-- ============================================================================
-- What the report could not show
-- ============================================================================
--
-- `apply_category_merges` writes the resultant name, icon and colour onto
-- **both** rows, so a merged pair is two rows that agree about everything.
-- Open one in the report and the "Shared by You" and "Shared with You" tiles
-- are identical — which is true, and useless. The owner is looking at the
-- screen that decides whether two people's years of records were about the
-- same thing, and by the time they get there `Dining Out` no longer exists
-- anywhere to be compared against `Dine Out`.
--
-- 20260913100000 chose this deliberately: "each side keeps whatever the
-- merged identity last said, because the alternative is restoring a name from
-- before the merge that this schema deliberately does not keep a copy of."
-- That is the decision being reversed. Keeping the copy is what lets the
-- report answer both of the questions the owner actually has — *what were
-- these two?* and *what will they become?* — and it is the only thing that
-- can make Unmerge mean undo.
--
-- Three nullable columns rather than a side table: this is one row's own
-- previous identity, it is written and read with the row, and a join table
-- keyed by category id would be the same three values with a foreign key in
-- front of them.
--
-- ============================================================================
-- Unmerging is an undo now, not a release
-- ============================================================================
--
-- It used to set `shared_group_id = null` on both rows, which left two
-- private categories wearing the merged name — the pair vanished from the
-- report entirely, and neither row was what it had been. Now each row is put
-- back the way the merge found it: its own identity, its own shared group,
-- and the other member's twin re-minted, which is exactly the shape the
-- report draws under **Extra**.
--
-- **Except when the two originals were already called the same thing.** An
-- exact-name automatic merge (`ensure_category_twin`'s second branch) joins
-- two rows that were never twinned to begin with — before it, both were
-- private. Re-sharing those would hand each member a second category by the
-- same name, or worse, walk straight back into `ensure_category_twin` and
-- re-merge the pair the user just separated. So that case goes back to
-- private, which is genuinely where it came from.
-- ============================================================================

alter table categories
  add column pre_merge_name text,
  add column pre_merge_icon text,
  add column pre_merge_color text;

comment on column categories.pre_merge_name is
  'This row''s own name before a merge overwrote it. Null when the row is not the product of one.';

-- ============================================================================
-- 1. Capturing an identity, once
--
-- `coalesce`d so a second merge over an already-merged row keeps the *first*
-- capture: what the user wants back is the category they started with, not
-- the intermediate name a previous merge happened to write. Cleared on
-- unmerge, so the next merge captures afresh.
-- ============================================================================

create or replace function capture_pre_merge_identity(p_category_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.categories
  set pre_merge_name = coalesce(pre_merge_name, name),
      pre_merge_icon = coalesce(pre_merge_icon, icon),
      pre_merge_color = coalesce(pre_merge_color, color)
  where id = any (p_category_ids);
$$;

revoke all on function capture_pre_merge_identity(uuid[]) from public;

-- ============================================================================
-- 2. The two places a merge happens
--
-- Both restated from `pg_get_functiondef` with the capture added and nothing
-- else — 20260911100000's lesson.
--
-- `ensure_category_twin`'s exact-name branch counts: the names match by
-- definition there, but the icons and colours usually do not, and the row
-- that loses its colour to `propagate_shared_category_edit` deserves to get
-- it back.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.ensure_category_twin(p_category_id uuid, p_other_member uuid, p_group_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_source record;
  v_twin_id uuid;
begin
  select * into v_source from public.categories where id = p_category_id and deleted_at is null;
  if v_source.id is null then
    return;
  end if;

  select id into v_twin_id from public.categories
  where owner_id = p_other_member and kind = v_source.kind and deleted_at is null
    and lower(btrim(name)) = lower(btrim(v_source.name))
  limit 1;

  if v_twin_id is null then
    -- `is_default` is never copied: each member has exactly one default per
    -- kind of their own, and `categories_one_default_per_kind` would refuse a
    -- second one anyway. `merge_origin` stays null — nothing was merged, the
    -- other member simply now has this category too.
    insert into public.categories (owner_id, kind, name, icon, color, shared_group_id)
    values (p_other_member, v_source.kind, v_source.name, v_source.icon, v_source.color, p_group_id);
    update public.categories set shared_group_id = p_group_id where id = p_category_id;
  else
    -- Both members already had it under the same name. That is a merge, and
    -- it happened without anybody being asked.
    perform public.capture_pre_merge_identity(array[v_twin_id, p_category_id]);
    update public.categories set shared_group_id = p_group_id, merge_origin = 'automatic'
    where id in (v_twin_id, p_category_id);
  end if;
end;
$function$;

revoke all on function ensure_category_twin(uuid, uuid, uuid) from public;

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

    -- What each row was, before this statement takes its name away. It is
    -- the only copy — the report shows the owner what they are joining, and
    -- Unmerge puts it back.
    perform public.capture_pre_merge_identity(array[v_mine.id, v_theirs.id]);

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
    -- see 20260916100000's header. Nothing reads a deleted category on either
    -- side, so the retired link costs nothing and carries the message.
    update public.categories c
    set deleted_at = now(), merge_origin = null
    where c.shared_group_id is not null
      and c.shared_group_id in (v_mine.shared_group_id, v_theirs.shared_group_id)
      and c.id not in (v_mine.id, v_theirs.id)
      and c.deleted_at is null
      and c.merge_origin is null
      and not exists (
        select 1 from public.transactions t where t.category_id = c.id and t.deleted_at is null
      )
      and not exists (
        select 1 from public.recurring_rules r where r.category_id = c.id
      )
      and not exists (
        select 1 from public.merchant_category_map m where m.category_id = c.id
      );

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

    update public.categories
    set shared_group_id = v_group_id, name = v_name, icon = v_icon, color = v_color,
        merge_origin = case when p_automatic then 'automatic'::public.category_merge_origin
                            else 'manual'::public.category_merge_origin end
    where id in (v_mine.id, v_theirs.id);

    v_applied := v_applied + 1;
  end loop;

  if v_released > 0 then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;

  return v_applied;
end;
$function$;

revoke all on function apply_category_merges(jsonb, boolean) from public;
grant execute on function apply_category_merges(jsonb, boolean) to authenticated, service_role;

-- ============================================================================
-- 3. Unmerge, as undo
--
-- Four statements, in this order, and the order is the whole correctness
-- argument:
--
--   1. Remember which rows are in the group, because step 2 destroys the only
--      way to find them.
--   2. Release the group **before** touching any name.
--      `propagate_shared_category_edit` fires on any update of name, icon or
--      colour and copies the new value onto every sibling still sharing the
--      group — so restoring one row's name while the link was still there
--      would overwrite the other row's with it, destroying the second value
--      in the act of restoring the first. With the link already gone the
--      trigger returns on its first line.
--   3. Restore each row's own identity and drop the capture.
--   4. Put each original back into a shared group of its own, which is the
--      shape the report draws under Extra.
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
  v_ids uuid[];
  v_id uuid;
  v_owner uuid;
  v_distinct_names integer;
begin
  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  if public.household_owner_id(v_household_id) <> v_me then
    raise exception 'only the household owner can unmerge categories';
  end if;

  select array_agg(c.id) into v_ids
  from public.categories c
  join public.household_members m
    on m.user_id = c.owner_id and m.household_id = v_household_id and m.deleted_at is null
  where c.shared_group_id = p_group_id and c.deleted_at is null;

  if v_ids is null then
    raise exception 'no such shared category in your household';
  end if;

  update public.categories set shared_group_id = null, merge_origin = null
  where shared_group_id = p_group_id;

  update public.categories
  set name = coalesce(pre_merge_name, name),
      icon = coalesce(pre_merge_icon, icon),
      color = coalesce(pre_merge_color, color),
      pre_merge_name = null, pre_merge_icon = null, pre_merge_color = null
  where id = any (v_ids);

  -- Two rows that were always called the same thing were never twinned in
  -- the first place — `ensure_category_twin` joined two categories that each
  -- member already had, and before that both were private. Re-sharing them
  -- would either hand each member a second category by that name or walk
  -- straight back into the exact-name branch and re-merge the pair the user
  -- just separated. Private is where they came from.
  select count(distinct lower(btrim(name))) into v_distinct_names
  from public.categories where id = any (v_ids);

  if v_distinct_names > 1 then
    foreach v_id in array v_ids loop
      select owner_id into v_owner from public.categories where id = v_id;
      perform public.ensure_category_twin(
        v_id,
        (select hm.user_id from public.household_members hm
         where hm.household_id = v_household_id and hm.user_id <> v_owner
           and hm.deleted_at is null limit 1),
        gen_random_uuid()
      );
    end loop;
  end if;

  -- A row leaving a shared group is a revocation whichever way it goes, and
  -- an incremental pull cannot express one (20260916100000).
  perform public.bump_household_sync_epochs(v_household_id);
end;
$$;

revoke all on function unmerge_category_group(uuid) from public;
grant execute on function unmerge_category_group(uuid) to authenticated, service_role;

-- ============================================================================
-- 4. A capture never outlives the link it belongs to
--
-- Both of these end a share outright. They **clear** the capture rather than
-- restoring from it: unsharing is "stop showing this to the other member",
-- and silently renaming somebody's category as a side effect of a toggle
-- would be a worse surprise than losing the ability to undo a merge that is
-- being dissolved anyway. What must not happen is the capture surviving,
-- where a later, unrelated merge-and-unmerge of the same row would restore a
-- name from two links ago.
--
-- Restated from `pg_get_functiondef` with the one column list widened.
-- ============================================================================

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

  update public.categories
  set shared_group_id = null, merge_origin = null,
      pre_merge_name = null, pre_merge_icon = null, pre_merge_color = null
  where shared_group_id = v_source.shared_group_id;

  if v_household_id is not null then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;
end;
$$;

revoke all on function unshare_category(uuid) from public;
grant execute on function unshare_category(uuid) to authenticated, service_role;

create or replace function unlink_shared_categories(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.categories
  set shared_group_id = null, merge_origin = null,
      pre_merge_name = null, pre_merge_icon = null, pre_merge_color = null
  where shared_group_id in (
    select shared_group_id from public.categories
    where owner_id = p_user_id and shared_group_id is not null
  );
$$;

revoke all on function unlink_shared_categories(uuid) from public;
