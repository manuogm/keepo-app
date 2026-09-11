-- The one thing an abort could not put back.
--
-- ============================================================================
-- The gap
-- ============================================================================
--
-- `20260921100000` made backing out of a household an undo: no forks, no
-- copies, every category restored to its own name, icon and colour. One thing
-- was left behind — a tag the owner pruned in the report.
--
-- `delete_tag_retagging` moves every `transaction_tags` row off the doomed tag
-- and onto the destination, and records nothing about which rows moved. After
-- the fact the destination tag simply has more transactions than it did, and
-- nothing on the server can say which of them arrived that way. So an abort
-- gave both members back their accounts and their categories and left one
-- tag deleted and somebody's history wearing a label they did not choose.
--
-- ============================================================================
-- Where the record goes, and why not on the row
-- ============================================================================
--
-- The obvious place is two columns on `transaction_tags` — the tag it wore
-- before and the `deleted_at` it had. It is the wrong place. That table is in
-- `pull_changes` and in `SyncApply`'s whitelist, so every column on it is
-- carried to every device on every sync, needs a local-schema rebuild to
-- land, and is paid for forever — to support an undo that is reachable for
-- the few minutes between joining a household and accepting the report.
--
-- A side table nobody syncs costs the client nothing: no codegen, no local
-- column, no payload. It is server-side bookkeeping for a server-side undo,
-- which is exactly what it is.
--
-- Two tables rather than one, because two different things are recorded and
-- folding them into one shape means a nullable `transaction_id` that means
-- "actually this row is about the tag itself":
--
--   * `household_pruned_tags` — this household retired this tag.
--   * `household_retagged_links` — and these links moved as part of it,
--     each with the state it is to be put back to.
--
-- The link log is keyed by the row's state **after** the move, because that
-- is what the undo has to find. It is replayed newest-first: a link pruned
-- twice in one session (X → Y, then Y → Z) only reaches X again if Z → Y is
-- undone before Y → X.
-- ============================================================================

create table household_pruned_tags (
  id bigserial primary key,
  household_id uuid not null references households(id) on delete cascade,
  tag_id uuid not null,
  pruned_at timestamptz not null default now()
);

create index household_pruned_tags_household_idx on household_pruned_tags (household_id);

create table household_retagged_links (
  id bigserial primary key,
  prune_id bigint not null references household_pruned_tags(id) on delete cascade,
  transaction_id uuid not null,
  -- The tag the row wears now — with `transaction_id`, the key the undo
  -- looks it up by.
  tag_id uuid not null,
  prev_tag_id uuid not null,
  prev_deleted_at timestamptz
);

create index household_retagged_links_prune_idx on household_retagged_links (prune_id);

-- Internal bookkeeping, never read by a client and never pulled. No policies,
-- same posture as `sync_tickets` and `ops_rate_limits`; the only writers are
-- the SECURITY DEFINER bodies below.
alter table household_pruned_tags enable row level security;
alter table household_retagged_links enable row level security;

comment on table household_pruned_tags is
  'Tags a household retired before it was accepted, so discarding it can bring them back.';
comment on table household_retagged_links is
  'Every transaction_tags row a prune touched, with the state to restore it to. Replayed newest-first.';

