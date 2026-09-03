-- Tags — a free label the user applies to any transaction, of any kind.
--
-- Tags are **tracking only**: no target, no budget, no goal. A target was
-- specified and then dropped as too much for one feature; if it comes back
-- it comes back as a column here, not as a second table.
--
-- Two things separate a tag from a category:
--
--   1. A transaction has exactly one category and **any number of tags**.
--      A category answers "what kind of money movement was this"; a tag
--      answers "which of my ongoing things was this part of", and those
--      overlap by design — a coffee is Food *and* part of the coffee habit
--      the user is watching.
--   2. A tag applies to **all three kinds**, transfers included. Transfers
--      have no category at all (`transactions.category_id is null` on both
--      legs), so an all-categories tag is the only kind that can reach
--      them — which falls out of the category rule below rather than
--      needing a rule of its own.
--
-- `category_id null` means **All categories**: the tag can go on any
-- transaction. A non-null `category_id` restricts it to transactions in
-- that one category, enforced by trigger below rather than trusted from
-- the client.

-- ============================================================================
-- tags
--
-- The composite FK `(category_id, owner_id) → categories (id, owner_id)` is
-- the same one budgets carried and exists for the same reason (H12): a plain
-- `category_id → categories(id)` would let a tag point at another user's
-- category, which is latent today and live the moment household categories
-- merge.
-- ============================================================================

create table tags (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  name text not null check (length(btrim(name)) between 1 and 40),
  category_id uuid,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  sync_seq bigint not null default 0,
  foreign key (category_id, owner_id) references categories (id, owner_id) deferrable initially deferred
);

-- Unique per owner, case-insensitively, and only among live rows — a
-- deleted tag's name is free to reuse, which is the behaviour a user
-- expects after deleting "Coffee" and typing it again. `lower(name)` rather
-- than a citext column: one index expression is cheaper than a type
-- dependency, and every comparison this schema already makes on category
-- names (`merge_household_categories`) is `lower()`-based too.
create unique index tags_owner_name_idx on tags (owner_id, lower(btrim(name)))
  where deleted_at is null;

create index tags_owner_idx on tags (owner_id) where deleted_at is null;
create index tags_category_idx on tags (category_id) where deleted_at is null;
create index tags_sync_seq_idx on tags (sync_seq);

-- ============================================================================
-- transaction_tags — the join. Carries `owner_id` denormalized so it can
-- reuse `stamp_sync_seq_owner()` unchanged and land in the same sync domain
-- as the transaction it points at; set by trigger from the transaction,
-- never trusted from the client.
--
-- Soft-deleted, not hard-deleted, like every other syncable table here: a
-- pull carries a tombstone as an ordinary row, and a hard DELETE would
-- simply never reach the other device.
-- ============================================================================

create table transaction_tags (
  transaction_id uuid not null references transactions (id) deferrable initially deferred,
  tag_id uuid not null references tags (id) deferrable initially deferred,
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  sync_seq bigint not null default 0,
  primary key (transaction_id, tag_id)
);

create index transaction_tags_tag_idx on transaction_tags (tag_id) where deleted_at is null;
create index transaction_tags_owner_idx on transaction_tags (owner_id);
create index transaction_tags_sync_seq_idx on transaction_tags (sync_seq);

-- ============================================================================
-- can_read_tag — a tag is visible to its owner, and to the other household
-- member once it has been applied to a transaction on a **shared account**.
--
-- Visibility is **derived, never stored**. That is what makes the spec's
-- "if account sharing is revoked, the tags do so too" free: unshare the
-- account and the `household_accounts` row goes, and this stops returning
-- true on the very next query. A stored `is_shared` flag would have to be
-- recomputed on every unshare, on every leave, and on every fork, and would
-- be wrong in between.
--
-- **The category half of the rule is deliberately not here yet.** The spec
-- also shares a tag when its linked category is shared, but categories are
-- strictly per-owner today (`categories_select` is `owner_id = auth.uid()`
-- with no household clause) — there is no such thing as a shared category
-- to test. That clause lands with the household category-sharing work,
-- which is the next feature; this function is the one place it goes.
--
-- SECURITY DEFINER for the same reason `can_read_account` is: the inner
-- reads must not be subject to the callers' own RLS policies, or a tag
-- attached to a transaction on the partner's shared account would be
-- filtered out by `transactions_select` before this could see it.
-- ============================================================================

