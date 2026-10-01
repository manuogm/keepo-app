-- The owner keeps the account.
--
-- Phase 3 of the "Transfers & household sharing" workstream
-- (keepo-v1-master-plan.md), closing review findings #1, #7 and #8.
--
-- ============================================================================
-- 1. When a share ends, only the member losing access gets a copy (#7)
-- ============================================================================
--
-- An account has one owner, and sharing never changes that. The old fork
-- treated the end of a share as the end of the account: it archived the
-- original and copied it for *both* members. The owner's own account turned
-- into an archived original plus a copy, their transfers degraded to "Other"
-- adjustments, notes, tags and paid-in-currency figures were dropped, and
-- their Cashflow counted the whole shared history twice.
--
-- Now, when a share ends (unshare, leave, erasure), `fork_accounts`:
--
--   * leaves the owner's account alone: same id, full history, card mappings,
--     rules and transfer pairs;
--   * hands the member losing access a copy holding exactly what they could
--     see: the transactions `transaction_visible_to` them, confirmed and live,
--     with notes, titles, tags and paid-in-currency figures; the account opens
--     on what they saw it open on (`opening_seen_from` — the carried opening
--     when the share began on a date);
--   * copies the account's recurring rules **paused** (user's decision,
--     2026-09-23): the copy is a snapshot of shared history and should not
--     keep receiving the owner's rent every month. A transfer rule is copied
--     only when both of its accounts are handed to the same member.
--
-- A pending capture is not copied: it is the owner's card purchase waiting
-- for the owner's review, it counts in no balance, and a copy would ask the
-- other member to review a purchase they never made.
--
-- Categories and tags on a copy are the member's own, matched by name:
-- `fork_category_id` as before (falling back to the default), and
-- `fork_tag_id`, which creates the member's tag when they have none.
--
-- Each copied row's id is `fork_copy_id(fork, original)`, a hash of the
-- original's id and a per-fork salt, so every statement below can find a
-- copy from its original without a lookup table.
--
-- ============================================================================
-- 2. Transfer pairs are rebuilt per person (#1)
-- ============================================================================
--
-- After a share ends, each person's halves of a touched pair — the halves
-- they own, plus the copies they were just handed — form one pair when there
-- are two, and a lone half is detached. That single rule covers every case:
--
--   * both halves on the owner's accounts: the owner keeps the pair
--     untouched, and the member's two copies (if both accounts were handed
--     over) pair with each other;
--   * a household ends with a transfer between the two members' accounts: it
--     splits into one pair per member, each an original half plus a copy;
--   * an account is unshared while it has a transfer to the partner's
--     still-shared account (user's decision, 2026-09-23): the partner's half
--     pairs with their copy, and the owner's half is detached — a payment
--     into someone else's account. No pair ever spans a private account and
--     the other member's account.
--
-- A pair keeps its group id when its sending half is an original, and takes
-- the copy's id when that half is a copy — `create_transfer`'s convention.
--
-- `detach_transfer_leg` is the one way a half stops being a transfer: its
-- group goes, it takes its owner's default category for its sign, its source
-- becomes `adjustment`, and its note, title and tags stay.
--
-- ============================================================================
-- 3. The owner's rows stop wearing the member's tags
-- ============================================================================
--
-- A partner may tag the owner's shared transaction with their own tag. Once
-- the share ends the owner can no longer read that tag, and — found while
-- building this — the partner could no longer delete their Keepo account: the
-- owner's link held the tag's foreign key and the delete failed at commit.
-- Such a link is now swapped for the owner's own tag of the same name
-- (`swap_in_own_tags`), created when the owner has none. Categories need no
-- such step: `(category_id, owner_id)` is a foreign key, so a transaction or
-- rule only ever wears its owner's category.
--
-- ============================================================================
-- 4. The fork's guard finds account references by foreign key (#8)
-- ============================================================================
--
-- The guard scanned columns named `account_id`, so `recurring_rules
-- .to_account_id` escaped it: a recurring transfer *into* a forked account went
-- dormant (the original was archived) and vanished from the Recurring list.
-- The owner's account is no longer archived at all, and the registry is now
-- by column, swept like `unregistered_identity_columns`: every foreign key to
-- `accounts(id)`, plus every column named like an account reference.
--
-- ============================================================================
-- 5. Deleting a Keepo account leaves nothing dangling (#1)
-- ============================================================================
--
-- `delete_own_account` hard-deletes the leaver's rows. The fork above now
-- settles everything a live household shared, but older data can still pair
-- the leaver's transfer half with someone else's, or put the leaver's tag on
-- someone else's row (forks before this one did neither step). Before the
-- hard delete, those halves are detached and those tags swapped; tag-link
-- tombstones still pointing at the leaver's tags go with them.
--
-- `erase_own_account` now also bumps the remaining member's sync epoch. They
-- lose access to the eraser's accounts exactly as an unshare's partner does,
-- and without a full re-pull their phone kept showing them.
--
-- ============================================================================
-- 6. An ended share is not a share
-- ============================================================================
--
-- `net_worth` and `accounts_with_balances.is_shared` counted any
-- `household_accounts` row, ended or not. The archive the old fork put on the
-- owner's account hid that; with the account left alone, an unshared account
-- read as shared for as long as the household lasted. Both now look at live
-- shares only, as every query on the phone already does.
--
-- ============================================================================
-- 7. net_worth_daily is removed
-- ============================================================================
--
-- A materialized cache readable through the API and unused by the app since
-- the net worth trajectory moved on-device. It goes with the two functions
-- that wrote and read it.

-- ============================================================================
-- net_worth_daily
-- ============================================================================

drop function public.net_worth_series(public.account_scope, date, date);
drop function public.refresh_net_worth_daily(uuid, date, date);
drop table public.net_worth_daily;
delete from public.deletion_handled_columns where table_name = 'net_worth_daily';

-- Only the comment changes: the function it pointed to is gone.
create or replace function public.household_owner_id(p_household_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id
  from public.household_members m
  where m.household_id = p_household_id
    and m.deleted_at is null
    -- Added 20261004100000. The null-uid arm follows the same convention as
    -- `account_balance_on`: a caller with no JWT is the cron or an edge
    -- function holding the service key — trusted server-side code, not a
    -- client, and the one case where asking about an arbitrary household is
    -- the point rather than the problem.
    and (
      (select auth.uid()) is null
      or p_household_id = public.my_household_id()
    )
  order by m.joined_at, m.user_id
  limit 1;
$$;

-- ============================================================================
-- Live shares only
-- ============================================================================

-- Restated from 20260820100000 with `ha.deleted_at is null` in both scopes.
create or replace function public.net_worth(p_scope public.account_scope)
returns bigint
language sql
stable
set search_path = ''
as $$
  select case p_scope
    when 'me' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where ab.archived_at is null
        and not exists (
          select 1 from public.household_accounts ha
          where ha.account_id = ab.account_id and ha.deleted_at is null
        )
    )
    when 'household' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where ab.archived_at is null
        and exists (
          select 1 from public.household_accounts ha
          where ha.account_id = ab.account_id and ha.deleted_at is null
        )
    )
    when 'total' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base_e4 is null) then null
        else sum(ab.balance_base_e4)
      end
      from public.account_balances_base ab
      where ab.archived_at is null
    )
  end;
