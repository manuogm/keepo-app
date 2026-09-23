-- A sharing link is not the client's to write.
--
-- Found by the security audit of 2026-09-21, and confirmed with a working
-- exploit before this was written.
--
-- `categories.shared_group_id` is how two household members' copies of one
-- category are tied together. Everything that acts on a shared category —
-- the propagation trigger, `unshare_category` — finds its peers with
-- `where shared_group_id = <this row's>`, and *nothing* checked that those
-- peers were in the caller's household. That was safe only for as long as
-- the group id was a server-controlled fact. It was not: `authenticated`
-- held a table-wide UPDATE on `categories`, so the client could write the
-- column to any value it liked, and the group id became attacker-chosen.
--
-- Two exploits followed from that one gap, both demonstrated against a
-- victim in no household at all, by an attacker who could not so much as
-- *read* the target row (`can_read_category` returned false):
--
--   1. Point your own category at the victim's group, rename it, and the
--      AFTER UPDATE trigger rewrites the victim's name, icon and colour.
--   2. Point your own category at the victim's group, call the perfectly
--      legitimate `unshare_category` on *your* row, and the victim's
--      sharing link is severed along with it.
--
-- The fix is in two layers, deliberately.
--
-- **The grant is the root cause**, so it goes first: the client only ever
-- sends `{name, icon, color}` or `{deleted_at}` for a category and `{name}`
-- or `{deleted_at}` for a tag (`CategoryWrites.swift`, `TagWrites.swift`),
-- so a column-scoped UPDATE costs the client nothing and takes the group id
-- — along with `is_default`, `merge_origin`, the `pre_merge_*` provenance
-- columns, `owner_id`, `id` and `sync_seq` — out of its reach entirely.
-- This is the same shape `profiles` has had since 20260910100000.
--
-- **The two readers are hardened anyway**, because a grant is one migration
-- away from being widened again by someone who does not know it is load
-- bearing, and because "this UPDATE trusts a column the client can write"
-- should not be a property that has to be remembered. Scoping them to the
-- owner's own household makes them correct regardless of who can write the
-- column.
--
-- Tags get the same column-scoped treatment in the same breath. No exploit
-- there today — `tags` has no group column — but it carried the identical
-- table-wide grant over `owner_id`, `id`, `version` and `sync_seq`, and the
-- reason it was not exploitable was luck of schema rather than design.

-- ---------------------------------------------------------------------------
-- 1. The grants. `REVOKE` then re-`GRANT` per column: Postgres has no
--    "narrow this grant" verb, and a column-level GRANT does not displace a
--    table-level one already held.
-- ---------------------------------------------------------------------------

revoke update on public.categories from authenticated;
grant update (name, icon, color, deleted_at) on public.categories to authenticated;

revoke update on public.tags from authenticated;
grant update (name, deleted_at) on public.tags to authenticated;

-- The BEFORE UPDATE triggers on both tables (`bump_version`, `set_updated_at`,
-- `stamp_sync_seq_owner`) still write `version`, `updated_at` and `sync_seq`
-- on NEW. That is unaffected by the revoke: Postgres checks column privileges
-- against the columns named in the statement's SET clause, never against what
-- a trigger assigns afterwards.

-- ---------------------------------------------------------------------------
-- 2. The propagation trigger, scoped to the household.
-- ---------------------------------------------------------------------------

create or replace function public.propagate_shared_category_edit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.shared_group_id is null then
    return null;
  end if;

  update public.categories
  set name = new.name, icon = new.icon, color = new.color
  where shared_group_id = new.shared_group_id
    and id <> new.id
    and deleted_at is null
    -- Added 20261001100000. A shared group only ever spans the members of
    -- one household, so say so here rather than inferring it from a column
    -- the client used to be able to write. An owner with no membership row
    -- shares with nobody and this matches nothing, which is correct.
    and owner_id in (
      select theirs.user_id
      from public.household_members mine
      join public.household_members theirs on theirs.household_id = mine.household_id
      where mine.user_id = new.owner_id
        and mine.deleted_at is null
        and theirs.deleted_at is null
    )
    and (name is distinct from new.name or icon is distinct from new.icon or color is distinct from new.color);

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. `unshare_category`, scoped the same way.
-- ---------------------------------------------------------------------------

create or replace function public.unshare_category(p_category_id uuid)
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
  where shared_group_id = v_source.shared_group_id
    -- Added 20261001100000, for the reason the trigger above carries. The
    -- union keeps the caller's own row in scope even when they are in no
    -- household — a leftover group id from a household they have since left
    -- is exactly the case where unsharing must still work.
    and owner_id in (
      select hm.user_id
      from public.household_members hm
      where hm.household_id = v_household_id and hm.deleted_at is null
      union
      select v_source.owner_id
    );

  if v_household_id is not null then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;
end;
$$;
