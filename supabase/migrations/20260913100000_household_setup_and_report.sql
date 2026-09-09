-- Household setup as a two-phone ceremony, and the owner's report that ends
-- it.
--
-- The invite machinery from 20260912100000 stays exactly as it is: the token
-- is still minted by `create_invite`, still carries both members' selections,
-- and `accept_invite` still applies them in one transaction. What changes is
-- what happens *around* it — the token now travels over a peer-to-peer link
-- between two phones held next to each other rather than being copied into a
-- text message, and the moment it lands the household owner is handed a
-- report over everything the two of them just pooled.
--
-- Nothing about the ledger moves peer-to-peer. The phones exchange a display
-- name, a face and a one-time token; every account, category and tag still
-- crosses through `accept_invite` under RLS. A design where one phone hands
-- another its balances directly would put money outside every guarantee this
-- schema makes about who may read what, and the guarantee is the product.
--
-- Five things live here:
--
--   1. The `my_household_id()` fix — a live bug, found while building this.
--   2. `household_owner_id()` — who has setup authority, as a fact rather
--      than an assumption at each call site.
--   3. `household_member_profile()` — the other member, as much of them as
--      the Household screen is entitled to show and no more.
--   4. `apply_category_merges()` / `unmerge_category_group()` — the report's
--      one real power: deciding that your category and theirs are the same
--      category.
--   5. `delete_tag_retagging()` — deleting a redundant tag without dropping
--      the transactions that were wearing it on the floor.

-- ============================================================================
-- 1. Leaving a household has to actually let go of it
--
-- `leave_household()` and `erase_own_account()` were changed in
-- 20260912100000 to **soft**-delete the caller's `household_members` row
-- (`set deleted_at = now()`), because the sync layer needs a tombstone to
-- push — a hard DELETE never reaches the other device. But
-- `my_household_id()` has read the table without a `deleted_at` filter since
-- 20260806090000, when the column did not exist.
--
-- So the row that says "you left" still answers "you are a member". After
-- leaving, `create_household()` refuses with "you already belong to a
-- household", `accept_invite()` refuses with "already a member of a
-- household", and `households_select` keeps returning the household the user
-- just walked out of. The user is trapped, permanently, with no way back to
-- a blank state and no error that names the cause.
--
-- Every other reader of this table already filters (`share_category`,
-- `accept_invite`, `leave_household` itself, `sync_domain_id`). This one was
-- simply missed when the column arrived, and it is the one the other twenty
-- call sites are built on top of.
--
-- `limit 1` stays: a user is in at most one household, and the guard is the
-- 2-member cap plus this function's own use in `create_household`.
-- ============================================================================

create or replace function my_household_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select household_id from public.household_members
  where user_id = (select auth.uid()) and deleted_at is null
  limit 1;
$$;

revoke all on function my_household_id() from public;
grant execute on function my_household_id() to authenticated, service_role;

-- ============================================================================
-- 2. Who owns the household
--
-- The member who created it: `create_household()` inserts the creator's row,
-- and `accept_invite()` inserts the second one in a later transaction, so
-- "earliest `joined_at`" is the creator by construction and the two can never
-- tie in production. `user_id` is the tiebreak anyway, so the answer is
-- deterministic even inside a single test transaction, where `now()` is
-- frozen and both rows genuinely do tie (see `_helpers.psql`, gotcha 5).
--
-- Derived rather than stored as `households.created_by`. Storing it would be
-- a second source of truth that has to be kept honest through leave, fork and
-- erase — and the behaviour everybody wants when the owner leaves is that the
-- remaining member becomes the owner of their now single-member household,
-- which falls out of this for free and would need explicit fixing up in a
-- column.
--
-- Owner authority is **setup authority only**: merging categories, naming the
-- result, pruning redundant tags. It is not authority over money. Both
-- members read and write every shared account exactly as they did before —
-- `can_write_account` is unchanged and is still the only thing that decides.
-- ============================================================================