$$;

-- Restated from 20260902100000 with `ha.deleted_at is null` in `is_shared`.
create or replace view public.accounts_with_balances
with (security_invoker = true) as
select
  a.id as account_id, a.name, a.kind, a.currency, c.minor_unit,
  a.include_in_total, a.icon, a.color, a.archived_at,
  ab.balance_e4, abb.base_currency, bc.minor_unit as base_minor_unit,
  abb.balance_base_e4, abb.has_missing_rate, a.version,
  exists (
    select 1 from public.household_accounts ha where ha.account_id = a.id and ha.deleted_at is null
  ) as is_shared
from public.accounts a
  join public.account_balances ab on ab.account_id = a.id
  join public.currencies c on c.code = a.currency
  join public.account_balances_base abb on abb.account_id = a.id
  left join public.currencies bc on bc.code = abb.base_currency;

-- ============================================================================
-- The guard, by column
-- ============================================================================

drop table public.fork_handled_tables;

create table public.fork_handled_columns (
  table_name text not null,
  column_name text not null,
  handling text not null check (handling in ('copied', 'copied_paused', 'stays_with_owner', 'share_ended')),
  primary key (table_name, column_name)
);

insert into public.fork_handled_columns (table_name, column_name, handling) values
  ('transactions', 'account_id', 'copied'),
  ('recurring_rules', 'account_id', 'copied_paused'),
  ('recurring_rules', 'to_account_id', 'copied_paused'),
  -- `(account_id, owner_id)` is a foreign key: a mapping is always the
  -- account owner's, and the owner keeps the account.
  ('card_mappings', 'account_id', 'stays_with_owner'),
  ('household_accounts', 'account_id', 'share_ended');

