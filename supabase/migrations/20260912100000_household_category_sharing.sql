-- Household category sharing, and the invite flow that chooses it.
--
-- Accounts have been shareable since Phase 7. Categories have not been
-- shareable at all — `categories_select` was `owner_id = auth.uid()` with no
-- household clause — and `accept_invite` papered over it by calling
-- `merge_household_categories`, which copied **every** category both ways the
-- moment anyone joined: no choice, no way to tell a shared one from a private
-- one, no way to change your mind, and the icon and colour left behind.
--
-- ============================================================================
-- Why a shared category is two rows and not one
-- ============================================================================
--
-- `transactions` carries `(category_id, owner_id) → categories(id, owner_id)`.
-- A transaction on your own account is owned by you, so it can only reference
-- a category **you** own. One shared row would therefore be unusable by
-- whichever member did not own it, and making it usable means dropping a
-- foreign key that guarantees a transaction can never point at a stranger's
-- category — on the table that holds all the money.
--
-- So a shared category is a **pair of rows sharing a `shared_group_id`**, one
-- per member, and every edit writes through to the other. The invariant that
-- makes this work is that a group always has exactly one row per member: the
-- other member's row is created if they have no match by name, so both sides
-- can always categorise their own transactions with their own row and the
-- foreign key never has to bend.
--
-- Sharing a category shares **the label, not the history**. Transaction
-- visibility stays account-scoped: `can_read_account` decides who sees money,
-- and it stays the only thing that does.

-- ============================================================================
-- 1. The link
-- ============================================================================

alter table categories add column shared_group_id uuid;

create index categories_shared_group_idx on categories (shared_group_id)
  where shared_group_id is not null and deleted_at is null;

comment on column categories.shared_group_id is
  'Rows sharing this are the same category, one per household member. Null means private.';

-- ============================================================================
-- 2. Who can read a category
--
-- Three branches, and the third is a **fix, not a feature**. Today a member
-- looking at a shared account sees the amount and the account name and
-- `category_name` as NULL — `transactions_with_details` is `security_invoker`
-- and left-joins `categories`, which owner-only visibility empties out. The
-- shared ledger has been half-legible since accounts became shareable.
--
-- The shape is `can_read_tag`'s, deliberately: a label attached to something
-- you are allowed to see is something you are allowed to read.
-- ============================================================================

create or replace function can_read_category(p_category_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.categories c
    where c.id = p_category_id
      and (
        -- yours
        c.owner_id = (select auth.uid())
        -- or deliberately shared by a member of your household
        or (
          c.shared_group_id is not null
          and exists (
            select 1
            from public.household_members mine
            join public.household_members theirs on theirs.household_id = mine.household_id
            where mine.user_id = (select auth.uid()) and mine.deleted_at is null
              and theirs.user_id = c.owner_id and theirs.deleted_at is null
          )
        )
        -- or it labels a transaction on an account you can already read
        or exists (
          select 1 from public.transactions t
          where t.category_id = c.id
            and t.account_id is not null
            and t.deleted_at is null
            and public.can_read_account(t.account_id)
        )
      )
  );
$$;

revoke all on function can_read_category(uuid) from public;
grant execute on function can_read_category(uuid) to authenticated, service_role;

drop policy categories_select on categories;

create policy categories_select on categories
  for select to authenticated
  using (can_read_category(id));

-- ============================================================================
-- 3. An edit to one row is an edit to the category
--
-- No recursion guard needed: the update below only fires for siblings whose
-- values actually differ, so the sibling's own trigger finds nothing left to
-- change and stops. A flag would be one more thing to get wrong.
--
-- `is_default` and `kind` are deliberately not propagated — kind is part of
-- the match, and each member has exactly one default per kind of their own.
-- ============================================================================

create or replace function propagate_shared_category_edit()
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
    and (name is distinct from new.name or icon is distinct from new.icon or color is distinct from new.color);

  return null;
end;
$$;

revoke all on function propagate_shared_category_edit() from public;

create trigger categories_propagate_shared_edit
after update of name, icon, color on categories
for each row execute function propagate_shared_category_edit();

-- ============================================================================
-- 4. share_category / unshare_category — the same shape as their account
--    siblings, so the Household screen can offer both the same way.
-- ============================================================================