create or replace function household_owner_id(p_household_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select user_id from public.household_members
  where household_id = p_household_id and deleted_at is null
  order by joined_at, user_id
  limit 1;
$$;

revoke all on function household_owner_id(uuid) from public;
grant execute on function household_owner_id(uuid) to authenticated, service_role;

comment on function household_owner_id(uuid) is
  'The member who created the household — setup authority, never money authority.';

-- ============================================================================
-- 3. The other member, in the amount the Household screen may show
--
-- `profiles_select` is `id = auth.uid()` and stays that way. Widening it so
-- the Household screen can draw a name would hand every household member the
-- whole profile row — including `sync_epoch`, `onboarded_at` and whatever
-- lands on `profiles` next — for a screen that needs five fields.
--
-- So this returns those five, for the other member of your own household and
-- nobody else. `email` comes from `auth.users`, which no client-facing policy
-- exposes at all; it is here because the spec's member card shows it and
-- because a household member already knows who they moved in with.
--
-- Returns zero rows when you have no household, or when you are alone in one.
-- That is the honest answer and the caller renders nothing, rather than a
-- half-drawn card.
-- ============================================================================

create or replace function household_member_profile()
returns table (
  user_id uuid,
  display_name text,
  email text,
  base_currency text,
  avatar_path text,
  member_since timestamptz,
  is_owner boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    p.display_name,
    u.email::text,
    p.base_currency,
    p.avatar_path,
    p.created_at,
    p.id = public.household_owner_id(m.household_id)
  from public.household_members m
  join public.profiles p on p.id = m.user_id
  join auth.users u on u.id = m.user_id
  where m.household_id = public.my_household_id()
    and m.user_id <> (select auth.uid())
    and m.deleted_at is null;
$$;

revoke all on function household_member_profile() from public;
grant execute on function household_member_profile() to authenticated, service_role;

-- ============================================================================
-- 3b. …and their face
--
-- The avatar bucket is private and `avatars_select` is own-folder-only, so
-- the Household screen could name the other member but not draw them. The
-- rule the app already states — a household member sees the other member's
-- identity — has to hold in Storage too, or the screen renders an initial
-- next to a name it just fetched, which reads as a broken image rather than
-- as a privacy boundary.
--
-- A `SECURITY DEFINER` helper rather than the join inlined into the policy:
-- inside a policy on `storage.objects` the subquery would have to re-reference
-- the outer `name` column, and the qualified form of that is exactly the kind
-- of expression that silently matches nothing.
-- ============================================================================

create or replace function can_read_household_avatar(p_folder text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members mine
    join public.household_members theirs on theirs.household_id = mine.household_id
    where mine.user_id = (select auth.uid()) and mine.deleted_at is null
      and theirs.deleted_at is null
      and lower(theirs.user_id::text) = lower(p_folder)
  );
$$;

revoke all on function can_read_household_avatar(text) from public;
grant execute on function can_read_household_avatar(text) to authenticated, service_role;

drop policy avatars_select on storage.objects;

-- `lower(...)` on both sides for the same reason as the original policy:
-- `auth.uid()::text` is lowercase and `UUID.uuidString` is uppercase, and the
-- literal comparison rejected every upload the client made until it was fixed.
create policy avatars_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and (
      lower((storage.foldername(name))[1]) = (select auth.uid())::text
      or public.can_read_household_avatar((storage.foldername(name))[1])
    )
  );

-- ============================================================================
-- 3c. Recording that a shared category is a *merge*
--
-- The report has to draw two lists side by side: **Merged** ("we both track
-- Groceries") and **Extra** ("I track Nightlife, and now you can too"). Under
-- 20260912100000 both are the same shape — a `shared_group_id` with one row
-- per member — because `ensure_category_twin` creates the other member's row
-- whenever they had no match. So the schema currently cannot tell the two
-- apart, and every derivation from what it *does* hold is a guess:
--
--   * Names are equal in both cases (a twin copies the name; a merge writes
--     the resultant onto both).
--   * `created_at` is not a discriminator either — a category created after
--     the household exists and then shared produces two recent rows, exactly
--     like a merge of two recent ones.
--   * "Has transactions" is a proxy for "was already mine" that is wrong for
--     every brand-new category.
--
-- So it is recorded, once, at the moment it is known — which is the only
-- moment anybody knows it. An enum rather than `text` + CHECK (CLAUDE.md
-- money rule 4's reasoning, applied to every enum: a CHECK generates as a
-- plain `String` in codegen, an enum as a real type), and nullable because
-- "not a merge" is most shared categories.
-- ============================================================================

create type category_merge_origin as enum ('automatic', 'manual');

alter table categories add column merge_origin category_merge_origin;

comment on column categories.merge_origin is
  'Set on both rows of a shared group formed by joining two categories that already existed. Null means the other member''s row was created by sharing, not merged.';

-- `ensure_category_twin` matched an existing row rather than creating one:
-- that is an automatic merge on exact name, and the report labels it with the
-- robot glyph exactly like a fuzzy one. Restated from `pg_get_functiondef`
-- with the one branch changed rather than retyped from memory — the lesson
-- from 20260911100000, where a from-memory restatement of `pull_changes`
-- silently turned a security-invoker function into a definer one.
create or replace function ensure_category_twin(p_category_id uuid, p_other_member uuid, p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
    update public.categories set shared_group_id = p_group_id, merge_origin = 'automatic'
    where id in (v_twin_id, p_category_id);
  end if;
end;
$$;

revoke all on function ensure_category_twin(uuid, uuid, uuid) from public;

-- Unlinking has to clear the merge with the link — a row still claiming to be
-- half of a merge after its partner has gone would show up in the report's
-- Merged list on its own.
create or replace function unshare_category(p_category_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source record;
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
  update public.categories set shared_group_id = null, merge_origin = null
  where shared_group_id in (
    select shared_group_id from public.categories
    where owner_id = p_user_id and shared_group_id is not null
  );
$$;

revoke all on function unlink_shared_categories(uuid) from public;

-- ============================================================================
-- 4. Merging two categories that mean the same thing
--
-- Two people who have kept their own books for years arrive with "Dine Out"
-- and "Dining Out", "Transport" and "Transportation". Left alone that is two
-- rows in every picker forever. The report's job is to let the owner say
-- "these are one category" once.
--
-- **A merge is not a new row.** 20260912100000 established that a shared
-- category is a pair of rows sharing a `shared_group_id`, one per member,
-- because `transactions (category_id, owner_id) → categories (id, owner_id)`
-- forces every category to stay owned by whoever files transactions under it.
-- Merging therefore means: link the two rows into one group, and write the
-- resultant name/icon/colour onto both. Neither member's transactions move;
-- neither row changes owner. Both sides simply start calling it the same
-- thing.
--
-- The resultant identity is written **explicitly to both rows** rather than
-- left to `categories_propagate_shared_edit` to carry across. That trigger
-- fires on `update of name, icon, color` and only touches siblings whose
-- values differ — which is the right behaviour for an ordinary rename, but
-- here the group is being formed in the same statement and relying on
-- trigger ordering to finish the job would make the outcome depend on which
-- row happened to be updated first.
--
-- Owner authority is enforced here and nowhere else: `p_theirs` belongs to
-- the other member, so this has to be `SECURITY DEFINER` — but it refuses
-- unless the caller *is* the household's owner, both rows belong to members
-- of that household, and the two are of the same kind. An expense category
-- and an income category are not the same category however alike they read.
--
-- Batched, because the setup ceremony applies every fuzzy match at once and a
-- half-applied set of merges is a household nobody can reason about. One
-- transaction, all or nothing.
-- ============================================================================

create or replace function apply_category_merges(p_merges jsonb, p_automatic boolean default false)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
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
    update public.categories c
    set deleted_at = now(), shared_group_id = null, merge_origin = null
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
    -- per member is the invariant every reader depends on.
    update public.categories
    set shared_group_id = null, merge_origin = null
    where shared_group_id is not null
      and shared_group_id in (v_mine.shared_group_id, v_theirs.shared_group_id)
      and id not in (v_mine.id, v_theirs.id);

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

  return v_applied;
end;
$$;

revoke all on function apply_category_merges(jsonb, boolean) from public;
grant execute on function apply_category_merges(jsonb, boolean) to authenticated, service_role;

comment on function apply_category_merges(jsonb, boolean) is
  'Owner-only. Each element is {mine, theirs, name, icon, color}; links both rows into one shared group under the resultant identity.';

-- Undoing a merge, addressed by the group rather than by a row the caller
-- owns — the owner unmerges a pair from the report, and half of that pair is
-- the other member''s.
--
-- Both rows survive with their transactions intact. Unmerging takes back the
-- link, never the data; each side keeps whatever the merged identity last
-- said, because the alternative is restoring a name from before the merge
-- that this schema deliberately does not keep a copy of.
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
end;
$$;

revoke all on function unmerge_category_group(uuid) from public;
grant execute on function unmerge_category_group(uuid) to authenticated, service_role;

-- ============================================================================
-- 5. Deleting a redundant tag without losing what it labelled
--
-- Two people pooling their books arrive with "Holiday" and "Holidays". The
-- report lets the owner delete one — but a tag is not decoration, it is the
-- only record that a transaction belonged to something the user was
-- tracking. `cascade_tag_soft_delete` (20260907100000) tombstones the links
-- along with the tag, which is right for "I do not track this any more" and
-- wrong for "this was the same thing as that one".
--
-- So deletion takes a destination. Every transaction wearing the doomed tag
-- gets the surviving one instead, and only then is the tag tombstoned.
--
-- `p_into_tag_id` may be null — that is the old behaviour, kept, for a tag
-- that genuinely has no successor.
--
-- Owner-authority again, and needed for the same reason: `tags_update` is
-- `owner_id = auth.uid()`, and the tag being pruned is usually the other
-- member's.
-- ============================================================================

create or replace function delete_tag_retagging(p_tag_id uuid, p_into_tag_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_tag public.tags;
  v_into public.tags;
  v_moved integer := 0;
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

  return v_moved;
end;
$$;

revoke all on function delete_tag_retagging(uuid, uuid) from public;
grant execute on function delete_tag_retagging(uuid, uuid) to authenticated, service_role;

comment on function delete_tag_retagging(uuid, uuid) is
  'Soft-deletes a tag, first moving every transaction wearing it onto p_into_tag_id when one is given.';
