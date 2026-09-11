-- Pruning a tag worked on the server and did nothing on the phone.
--
-- ============================================================================
-- The defect
-- ============================================================================
--
-- The household report's "Delete and Re-tag" calls `delete_tag_retagging`,
-- which moves every transaction off the doomed tag and then tombstones it.
-- Both halves land on the server. Neither reaches the owner's device.
--
-- `can_read_tag` admits somebody else's tag on exactly one ground: it is
-- **currently** on a live transaction of a shared account —
--
--     from public.transaction_tags tt ... where tt.tag_id = p_tag_id
--       and tt.deleted_at is null and t.deleted_at is null
--
-- — and the re-tag's whole job is to empty that set. So by the time the tag
-- row is tombstoned, the member who pressed the button can no longer see the
-- row being tombstoned. `pull_changes` is an incremental pull under RLS: it
-- sends the rows you can **see** whose `sync_seq` is past your cursor. A
-- tombstone you cannot see is not a tombstone you receive.
--
-- Observed on two devices: the server holds `Holidays` deleted and both
-- transactions wearing `Holiday`, while the report goes on listing two tags.
-- Pressing the button again does the same nothing.
--
-- This is 20260916100000's rule — **a soft delete must stay readable to
-- everyone who could read the row** — arriving at the table it was not
-- applied to. There, the fix was to stop revoking: the retired category twin
-- keeps its `shared_group_id`, so the tombstone still reaches the other
-- phone. That answer is not available here. A tag's visibility is *derived*
-- from where it is applied (20260907100000 chose that deliberately, so that
-- unsharing an account revokes its tags for free), and the delete is the act
-- of taking it off everything. There is no link left to carry the message.
--
-- So this is the other case the rule names: a change that genuinely
-- **removes** visibility, which no incremental pull can express, and which
-- `sync_epoch` exists for. Both members re-pull in full: the member who owns
-- the tag receives its tombstone as their own row, and the member who does
-- not simply never receives the row again.
--
-- ============================================================================
-- Two paths delete a tag, and both revoke
-- ============================================================================
--
--   1. `delete_tag_retagging` — the report's prune, above.
--   2. A plain `update tags set deleted_at = now()` — the Tags screen, which
--      writes the row directly through the outbox. `tags_cascade_soft_delete`
--      then tombstones the links, which revokes the *other* member's
--      visibility in exactly the same way, so their device keeps a tag that
--      no longer exists.
--
-- Both are fixed, because they are one defect: deleting a tag ends the
-- household's ability to see it. The first knows what it is about to revoke
-- only *before* it moves the links, so it captures that up front; the second
-- is the cascade itself and captures it on the way in.
-- ============================================================================

-- ============================================================================
-- 1. Which household could see this tag
--
-- The second branch of `can_read_tag`, asked the other way round: not "may I
-- read it" but "whose household is about to stop being able to". Extracted
-- rather than inlined twice — it is the subtle, security-shaped half of the
-- rule, and two copies of it would drift.
--
-- `can_read_tag` itself is deliberately left alone. It answers a different
-- question (about the caller, not about a household), it is load-bearing in
-- `tags_select`, and restating a working policy function to share four joins
-- is exactly the churn 20260911100000 charged for.
-- ============================================================================

