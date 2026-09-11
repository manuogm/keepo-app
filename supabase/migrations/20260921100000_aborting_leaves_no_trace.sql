-- Backing out of a household left both members holding copies of each
-- other's accounts.
--
-- ============================================================================
-- The defect
-- ============================================================================
--
-- `HouseholdSetupCoordinator.abort()` undid the setup by calling
-- `leave_household()`, which is the wrong verb. Leaving **dissolves** a
-- household that has existed: `fork_household_accounts` gives each member a
-- private copy of everything that was shared, so neither of them loses the
-- ledger they have been keeping together. That is exactly right for two
-- people who have shared their money and are separating, and exactly wrong
-- for two people who pressed Stop thirty seconds after starting.
--
-- Observed across a few test cycles: each build-and-abort left both phones
-- with another "Checking" and another "Bob Current", until the picker listed
-- four accounts that were two.
--
-- **An abort is not a dissolution. It is an undo.** Nothing was shared long
-- enough to be worth forking, and the household is not real until the owner
-- accepts the report — before that, both members are entitled to exactly the
-- picture they had before they started.
--
-- ============================================================================
-- What the setup actually creates, and how each part comes back
-- ============================================================================
--
--   * `households` + two `household_members` — retired, the way leaving
--     retires them. Not hard-deleted: the memberships are what the sync layer
--     and `household_members_raise_sync_domain` both key on, and a `DELETE`
--     fires neither.
--   * `household_accounts` — retired. The household never owned an account,
--     it listed one, and dropping the listing is the whole undo. **No fork.**
--   * Categories the sharing step *linked* — `shared_group_id`,
--     `merge_origin`, and whatever a merge wrote over their name, icon and
--     colour. All restorable, because 20260920100000 started keeping the
--     copy.
--   * Categories the sharing step *minted* — `ensure_category_twin` inserts
--     the other member's row when they had no match by that name. Those rows
--     exist only because of this household and have to go with it.
--
-- That last one is why this migration adds a column. `apply_category_merges`
-- already needs to tell a minted twin from a real category and does it by
-- proxy — no transactions, no recurring rule, no merchant mapping — which is
-- sound for a twin minted seconds earlier and **not** sound here: a category
-- its owner made and never used answers the same way, and deleting one on
-- that basis would be losing something the user created. So it is recorded at
-- the moment it is known, for the same reason `merge_origin` is.
-- ============================================================================

alter table categories
  add column created_as_twin boolean not null default false;

comment on column categories.created_as_twin is
  'This row exists because a household shared a category its owner did not have. Cleared when the household ends for real; the row is theirs from then on.';

-- ============================================================================
-- 1. The twin says so
--
-- Restated from `pg_get_functiondef` with one column added to the insert.
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
    insert into public.categories (
      owner_id, kind, name, icon, color, shared_group_id, created_as_twin
    )
    values (
      p_other_member, v_source.kind, v_source.name, v_source.icon, v_source.color,
      p_group_id, true
    );
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

-- A household that ends for real — one member leaving, an account erased —
-- forks everything and both people keep what they had. A twin is their own
-- category from that moment, and must not be swept up by a later discard.
create or replace function unlink_shared_categories(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.categories
  set shared_group_id = null, merge_origin = null,
      pre_merge_name = null, pre_merge_icon = null, pre_merge_color = null,
      created_as_twin = false
  where shared_group_id in (
    select shared_group_id from public.categories
    where owner_id = p_user_id and shared_group_id is not null
  );
$$;

revoke all on function unlink_shared_categories(uuid) from public;

-- ============================================================================
-- 2. Discarding, as the opposite of creating
--
-- Deliberately not owner-only. Either member may back out of a household
-- neither of them has agreed to yet, and the setup screens offer the same
-- button on both phones.
--
-- Silent when there is nothing to discard: an abort races the other phone's,
-- and the second one to arrive finding no household is the outcome being
-- asked for, not a failure to report.
-- ============================================================================

create or replace function discard_household()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_members uuid[];
begin
  if v_household_id is null then
    return;
  end if;

  select array_agg(user_id) into v_members
  from public.household_members
  where household_id = v_household_id and deleted_at is null;

  -- The listing, not the account. Nothing is copied and nothing is forked;
  -- each member's accounts are already theirs and stay exactly as they were.
  update public.household_accounts set deleted_at = now()
  where household_id = v_household_id and deleted_at is null;

  -- One statement, and it has to be one statement:
  -- `propagate_shared_category_edit` fires on any update of name, icon or
  -- colour and copies the value onto every sibling still sharing the group.
  -- Clearing `shared_group_id` in the same UPDATE means the trigger sees a
  -- null group on the new row and returns on its first line, so each row gets
  -- its own identity back instead of the last one written.
  --
  -- Tombstoned rows are included on purpose: a merge retires the twins it
  -- makes redundant, and those are rows this household invented too.
  update public.categories
  set name = coalesce(pre_merge_name, name),
      icon = coalesce(pre_merge_icon, icon),
      color = coalesce(pre_merge_color, color),
      shared_group_id = null, merge_origin = null,
      pre_merge_name = null, pre_merge_icon = null, pre_merge_color = null
  where owner_id = any (v_members) and shared_group_id is not null;

  -- Hard, not soft. A tombstone is a message to the other device, and there
  -- is no message to send: the epoch bump below makes both of them wipe and
  -- re-pull, after which a row that was never really theirs simply is not
  -- there. The three guards are the same ones `apply_category_merges` uses —
  -- a twin somebody managed to file against in the last minute is a category
  -- now, and keeping it costs one stray row against losing a transaction.
  delete from public.categories c
  where c.owner_id = any (v_members)
    and c.created_as_twin
    and not exists (select 1 from public.transactions t where t.category_id = c.id)
    and not exists (select 1 from public.recurring_rules r where r.category_id = c.id)
    and not exists (select 1 from public.merchant_category_map m where m.category_id = c.id);

  update public.categories set created_as_twin = false
  where owner_id = any (v_members) and created_as_twin;

  -- Retired rather than deleted, which is also what lifts each member back
  -- onto a ticket sequence ahead of their own cursor —
  -- `household_members_raise_sync_domain` fires on this update and on no
  -- DELETE (20260919100000).
  update public.household_members set deleted_at = now()
  where household_id = v_household_id and deleted_at is null;

  update public.household_invites set status = 'revoked'
  where household_id = v_household_id and status = 'pending';

  -- Everything above either removes a row or removes somebody's right to see
  -- one, and an incremental pull can deliver neither. Both devices start over.
  update public.profiles set sync_epoch = sync_epoch + 1 where id = any (v_members);
end;
$$;

revoke all on function discard_household() from public;
grant execute on function discard_household() to authenticated, service_role;

comment on function discard_household() is
  'Undoes a household that was never agreed to: no fork, no copies, both members exactly as they were. Either member may call it.';