-- Finds the other member's row for a category, creating it if they have none
-- by that name and kind. This is the invariant the whole design rests on:
-- after this, both members own a row in the group, so both can use it.
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
    -- second one anyway.
    insert into public.categories (owner_id, kind, name, icon, color, shared_group_id)
    values (p_other_member, v_source.kind, v_source.name, v_source.icon, v_source.color, p_group_id);
  else
    update public.categories set shared_group_id = p_group_id where id = v_twin_id;
  end if;

  update public.categories set shared_group_id = p_group_id where id = p_category_id;
end;
$$;

revoke all on function ensure_category_twin(uuid, uuid, uuid) from public;

create or replace function share_category(p_category_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source record;
  v_household_id uuid := public.my_household_id();
  v_other uuid;
begin
  select * into v_source from public.categories where id = p_category_id and deleted_at is null;
  if v_source.id is null or v_source.owner_id <> (select auth.uid()) then
    raise exception 'category not found or not owned by you';
  end if;

  -- The two "Other" rows are each member's own fallback, and a mirror of one
  -- would collide with the other member's own default.
  if v_source.is_default then
    raise exception 'the default category cannot be shared';
  end if;

  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  if v_source.shared_group_id is not null then
    return;
  end if;

  select user_id into v_other from public.household_members
  where household_id = v_household_id and user_id <> (select auth.uid()) and deleted_at is null
  limit 1;

  -- Shareable before anyone else arrives: the group is recorded now and the
  -- twin is created when they accept, which is what lets the invite flow ask
  -- "what will you share?" before there is anybody to share it with.
  if v_other is null then
    update public.categories set shared_group_id = gen_random_uuid() where id = p_category_id;
    return;
  end if;

  perform public.ensure_category_twin(p_category_id, v_other, gen_random_uuid());
end;
$$;

revoke all on function share_category(uuid) from public;
grant execute on function share_category(uuid) to authenticated, service_role;

-- Unlinks **every** row in the group, not just the caller's: a shared
-- category with one member left in it is a private category wearing a badge.
-- The other member keeps their row and its transactions — unsharing takes
-- back the link, never their data.
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

  update public.categories set shared_group_id = null where shared_group_id = v_source.shared_group_id;
end;
$$;

revoke all on function unshare_category(uuid) from public;
grant execute on function unshare_category(uuid) to authenticated, service_role;

-- Every group a departing member belonged to. Called by leave/erase/delete:
-- the same reasoning as `unshare_category` above, applied to all of them at
-- once, and the reason a fork never has to reason about shared categories.
create or replace function unlink_shared_categories(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.categories set shared_group_id = null
  where shared_group_id in (
    select shared_group_id from public.categories
    where owner_id = p_user_id and shared_group_id is not null
  );
$$;

revoke all on function unlink_shared_categories(uuid) from public;

-- ============================================================================
-- 5. The invite carries what the inviter chose
--
-- Stored on the invite rather than applied when it is created: until someone
-- accepts there is no one to share with, and an invite that quietly changed
-- the inviter's data before anybody used it would be a surprise if it expired
-- unused.
-- ============================================================================

alter table household_invites
  add column shared_account_ids uuid[] not null default '{}',
  add column shared_category_ids uuid[] not null default '{}';

comment on column household_invites.shared_account_ids is
  'What the inviter chose to share, applied when the invite is accepted.';

-- ============================================================================
-- 6. create_invite / preview_invite / accept_invite
--
-- The old zero-argument `create_invite` and single-argument `accept_invite`
-- are dropped rather than overloaded: a default-valued overload alongside the
-- old signature is ambiguous for the call that supplies no arguments, and
-- both callers are in this repository.
-- ============================================================================

drop function if exists create_invite();

create or replace function create_invite(
  p_share_account_ids uuid[] default '{}',
  p_share_category_ids uuid[] default '{}'
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_token text;
begin
  if not public.ops_check_own_rate_limit('create_invite', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

  if v_household_id is null then
    raise exception 'create a household before inviting a member';
  end if;

  -- Only your own, and only things that exist. A selection is a promise about
  -- what the other member will get; silently dropping an unowned id would
  -- make the review screen a lie.
  if exists (
    select 1 from unnest(p_share_account_ids) as a(id)
    where not exists (
      select 1 from public.accounts
      where id = a.id and owner_id = (select auth.uid()) and deleted_at is null
    )
  ) then
    raise exception 'cannot share an account you do not own';
  end if;

  if exists (
    select 1 from unnest(p_share_category_ids) as c(id)
    where not exists (
      select 1 from public.categories
      where id = c.id and owner_id = (select auth.uid()) and deleted_at is null and not is_default
    )
  ) then
    raise exception 'cannot share a category you do not own';
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');

  insert into public.household_invites (
    household_id, invited_by, token_hash, expires_at, shared_account_ids, shared_category_ids
  )
  values (
    v_household_id, (select auth.uid()), encode(extensions.digest(v_token, 'sha256'), 'hex'),
    now() + interval '7 days', p_share_account_ids, p_share_category_ids
  );

  return v_token;
end;
$$;

revoke all on function create_invite(uuid[], uuid[]) from public;
grant execute on function create_invite(uuid[], uuid[]) to authenticated, service_role;

-- What the invitee is about to receive, before they commit to anything.
--
-- Readable by whoever holds the token and nobody else — the token is a secret
-- the inviter chose to hand over, and it expires. Names only: no ids, no
-- amounts, nothing that outlives the decision it exists to inform.
create or replace function preview_invite(p_token text)
returns table (account_name text, category_name text, category_kind public.category_kind)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
begin
  if not public.ops_check_own_rate_limit('preview_invite', 20, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select * into v_invite from public.household_invites
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();

  if v_invite.id is null then
    raise exception 'invite not found, already used, or expired';
  end if;

  return query
  select a.name, null::text, null::public.category_kind
  from public.accounts a
  where a.id = any(v_invite.shared_account_ids) and a.deleted_at is null
  union all
  select null::text, c.name, c.kind
  from public.categories c
  where c.id = any(v_invite.shared_category_ids) and c.deleted_at is null;
end;
$$;

revoke all on function preview_invite(text) from public;
grant execute on function preview_invite(text) to authenticated, service_role;

drop function if exists accept_invite(text);

create or replace function accept_invite(
  p_token text,
  p_share_account_ids uuid[] default '{}',
  p_share_category_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
  v_event_id uuid;
  v_me uuid := (select auth.uid());
  v_category_id uuid;
  v_account_id uuid;
begin
  if not public.ops_check_own_rate_limit('accept_invite', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

  if public.my_household_id() is not null then
    raise exception 'already a member of a household';
  end if;

  select * into v_invite from public.household_invites
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();

  if v_invite.id is null then
    raise exception 'invite not found, already used, or expired';
  end if;

  if v_invite.invited_by = v_me then
    raise exception 'cannot accept your own invite';
  end if;

  insert into public.household_members (household_id, user_id)
  values (v_invite.household_id, v_me)
  on conflict (household_id, user_id) do update set deleted_at = null, joined_at = now();

  update public.household_invites set status = 'accepted' where id = v_invite.id;

  -- The inviter's choices, made real now that there is somebody to share
  -- with. Their accounts first: sharing one is the inviter's own act, and
  -- `share_account` runs as its owner, so it is inlined here rather than
  -- called — the caller is the invitee.
  foreach v_account_id in array v_invite.shared_account_ids loop
    if exists (select 1 from public.accounts where id = v_account_id and owner_id = v_invite.invited_by and deleted_at is null) then
      insert into public.household_accounts (household_id, account_id)
      values (v_invite.household_id, v_account_id)
      on conflict (household_id, account_id) do update set deleted_at = null, shared_at = now();
      perform public.restamp_account_for_sync(v_account_id);
    end if;
  end loop;

  -- Then the categories, in both directions. `ensure_category_twin` matches
  -- by trimmed, case-insensitive name and kind — the inviter's "Groceries"
  -- and the invitee's "groceries" become one category rather than two that
  -- look identical — and creates the other member's row when there is no
  -- match, which is what keeps every group one-row-per-member.
  foreach v_category_id in array v_invite.shared_category_ids loop
    if exists (
      select 1 from public.categories
      where id = v_category_id and owner_id = v_invite.invited_by and deleted_at is null and not is_default
    ) then
      perform public.ensure_category_twin(
        v_category_id, v_me,
        coalesce(
          (select shared_group_id from public.categories where id = v_category_id),
          gen_random_uuid()
        )
      );
    end if;
  end loop;

  foreach v_category_id in array p_share_category_ids loop
    if exists (
      select 1 from public.categories
      where id = v_category_id and owner_id = v_me and deleted_at is null and not is_default
    ) then
      -- Already linked by the loop above when both members named it the same
      -- thing; `coalesce` keeps that group rather than starting a second one.
      perform public.ensure_category_twin(
        v_category_id, v_invite.invited_by,
        coalesce(
          (select shared_group_id from public.categories where id = v_category_id),
          gen_random_uuid()
        )
      );
    end if;
  end loop;

  foreach v_account_id in array p_share_account_ids loop
    if exists (select 1 from public.accounts where id = v_account_id and owner_id = v_me and deleted_at is null) then
      insert into public.household_accounts (household_id, account_id)
      values (v_invite.household_id, v_account_id)
      on conflict (household_id, account_id) do update set deleted_at = null, shared_at = now();
      perform public.restamp_account_for_sync(v_account_id);
    end if;
  end loop;

  update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

  insert into public.household_events (household_id, actor_id, kind)
  values (v_invite.household_id, v_me, 'member_joined')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);

  return v_invite.household_id;
end;
$$;

revoke all on function accept_invite(text, uuid[], uuid[]) from public;
grant execute on function accept_invite(text, uuid[], uuid[]) to authenticated, service_role;

-- Replaced by the selective, linked version above. It copied every category
-- both ways on join — no choice, no link, and the icon and colour dropped.
drop function if exists merge_household_categories(uuid, uuid);

-- ============================================================================
-- 7. Departing unlinks
--
-- A shared category is a link between two members, so it cannot outlive one
-- of them being in the household. Both of these are restated from
-- `pg_get_functiondef` with one line added rather than retyped — the lesson
-- from 20260911100000, where a from-memory restatement of `pull_changes`
-- silently turned a security-invoker function into a definer one.
--
-- The other member keeps their row and everything filed under it. Unsharing
-- takes back the link and never the data.
-- ============================================================================

create or replace function leave_household()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is null then
    raise exception 'not a member of a household';
  end if;

  select user_id into v_other from public.household_members
  where household_id = v_household_id and user_id <> v_me and deleted_at is null;

  if v_other is not null then
    perform public.fork_household_accounts(v_household_id, v_me, v_other);
  end if;

  update public.household_members set deleted_at = now()
  where household_id = v_household_id and user_id = v_me and deleted_at is null;

    perform public.unlink_shared_categories(v_me);

  update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

  insert into public.household_events (household_id, actor_id, kind)
  values (v_household_id, v_me, 'member_left')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);
end;
$$;

create or replace function erase_own_account()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is not null then
    select user_id into v_other from public.household_members
    where household_id = v_household_id and user_id <> v_me and deleted_at is null;

    if v_other is not null then
      perform public.fork_household_accounts(v_household_id, v_me, v_other);
    end if;

    update public.household_members set deleted_at = now()
    where household_id = v_household_id and user_id = v_me and deleted_at is null;

      perform public.unlink_shared_categories(v_me);

  update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

    insert into public.household_events (household_id, actor_id, kind)
    values (v_household_id, v_me, 'member_erased')
    returning id into v_event_id;

    perform public.notify_household(v_event_id);
  end if;

  update public.transactions set merchant_raw = null, merchant_normalized = null
  where owner_id = v_me and (merchant_raw is not null or merchant_normalized is not null);

  update public.card_mappings set card_identifier = 'erased'
  where owner_id = v_me;
end;
$$;

-- ============================================================================
-- 8. Creating a household bumps the creator's sync epoch
--
-- A **pre-existing bug**, found walking the new flow: create a household and
-- your own phone never shows one.
--
-- `sync_domain_id` returns the household id once you are a member, so
-- creating a household moves the caller out of their personal ticket sequence
-- and into the household's — which starts at 1. The client's cursor is
-- already well past that, so `sync_seq > cursor` never matches the household
-- and membership rows, and the creator's device sits there offering to create
-- a household it already has.
--
-- This is exactly the domain change the epoch mechanism exists for
-- (app-architecture.md's LH2/LH3): `accept_invite`, `leave_household` and
-- `unshare_account` all bump for it, and a cursor from before a domain change
-- is denominated in a different, unrelated counter. Creating was the one door
-- into a household that did not.
-- ============================================================================

create or replace function create_household()
returns households
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_result public.households;
begin
  if public.my_household_id() is not null then
    raise exception 'you already belong to a household';
  end if;

  insert into public.households (id) values (v_id) returning * into v_result;
  insert into public.household_members (household_id, user_id) values (v_id, (select auth.uid()));

  update public.profiles set sync_epoch = sync_epoch + 1 where id = (select auth.uid());

  return v_result;
end;
$$;

revoke all on function create_household() from public;
grant execute on function create_household() to authenticated, service_role;