create or replace function household_sharing_tag(p_tag_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select ha.household_id
  from public.transaction_tags tt
  join public.transactions t on t.id = tt.transaction_id
  join public.household_accounts ha on ha.account_id = t.account_id and ha.deleted_at is null
  where tt.tag_id = p_tag_id
    and tt.deleted_at is null
    and t.deleted_at is null
  limit 1;
$$;

revoke all on function household_sharing_tag(uuid) from public;

comment on function household_sharing_tag(uuid) is
  'The household whose members can currently see this tag through a shared account, or null. Ask BEFORE removing the links that grant it.';

-- ============================================================================
-- 2. The cascade bumps what it revokes
--
-- Reads before it writes: after the update there is nothing left to derive
-- the answer from, which is the whole shape of this bug.
-- ============================================================================

create or replace function cascade_tag_soft_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.household_sharing_tag(new.id);
begin
  update public.transaction_tags
  set deleted_at = new.deleted_at, updated_at = now()
  where tag_id = new.id and deleted_at is null;

  -- The links this just retired were the other member's only claim on the
  -- tag. Their device cannot be told incrementally that a row it holds has
  -- stopped existing for it, so both members re-pull.
  if v_household_id is not null then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;

  return null;
end;
$$;

revoke all on function cascade_tag_soft_delete() from public;

-- ============================================================================
-- 3. The re-tag captures visibility before it moves the links
--
-- Restated from `pg_get_functiondef` with two lines added and nothing else
-- — 20260911100000's lesson, re-earned twice since.
--
-- The capture has to happen at the top: the three statements below move every
-- live link off this tag, so asking afterwards always answers "nobody". The
-- bump then happens at the very end, after the tombstone, so the cascade
-- trigger (which now finds no live links, and therefore bumps nothing) and
-- this function cannot double-count — and a single bump is enough either way,
-- since the client compares epochs for inequality, not by how far they moved.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_tag_retagging(p_tag_id uuid, p_into_tag_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_tag public.tags;
  v_into public.tags;
  v_moved integer := 0;
  v_revoked_for uuid := public.household_sharing_tag(p_tag_id);
begin
  select * into v_tag from public.tags where id = p_tag_id and deleted_at is null;
  if v_tag.id is null then
    raise exception 'tag not found';
  end if;

  -- Your own tag needs no household at all: this is also the path the Tags
  -- screen uses to merge two of your own duplicates.
  if v_tag.owner_id <> v_me then
    if v_household_id is null then
      raise exception 'tag not found';
    end if;
    if public.household_owner_id(v_household_id) <> v_me then
      raise exception 'only the household owner can delete another member''s tag';
    end if;
    if not exists (
      select 1 from public.household_members
      where household_id = v_household_id and user_id = v_tag.owner_id and deleted_at is null
    ) then
      raise exception 'tag not found';
    end if;
  end if;

  if p_into_tag_id is not null then
    if p_into_tag_id = p_tag_id then
      raise exception 'a tag cannot be re-tagged into itself';
    end if;

    select * into v_into from public.tags where id = p_into_tag_id and deleted_at is null;
    if v_into.id is null then
      raise exception 'destination tag not found';
    end if;

    -- The destination has to be usable by whoever owns the transactions being
    -- moved. `transaction_tags.owner_id` comes from the transaction, and
    -- `transaction_tags_insert` demands `can_read_tag(tag_id)` — a
    -- destination the transaction's owner cannot read would produce rows the
    -- app can never show them again.
    if v_into.owner_id <> v_tag.owner_id and not exists (
      select 1
      from public.household_members mine
      join public.household_members theirs on theirs.household_id = mine.household_id
      where mine.user_id = v_tag.owner_id and mine.deleted_at is null
        and theirs.user_id = v_into.owner_id and theirs.deleted_at is null
    ) then
      raise exception 'destination tag belongs to neither member of this household';
    end if;

    -- `transaction_tags`' primary key is `(transaction_id, tag_id)`, and its
    -- rows are **soft**-deleted like everything else here — so a transaction
    -- that once wore the destination tag and had it removed still holds a
    -- tombstone on exactly the key a move would land on. Updating into it
    -- raises a unique violation; hard-deleting the tombstone would strand
    -- the other device, which pulls tombstones as ordinary rows.
    --
    -- Reviving it is the move, for those transactions. Three statements, in
    -- this order: revive what would collide, retire the sources that are now
    -- redundant, then move whatever is left onto a free key.
    with revived as (
      update public.transaction_tags dest
      set deleted_at = null
      where dest.tag_id = p_into_tag_id
        and dest.deleted_at is not null
        and exists (
          select 1 from public.transaction_tags src
          where src.transaction_id = dest.transaction_id
            and src.tag_id = p_tag_id
            and src.deleted_at is null
        )
      returning 1
    )
    select count(*) into v_moved from revived;

    update public.transaction_tags tt
    set deleted_at = now()
    where tt.tag_id = p_tag_id and tt.deleted_at is null
      and exists (
        select 1 from public.transaction_tags other
        where other.transaction_id = tt.transaction_id
          and other.tag_id = p_into_tag_id
          and other.deleted_at is null
      );

    with moved as (
      update public.transaction_tags
      set tag_id = p_into_tag_id
      where tag_id = p_tag_id and deleted_at is null
      returning 1
    )
    select v_moved + count(*) into v_moved from moved;
  end if;

  -- Last, so `cascade_tag_soft_delete` finds only the links that genuinely
  -- had nowhere to go.
  update public.tags set deleted_at = now() where id = p_tag_id;

  -- The tag has stopped being visible to whoever was seeing it through a
  -- shared account — including, on the report's own path, the member who
  -- pressed the button. An incremental pull cannot deliver "a row you hold
  -- is no longer yours to see", so both members re-pull in full.
  if v_revoked_for is not null then
    perform public.bump_household_sync_epochs(v_revoked_for);
  end if;

  return v_moved;
end;
$function$;

revoke all on function delete_tag_retagging(uuid, uuid) from public;
grant execute on function delete_tag_retagging(uuid, uuid) to authenticated, service_role;

comment on function delete_tag_retagging(uuid, uuid) is
  'Soft-deletes a tag, first moving every transaction wearing it onto p_into_tag_id when one is given. Bumps both household epochs when the delete revokes a member''s visibility.';