-- ============================================================================
-- 1. The prune writes down what it did
--
-- Restated from `pg_get_functiondef`. Each of the three statements now
-- captures the rows it is about to change **before** changing them — `UPDATE
-- … RETURNING` hands back the new row, and what the undo needs is the old
-- one. Logging is skipped entirely outside a household: this is also the path
-- the Tags screen uses on a user's own duplicates, and that is not part of
-- any setup to undo.
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
  v_prune_id bigint;
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

  if v_household_id is not null then
    insert into public.household_pruned_tags (household_id, tag_id)
    values (v_household_id, p_tag_id)
    returning id into v_prune_id;
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
    with targets as (
      select dest.transaction_id, dest.tag_id, dest.deleted_at as prev_deleted_at
      from public.transaction_tags dest
      where dest.tag_id = p_into_tag_id
        and dest.deleted_at is not null
        and exists (
          select 1 from public.transaction_tags src
          where src.transaction_id = dest.transaction_id
            and src.tag_id = p_tag_id
            and src.deleted_at is null
        )
    ), logged as (
      insert into public.household_retagged_links
        (prune_id, transaction_id, tag_id, prev_tag_id, prev_deleted_at)
      select v_prune_id, t.transaction_id, t.tag_id, t.tag_id, t.prev_deleted_at
      from targets t where v_prune_id is not null
      returning 1
    ), revived as (
      update public.transaction_tags dest
      set deleted_at = null
      from targets t
      where dest.transaction_id = t.transaction_id and dest.tag_id = t.tag_id
      returning 1
    )
    select count(*) into v_moved from revived;

    with targets as (
      select tt.transaction_id, tt.tag_id
      from public.transaction_tags tt
      where tt.tag_id = p_tag_id and tt.deleted_at is null
        and exists (
          select 1 from public.transaction_tags other
          where other.transaction_id = tt.transaction_id
            and other.tag_id = p_into_tag_id
            and other.deleted_at is null
        )
    ), logged as (
      insert into public.household_retagged_links
        (prune_id, transaction_id, tag_id, prev_tag_id, prev_deleted_at)
      select v_prune_id, t.transaction_id, t.tag_id, t.tag_id, null
      from targets t where v_prune_id is not null
      returning 1
    )
    update public.transaction_tags tt
    set deleted_at = now()
    from targets t
    where tt.transaction_id = t.transaction_id and tt.tag_id = t.tag_id;

    -- Logged against the key the row is about to have, which is what the undo
    -- looks it up by.
    with targets as (
      select tt.transaction_id from public.transaction_tags tt
      where tt.tag_id = p_tag_id and tt.deleted_at is null
    ), logged as (
      insert into public.household_retagged_links
        (prune_id, transaction_id, tag_id, prev_tag_id, prev_deleted_at)
      select v_prune_id, t.transaction_id, p_into_tag_id, p_tag_id, null
      from targets t where v_prune_id is not null
      returning 1
    ), moved as (
      update public.transaction_tags tt
      set tag_id = p_into_tag_id
      from targets t
      where tt.transaction_id = t.transaction_id and tt.tag_id = p_tag_id
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

-- ============================================================================
-- 2. Accepting the report is what makes a prune permanent
--
-- Until Finish the household is setup nobody has agreed to, and the log is
-- what lets that be taken back. After it there is nothing to undo, and a log
-- left lying about would let some *later* household's abort revert a prune
-- that has been part of this one's history for months.
-- ============================================================================

create or replace function finalize_household()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
begin
  if v_household_id is null then
    return;
  end if;

  -- The links cascade with it.
  delete from public.household_pruned_tags where household_id = v_household_id;
end;
$$;

revoke all on function finalize_household() from public;
grant execute on function finalize_household() to authenticated, service_role;

comment on function finalize_household() is
  'Called when the owner accepts the report. Drops the undo log — from here the household is real.';

-- ============================================================================
-- 3. Discarding replays the log
--
-- Restated from `pg_get_functiondef` with the tag half added in front of the
-- rest, and the order is load-bearing:
--
--   1. **Tags first.** `set_transaction_tag_derived_columns` fires before
--      every `transaction_tags` update and, for a row being revived, looks the
--      tag up with `deleted_at is null`. Putting a link back before its tag
--      exists again raises "tag not found" from a trigger.
--   2. **Links newest-first.** A link pruned twice in one session (X → Y, then
--      Y → Z) only reaches X again if Z → Y is undone before Y → X.
--   3. Then the accounts, the categories and the memberships, unchanged.
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
  v_link record;
begin
  if v_household_id is null then
    return;
  end if;

  select array_agg(user_id) into v_members
  from public.household_members
  where household_id = v_household_id and deleted_at is null;

  update public.tags t
  set deleted_at = null
  where t.deleted_at is not null
    and exists (
      select 1 from public.household_pruned_tags p
      where p.household_id = v_household_id and p.tag_id = t.id
    );

  for v_link in
    select l.transaction_id, l.tag_id, l.prev_tag_id, l.prev_deleted_at
    from public.household_retagged_links l
    join public.household_pruned_tags p on p.id = l.prune_id
    where p.household_id = v_household_id
    order by l.id desc
  loop
    update public.transaction_tags
    set tag_id = v_link.prev_tag_id, deleted_at = v_link.prev_deleted_at
    where transaction_id = v_link.transaction_id and tag_id = v_link.tag_id;
  end loop;

  delete from public.household_pruned_tags where household_id = v_household_id;

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
  -- there.
  delete from public.categories c
  where c.owner_id = any (v_members)
    and c.created_as_twin
    and not exists (select 1 from public.transactions t where t.category_id = c.id)
    and not exists (select 1 from public.recurring_rules r where r.category_id = c.id)
    and not exists (select 1 from public.merchant_category_map m where m.category_id = c.id);

  update public.categories set created_as_twin = false
  where owner_id = any (v_members) and created_as_twin;

  update public.household_members set deleted_at = now()
  where household_id = v_household_id and deleted_at is null;

  update public.household_invites set status = 'revoked'
  where household_id = v_household_id and status = 'pending';

  update public.profiles set sync_epoch = sync_epoch + 1 where id = any (v_members);
end;
$$;

revoke all on function discard_household() from public;
grant execute on function discard_household() to authenticated, service_role;