alter table public.fork_handled_columns enable row level security;

-- Same posture as `deletion_handled_columns`: readable, never writable from
-- outside a migration.
create policy fork_handled_columns_select on public.fork_handled_columns
  for select to authenticated
  using (true);

grant select on public.fork_handled_columns to authenticated, service_role;

create function public.unregistered_account_references()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select string_agg(q.table_name || '.' || q.column_name, ', ' order by q.table_name, q.column_name)
  from (
    select cl.relname::text as table_name, att.attname::text as column_name
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class cl on cl.oid = con.conrelid
    join pg_catalog.pg_namespace ns on ns.oid = cl.relnamespace
    join unnest(con.conkey, con.confkey) as k(attnum, ref_attnum) on true
    join pg_catalog.pg_attribute att on att.attrelid = con.conrelid and att.attnum = k.attnum
    join pg_catalog.pg_attribute ref on ref.attrelid = con.confrelid and ref.attnum = k.ref_attnum
    where con.contype = 'f' and con.confrelid = 'public.accounts'::regclass
      and ref.attname = 'id' and ns.nspname = 'public'

    union

    select c.table_name::text, c.column_name::text
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and t.table_type = 'BASE TABLE'
      and c.column_name ~ '(^|_)account_id$'
  ) q
  where not exists (
    select 1 from public.fork_handled_columns f
    where f.table_name = q.table_name and f.column_name = q.column_name
  );
$$;

revoke all on function public.unregistered_account_references() from public, anon, authenticated;

-- ============================================================================
-- Helpers
-- ============================================================================

-- The id of a row's copy in one fork.
create function public.fork_copy_id(p_fork uuid, p_original uuid)
returns uuid
language sql
immutable
strict
set search_path = ''
as $$
  select md5(p_fork::text || p_original::text)::uuid;
$$;

revoke all on function public.fork_copy_id(uuid, uuid) from public, anon, authenticated;