create function can_read_tag(p_tag_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tags where id = p_tag_id and owner_id = (select auth.uid())
  )
  or exists (
    select 1
    from public.transaction_tags tt
    join public.transactions t on t.id = tt.transaction_id
    join public.household_accounts ha on ha.account_id = t.account_id and ha.deleted_at is null
    join public.household_members hm on hm.household_id = ha.household_id and hm.deleted_at is null
    where tt.tag_id = p_tag_id
      and tt.deleted_at is null
      and t.deleted_at is null
      and hm.user_id = (select auth.uid())
  );
$$;

revoke all on function can_read_tag(uuid) from public;
grant execute on function can_read_tag(uuid) to authenticated;

-- ============================================================================
-- RLS
--
-- Writes stay owner-only on both tables. A household member can *see* a
-- shared tag and can put it on their own transactions, but cannot rename or
-- delete someone else's tag — the same asymmetry a shared account already
-- has for its name.
-- ============================================================================

alter table tags enable row level security;

create policy tags_select on tags
  for select to authenticated
  using (can_read_tag(id));

create policy tags_insert on tags
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy tags_update on tags
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, insert, update on tags to authenticated, service_role;

alter table transaction_tags enable row level security;

-- Visible exactly when its transaction is. Restating `transactions_select`'s
-- own two branches rather than joining to it: the null-account_id branch is
-- a pending capture, which belongs to its owner alone.
create policy transaction_tags_select on transaction_tags
  for select to authenticated
  using (
    exists (
      select 1 from transactions t
      where t.id = transaction_tags.transaction_id
        and (
          (t.account_id is not null and can_read_account(t.account_id))
          or (t.account_id is null and t.owner_id = (select auth.uid()))
        )
    )
  );

-- Writable by anyone who can write the transaction's account, using any tag
-- they can read — that is what lets a household member tag a transaction on
-- a shared account with a tag the other member created.
create policy transaction_tags_insert on transaction_tags
  for insert to authenticated
  with check (
    can_read_tag(tag_id)
    and exists (
      select 1 from transactions t
      where t.id = transaction_tags.transaction_id
        and (
          (t.account_id is not null and can_write_account(t.account_id))
          or (t.account_id is null and t.owner_id = (select auth.uid()))
        )
    )
  );

create policy transaction_tags_update on transaction_tags
  for update to authenticated
  using (
    exists (
      select 1 from transactions t
      where t.id = transaction_tags.transaction_id
        and (
          (t.account_id is not null and can_write_account(t.account_id))
          or (t.account_id is null and t.owner_id = (select auth.uid()))
        )
    )
  )
  with check (
    exists (
      select 1 from transactions t
      where t.id = transaction_tags.transaction_id
        and (
          (t.account_id is not null and can_write_account(t.account_id))
          or (t.account_id is null and t.owner_id = (select auth.uid()))
        )
    )
  );

grant select, insert, update on transaction_tags to authenticated, service_role;

-- ============================================================================
-- set_transaction_tag_derived_columns — owner and the category rule.
--
-- `owner_id` is taken from the transaction, never from the client: it has
-- to match the transaction's own owner for `stamp_sync_seq_owner()` to put
-- the row in the right sync domain, and a client-supplied value could put a
-- household member's tagging of a shared transaction into their own domain
-- instead of the household's, where the account owner would never pull it.
--
-- The category rule is the spec's own: a tag bound to a category may only
-- go on a transaction in that category. A transfer has no category at all,
-- so only an all-categories tag can reach one — that falls out of this
-- comparison rather than needing a transfer branch.
-- ============================================================================

create function set_transaction_tag_derived_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn_owner uuid;
  v_txn_category uuid;
  v_tag_category uuid;
  v_tag_name text;
begin
  select owner_id, category_id into v_txn_owner, v_txn_category
  from public.transactions where id = new.transaction_id;

  if v_txn_owner is null then
    raise exception 'transaction % not found', new.transaction_id;
  end if;

  new.owner_id := v_txn_owner;

  -- A row on its way OUT is never re-validated. Both cascades below work by
  -- soft-deleting links, and one of them
  -- (`drop_incompatible_transaction_tags`) soft-deletes precisely the links
  -- this check would now reject — re-running the category rule on the way
  -- out would make that cleanup structurally impossible. The other
  -- (`cascade_tag_soft_delete`) has already soft-deleted the tag, so the
  -- lookup below would not find it either. Reviving a link
  -- (`deleted_at → null`) still goes through the full check.
  if new.deleted_at is not null then
    return new;
  end if;

  select category_id, name into v_tag_category, v_tag_name
  from public.tags where id = new.tag_id and deleted_at is null;

  if v_tag_name is null then
    raise exception 'tag % not found', new.tag_id;
  end if;

  if v_tag_category is not null and v_tag_category is distinct from v_txn_category then
    raise exception 'tag "%" only applies to transactions in its own category', v_tag_name;
  end if;

  return new;