-- The owner's tag with this tag's name, created when they have none.
create function public.fork_tag_id(p_owner uuid, p_tag_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_result uuid;
begin
  select btrim(name) into v_name from public.tags where id = p_tag_id;

  select id into v_result from public.tags
  where owner_id = p_owner and deleted_at is null and lower(btrim(name)) = lower(v_name);

  if v_result is null then
    insert into public.tags (owner_id, name) values (p_owner, v_name) returning id into v_result;
  end if;

  return v_result;
end;
$$;

revoke all on function public.fork_tag_id(uuid, uuid) from public, anon, authenticated;

-- A transfer half stops being a transfer. See the header.
create function public.detach_transfer_leg(p_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.transactions t
  set transfer_group_id = null,
      source = 'adjustment',
      category_id = (
        select c.id from public.categories c
        where c.owner_id = t.owner_id and c.is_default and c.deleted_at is null
          and c.kind = case when t.amount_e4 < 0 then 'expense'::public.category_kind
                            else 'income'::public.category_kind end
        limit 1
      )
  where t.id = p_id and t.transfer_group_id is not null;
$$;

revoke all on function public.detach_transfer_leg(uuid) from public, anon, authenticated;

-- An account's opening as seen from a start date: its own opening for full
-- history, else the balance carried into that moment, dated on the owner's
-- calendar day it began.
create function public.opening_seen_from(p_account_id uuid, p_history_from timestamptz)
returns table (opening_balance_e4 bigint, opening_balance_at date)
language sql
stable
security definer
set search_path = ''
as $$
  select
    case when p_history_from is null then a.opening_balance_e4
         else public.account_balance_through(a.id, p_history_from - interval '1 microsecond') end,
    case when p_history_from is null then a.opening_balance_at
         else (p_history_from at time zone coalesce(public.safe_time_zone(p.time_zone), 'UTC'))::date end
  from public.accounts a
  join public.profiles p on p.id = a.owner_id
  where a.id = p_account_id;
$$;

revoke all on function public.opening_seen_from(uuid, timestamptz) from public, anon, authenticated;

-- Restated from 20261010100000 on top of `opening_seen_from`.
create or replace function public.account_opening_as_seen(p_account_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select to_jsonb(o)
    from public.accounts a
    join public.household_accounts ha
      on ha.account_id = a.id and ha.deleted_at is null and ha.history_from is not null
    cross join lateral public.opening_seen_from(a.id, ha.history_from) o
    where a.id = p_account_id
      and a.owner_id <> (select auth.uid())
      and public.can_read_account(a.id)
  ), '{}'::jsonb);
$$;

-- Links on rows (transactions and recurring rules) on these accounts — every
-- account when null — to a tag owned by p_tag_owner — anyone but the row's
-- owner when null — are swapped for the row owner's own tag of the same name.
-- The old link is soft-deleted, so the owner's phone hears it went.
create function public.swap_in_own_tags(p_account_ids uuid[], p_tag_owner uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.transaction_tags as existing (transaction_id, tag_id)
  select distinct tt.transaction_id, public.fork_tag_id(t.owner_id, tt.tag_id)
  from public.transaction_tags tt
  join public.transactions t on t.id = tt.transaction_id
  join public.tags g on g.id = tt.tag_id and g.owner_id <> t.owner_id
  where tt.deleted_at is null
    and (p_tag_owner is null or g.owner_id = p_tag_owner)
    and (p_account_ids is null or t.account_id = any(p_account_ids))
  on conflict (transaction_id, tag_id) do update set deleted_at = null
  where existing.deleted_at is not null;

  update public.transaction_tags tt
  set deleted_at = now()
  from public.transactions t, public.tags g
  where t.id = tt.transaction_id and g.id = tt.tag_id and g.owner_id <> t.owner_id
    and tt.deleted_at is null
    and (p_tag_owner is null or g.owner_id = p_tag_owner)
    and (p_account_ids is null or t.account_id = any(p_account_ids));

  insert into public.recurring_rule_tags as existing (recurring_rule_id, tag_id)
  select distinct rt.recurring_rule_id, public.fork_tag_id(r.owner_id, rt.tag_id)
  from public.recurring_rule_tags rt
  join public.recurring_rules r on r.id = rt.recurring_rule_id
  join public.tags g on g.id = rt.tag_id and g.owner_id <> r.owner_id
  where rt.deleted_at is null
    and (p_tag_owner is null or g.owner_id = p_tag_owner)
    and (p_account_ids is null or r.account_id = any(p_account_ids) or r.to_account_id = any(p_account_ids))
  on conflict (recurring_rule_id, tag_id) do update set deleted_at = null
  where existing.deleted_at is not null;

  update public.recurring_rule_tags rt
  set deleted_at = now()
  from public.recurring_rules r, public.tags g
  where r.id = rt.recurring_rule_id and g.id = rt.tag_id and g.owner_id <> r.owner_id
    and rt.deleted_at is null
    and (p_tag_owner is null or g.owner_id = p_tag_owner)
    and (p_account_ids is null or r.account_id = any(p_account_ids) or r.to_account_id = any(p_account_ids));
end;
$$;

revoke all on function public.swap_in_own_tags(uuid[], uuid) from public, anon, authenticated;

-- Who is handed a copy of which account when these shares end: the live
-- member who is not the owner, for every live account.
create function public.fork_recipients(p_account_ids uuid[])
returns table (account_id uuid, member_id uuid, history_from timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select ha.account_id, hm.user_id, ha.history_from
  from public.household_accounts ha
  join public.accounts a on a.id = ha.account_id and a.deleted_at is null
  join public.household_members hm
    on hm.household_id = ha.household_id and hm.deleted_at is null and hm.user_id <> a.owner_id
  where ha.account_id = any(p_account_ids) and ha.deleted_at is null;
$$;

revoke all on function public.fork_recipients(uuid[]) from public, anon, authenticated;

-- The transactions each recipient is handed: what they could see, confirmed
-- and live.
create function public.fork_copied_transactions(p_fork uuid, p_account_ids uuid[])
returns table (original_id uuid, copy_id uuid, member_id uuid, copy_account_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, public.fork_copy_id(p_fork, t.id), r.member_id, public.fork_copy_id(p_fork, r.account_id)
  from public.fork_recipients(p_account_ids) r
  join public.transactions t on t.account_id = r.account_id
  where t.deleted_at is null and t.status = 'confirmed'
    and public.transaction_visible_to(r.member_id, t.account_id, t.occurred_at);
$$;

revoke all on function public.fork_copied_transactions(uuid, uuid[]) from public, anon, authenticated;

-- How every half of a touched pair comes out: `new_group` is the pair it
-- joins, or null when it is detached. See the header.
create function public.fork_transfer_plan(p_fork uuid, p_account_ids uuid[])
returns table (leg_id uuid, new_group uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with legs as (
    -- Every live half of a pair touching these accounts stays with its owner...
    select t.id as leg_id, false as copied, t.owner_id as person, t.transfer_group_id as group_id, t.amount_e4
    from public.transactions t
    where t.deleted_at is null
      and t.transfer_group_id in (
        select x.transfer_group_id from public.transactions x
        where x.account_id = any(p_account_ids) and x.deleted_at is null
      )

    union all

    -- ...and a recipient is handed a copy of each half they could see.
    select c.copy_id, true, c.member_id, t.transfer_group_id, t.amount_e4
    from public.fork_copied_transactions(p_fork, p_account_ids) c
    join public.transactions t on t.id = c.original_id
    where t.transfer_group_id is not null
  )
  select
    leg_id,
    case when count(*) over held = 2 then
      first_value(case when copied then leg_id else group_id end) over (held order by amount_e4)
    end
  from legs
  window held as (partition by group_id, person);
$$;

revoke all on function public.fork_transfer_plan(uuid, uuid[]) from public, anon, authenticated;

-- ============================================================================
-- The fork
-- ============================================================================

create function public.fork_accounts(p_account_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fork uuid := gen_random_uuid();
  v_unregistered text := public.unregistered_account_references();
  v_legs jsonb;
begin
  -- Before anything is copied. A reference to an account this function does
  -- not know about would be left pointing at an account its row's owner can
  -- no longer see.
  if v_unregistered is not null then
    raise exception 'fork_accounts: unregistered account reference(s): %', v_unregistered;
  end if;

  -- Decided before anything moves: the plan reads the pairs as they are.
  select coalesce(jsonb_agg(p), '[]'::jsonb) into v_legs
  from public.fork_transfer_plan(v_fork, p_account_ids) p;

  -- The account, as the recipient saw it.
  insert into public.accounts (
    id, owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, archived_at, icon, color
  )
  select public.fork_copy_id(v_fork, a.id), r.member_id, r.member_id, a.kind, a.name, a.currency,
         o.opening_balance_e4, o.opening_balance_at, a.include_in_total, a.archived_at, a.icon, a.color
  from public.fork_recipients(p_account_ids) r
  join public.accounts a on a.id = r.account_id
  cross join lateral public.opening_seen_from(a.id, r.history_from) o;

  -- Its recurring rules, paused; a transfer rule only when both ends are handed
  -- to the same member.
  insert into public.recurring_rules (
    id, created_by, account_id, category_id, to_account_id,
    amount_e4, currency, title, notes, frequency, next_due_at, last_materialized_at, active
  )
  select public.fork_copy_id(v_fork, rr.id), rr.created_by, public.fork_copy_id(v_fork, rr.account_id),
         public.fork_category_id(r.member_id, rr.category_id), public.fork_copy_id(v_fork, rr.to_account_id),
         rr.amount_e4, rr.currency, rr.title, rr.notes, rr.frequency, rr.next_due_at, rr.last_materialized_at,
         false
  from public.fork_recipients(p_account_ids) r
  join public.recurring_rules rr on rr.account_id = r.account_id
  where rr.to_account_id is null
     or rr.to_account_id in (
       select other.account_id from public.fork_recipients(p_account_ids) other
       where other.member_id = r.member_id
     );

  insert into public.recurring_rule_tags (recurring_rule_id, tag_id)
  select distinct c.id, public.fork_tag_id(c.owner_id, rt.tag_id)
  from public.fork_recipients(p_account_ids) r
  join public.recurring_rules rr on rr.account_id = r.account_id
  join public.recurring_rules c on c.id = public.fork_copy_id(v_fork, rr.id)
  join public.recurring_rule_tags rt on rt.recurring_rule_id = rr.id and rt.deleted_at is null
  on conflict do nothing;

  -- The transactions they could see. A lone transfer half is its own pair
  -- until it is detached below.
  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, title, notes, original_amount_e4, original_currency,
    source, status, recurring_rule_id, transfer_group_id
  )
  select c.copy_id, c.member_id, t.created_by, c.copy_account_id,
         public.fork_category_id(c.member_id, t.category_id),
         t.amount_e4, t.currency, t.occurred_at,
         t.merchant_raw, t.merchant_normalized, t.title, t.notes, t.original_amount_e4, t.original_currency,
         t.source, t.status,
         (select rc.id from public.recurring_rules rc where rc.id = public.fork_copy_id(v_fork, t.recurring_rule_id)),
         case when t.transfer_group_id is not null then coalesce(l.new_group, c.copy_id) end
  from public.fork_copied_transactions(v_fork, p_account_ids) c
  join public.transactions t on t.id = c.original_id
  left join jsonb_to_recordset(v_legs) as l(leg_id uuid, new_group uuid) on l.leg_id = c.copy_id;

  insert into public.transaction_tags (transaction_id, tag_id)
  select distinct c.copy_id, public.fork_tag_id(c.member_id, tt.tag_id)
  from public.fork_copied_transactions(v_fork, p_account_ids) c
  join public.transaction_tags tt on tt.transaction_id = c.original_id and tt.deleted_at is null
  on conflict do nothing;

  -- Pairs rebuilt per person: two halves are one pair, a lone half is detached.
  update public.transactions t
  set transfer_group_id = l.new_group
  from jsonb_to_recordset(v_legs) as l(leg_id uuid, new_group uuid)
  where t.id = l.leg_id and l.new_group is not null and t.transfer_group_id <> l.new_group;

  perform public.detach_transfer_leg(l.leg_id)
  from jsonb_to_recordset(v_legs) as l(leg_id uuid, new_group uuid)
  where l.new_group is null;

  -- The owner's rows stop wearing tags that were never theirs.
  perform public.swap_in_own_tags(p_account_ids, null);

  update public.household_accounts set deleted_at = now()
  where account_id = any(p_account_ids) and deleted_at is null;
end;
$$;

revoke all on function public.fork_accounts(uuid[]) from public, anon, authenticated;

drop function public.fork_one_account(uuid, uuid, uuid);
drop function public.fork_household_accounts(uuid, uuid, uuid);

create function public.fork_household_accounts(p_household_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.fork_accounts(array(
    select account_id from public.household_accounts
    where household_id = p_household_id and deleted_at is null
  ));
end;
$$;

revoke all on function public.fork_household_accounts(uuid) from public, anon, authenticated;

-- ============================================================================
-- The callers
-- ============================================================================

-- Restated from 20260816100000: the fork is `fork_accounts`, for any
-- household, and only the member losing access re-pulls.
create or replace function public.unshare_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_household_id uuid;
  v_other uuid;
begin
  select owner_id into v_owner from public.accounts where id = p_account_id and deleted_at is null;
  if v_owner is null or v_owner <> (select auth.uid()) then
    raise exception 'account not found or not owned by you';
  end if;

  select ha.household_id into v_household_id
  from public.household_accounts ha
  join public.household_members hm on hm.household_id = ha.household_id
  where ha.account_id = p_account_id and hm.user_id = (select auth.uid())
    and ha.deleted_at is null and hm.deleted_at is null
  limit 1;

  if v_household_id is null then
    return;
  end if;

  select user_id into v_other from public.household_members
  where household_id = v_household_id and user_id <> (select auth.uid()) and deleted_at is null;

  -- The owner keeps the account; the other member is handed a copy of what
  -- they could see (LH4/LH12). Only THEIR epoch moves: the owner's domain and
  -- cursor are unaffected, they never lost anything.
  perform public.fork_accounts(array[p_account_id]);

  if v_other is not null then
    update public.profiles set sync_epoch = sync_epoch + 1 where id = v_other;
  end if;
end;
$$;

-- Restated from 20260915100000: every share ends, whether or not the other
-- member is still there.
create or replace function public.leave_household()
returns void
language plpgsql
security definer
set search_path = ''
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

  perform public.fork_household_accounts(v_household_id);

  -- **Both** memberships, not just the caller's. A household is two people by
  -- definition; one of them walking out does not leave the other in a
  -- household of one, it ends the household. Leaving the other member behind
  -- in a single-member household was the old behaviour, and on two real
  -- phones it read as a bug: the person who stayed was never told anything,
  -- and their Household screen went on showing a partner who had gone.
  --
  -- The fork above has already left each of them their own accounts and
  -- handed them a copy of what they could see of the other's, so nothing
  -- either could see is lost.
  update public.household_members set deleted_at = now()
  where household_id = v_household_id and deleted_at is null;

  perform public.unlink_shared_categories(v_me);
  if v_other is not null then
    perform public.unlink_shared_categories(v_other);
  end if;

  -- Both epochs, so the other member's device re-pulls and discovers the
  -- household is gone rather than rendering one that no longer exists.
  update public.profiles set sync_epoch = sync_epoch + 1
  where id = v_me or (v_other is not null and id = v_other);

  insert into public.household_events (household_id, actor_id, kind)
  values (v_household_id, v_me, 'member_left')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);
end;
$$;

-- Restated from 20260925100000: the new fork, and the remaining member's
-- epoch.
create or replace function public.erase_own_account()
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

    perform public.fork_household_accounts(v_household_id);

    update public.household_members set deleted_at = now()
    where household_id = v_household_id and user_id = v_me and deleted_at is null;

    perform public.unlink_shared_categories(v_me);

    -- Stays inside this branch on purpose. The epoch exists to force a
    -- device whose sync *domain* changed to wipe and re-pull from zero
    -- (app-architecture.md LH2/LH3, and 20260827100000's S-06 note):
    -- leaving a household moves the caller out of the household's ticket
    -- sequence and back into their own, so every cached cursor is
    -- denominated in a counter that no longer applies. A caller with no
    -- household changes no domain, and the scrubs below carry themselves
    -- through the ordinary pull via each table's stamp_sync_seq trigger.
    -- Bumping unconditionally would hand every solo erase a full
    -- wipe-and-re-pull to deliver two UPDATEs that were already on their
    -- way. Checked, and left exactly as it was.
    --
    -- The member who stays re-pulls too (20261012100000): they just lost
    -- access to the caller's accounts, exactly like an unshare's partner, and
    -- nothing in an ordinary pull tells a phone that a row became unreadable.
    update public.profiles set sync_epoch = sync_epoch + 1
    where id = v_me or (v_other is not null and id = v_other);

    insert into public.household_events (household_id, actor_id, kind)
    values (v_household_id, v_me, 'member_erased')
    returning id into v_event_id;

    perform public.notify_household(v_event_id);
  end if;

  -- The card token belongs here as much as the merchant does. See 20260925100000.
  update public.transactions
  set merchant_raw = null, merchant_normalized = null, card_identifier = null
  where owner_id = v_me
    and (merchant_raw is not null or merchant_normalized is not null or card_identifier is not null);

  -- One scrubbed value per row, unique by construction. See 20260924100000.
  update public.card_mappings set card_identifier = 'erased:' || id::text
  where owner_id = v_me;
end;
$$;

-- Restated from 20260930100000: what the user leaves on other people's rows
-- is settled before the hard delete, and net_worth_daily is gone.
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_household_id uuid;
  v_unregistered text;
begin
  if v_me is null then
    raise exception 'delete_own_account: no authenticated user';
  end if;

  -- Before anything is destroyed. A table added since this function was
  -- written, carrying the user's id and not accounted for here, is a row that
  -- would either survive the erasure or refuse the auth delete — and the
  -- moment to find out is while everything is still intact.
  v_unregistered := public.unregistered_identity_columns();
  if v_unregistered is not null then
    raise exception 'delete_own_account: unregistered identity column(s): %', v_unregistered;
  end if;

  -- Read before `erase_own_account` removes the membership that answers it.
  v_household_id := public.my_household_id();

  -- The fork, the departure, the notification, and the free-text scrub — all
  -- of it already exists and is already tested (18_household_lifecycle.sql).
  -- Deletion is erasure plus destruction, so it starts by erasing.
  perform public.erase_own_account();

  -- **The step without which the auth delete is simply refused.** After the
  -- fork the other member owns fresh copies of the shared history, and every
  -- one of them still records this user as its creator. `created_by` is
  -- provenance, not ownership, so pointing it at the row's own owner keeps
  -- the row truthful about who has it and silent about who first typed it.
  update public.transactions set created_by = owner_id where created_by = v_me and owner_id <> v_me;
  update public.accounts set created_by = owner_id where created_by = v_me and owner_id <> v_me;
  update public.recurring_rules set created_by = owner_id where created_by = v_me and owner_id <> v_me;

  -- The same, for what this user left on other people's rows (#1). The fork
  -- settles everything a live household shared; this catches what older
  -- forks left behind. A transfer half whose other half is this user's would
  -- be left alone and refused at commit, so it is detached; a tag of this
  -- user's on someone else's row becomes that person's own tag.
  perform public.detach_transfer_leg(t.id)
  from public.transactions t
  where t.owner_id <> v_me and t.deleted_at is null
    and t.transfer_group_id in (
      select x.transfer_group_id from public.transactions x where x.owner_id = v_me
    );
  perform public.swap_in_own_tags(null, v_me);

  -- The event stays, the person goes. See the ALTER above.
  update public.household_events set actor_id = null where actor_id = v_me;

  -- An invitation from an account that no longer exists cannot be accepted.
  delete from public.household_invites where invited_by = v_me;

  -- `erase_own_account` soft-deletes this, so a rejoin can reactivate the
  -- same row. There is no rejoining from here, and a soft-deleted row holds
  -- the foreign key just as firmly as a live one.
  delete from public.household_members where user_id = v_me;

  -- A household with nobody in it is not a household. Soft-deleted rather
  -- than dropped so the remaining member's next pull sees a tombstone instead
  -- of a row that silently vanished — the same reasoning as a departure.
  if v_household_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and deleted_at is null
  ) then
    update public.households set deleted_at = now()
    where id = v_household_id and deleted_at is null;
  end if;

  -- Children first, all the way down. Each line is here because something
  -- below it has a foreign key pointing at it. A tag link is someone else's
  -- row when it sits on their transaction or rule, but a tombstone still
  -- pointing at one of this user's tags holds that tag's foreign key.
  delete from public.export_audit_log where owner_id = v_me;
  delete from public.merchant_category_map where owner_id = v_me;
  delete from public.card_mappings where owner_id = v_me;
  delete from public.recurring_rule_tags
  where owner_id = v_me or tag_id in (select id from public.tags where owner_id = v_me);
  delete from public.transaction_tags
  where owner_id = v_me or tag_id in (select id from public.tags where owner_id = v_me);
  delete from public.tags where owner_id = v_me;
  delete from public.recurring_rules where owner_id = v_me;
  delete from public.sync_conflicts where owner_id = v_me;
  delete from public.household_accounts
  where account_id in (select id from public.accounts where owner_id = v_me);
  delete from public.transactions where owner_id = v_me;
  delete from public.accounts where owner_id = v_me;
  delete from public.categories where owner_id = v_me;

  -- Not a uuid and not a foreign key — the user's id as `text`, which nothing
  -- in the database would ever have cleaned up on its own.
  delete from public.ops_rate_limits where subject = v_me::text;

  delete from public.profiles where id = v_me;
end;
$$;