end;
$$;

revoke all on function set_transaction_tag_derived_columns() from public;

create trigger transaction_tags_set_derived
  before insert or update on transaction_tags
  for each row execute function set_transaction_tag_derived_columns();

-- ============================================================================
-- drop_incompatible_transaction_tags — when a transaction's category
-- changes, any tag bound to the old category stops applying and is dropped.
--
-- Silently, and on purpose: the alternative is refusing the category edit,
-- which would make a tag applied months ago block a correction the user is
-- making now. The tag itself is untouched — only this transaction's link to
-- it goes. Soft-deleted like every other row here, so the other device
-- learns about it through the ordinary pull.
-- ============================================================================

create function drop_incompatible_transaction_tags()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.transaction_tags tt
  set deleted_at = now(), updated_at = now()
  from public.tags tg
  where tt.transaction_id = new.id
    and tt.tag_id = tg.id
    and tt.deleted_at is null
    and tg.category_id is not null
    and tg.category_id is distinct from new.category_id;
  return null;
end;
$$;

revoke all on function drop_incompatible_transaction_tags() from public;

create trigger transactions_drop_incompatible_tags
  after update of category_id on transactions
  for each row
  when (old.category_id is distinct from new.category_id)
  execute function drop_incompatible_transaction_tags();

-- ============================================================================
-- delete_tag_cascade — soft-deleting a tag must take its links with it, or
-- a device that already pulled the links keeps rendering a chip for a tag
-- that no longer exists. The tag row's own tombstone says nothing about the
-- join rows.
-- ============================================================================

create function cascade_tag_soft_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.transaction_tags
  set deleted_at = new.deleted_at, updated_at = now()
  where tag_id = new.id and deleted_at is null;
  return null;
end;
$$;

revoke all on function cascade_tag_soft_delete() from public;

create trigger tags_cascade_soft_delete
  after update of deleted_at on tags
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function cascade_tag_soft_delete();

-- ============================================================================
-- Housekeeping triggers, same set every syncable table carries.
-- ============================================================================

create trigger tags_set_updated_at
  before update on tags
  for each row execute function set_updated_at();

create trigger tags_bump_version
  before update on tags
  for each row execute function bump_version();

create trigger tags_stamp_sync_seq
  before insert or update on tags
  for each row execute function stamp_sync_seq_owner();

create trigger transaction_tags_set_updated_at
  before update on transaction_tags
  for each row execute function set_updated_at();

create trigger transaction_tags_stamp_sync_seq
  before insert or update on transaction_tags
  for each row execute function stamp_sync_seq_owner();

-- ============================================================================
-- pull_changes — restated in full from 20260906100000, plus the two new
-- tables, re-read end to end rather than patched from an excerpt, per
-- version-logs/lessons-learned.md.
--
-- Both new branches are RLS-filtered for free, exactly like every other
-- table here: the function is `security invoker` by default and the
-- policies above do the scoping, which is what makes a shared tag reach the
-- other household member and a private one not.
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
$$;

revoke all on function public.pull_changes(bigint, bigint) from public, anon;
grant execute on function public.pull_changes(bigint, bigint) to authenticated;

-- ============================================================================
-- fork_household_accounts' registry — `transaction_tags` has no `account_id`
-- column, so the guard there does not see it, but a fork DOES need to know
-- about it: forking duplicates transactions to both members, and the copies
-- would silently lose their tags.
--
-- Registering it is not enough on its own (the registry only lists tables
-- the fork already handles), so this is recorded here as the known gap it
-- is: the fork carries tags forward only once household category sharing
-- lands and the fork is revisited, which is the next feature. Tags on a
-- forked transaction are lost today, and no data of the user's own is
-- destroyed by that — the tag itself survives, only the link does not.
-- ============================================================================

comment on table transaction_tags is
  'Join between transactions and tags. NOT carried through fork_household_accounts yet — '
  'a forked transaction copy loses its tag links. Closed with the household category-sharing work.';
