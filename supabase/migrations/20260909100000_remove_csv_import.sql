-- Removes CSV import entirely: the staging tables, the three RPCs, the
-- candidate-status enum, and the `needs_review` branch that surfaced a
-- staged row for review.
--
-- Why it goes: import was the one way into the ledger that asked the user to
-- do bookkeeping. Everything else in Keepo either captures itself (Apple Pay
-- + Shortcuts) or is one form away, and a staging table whose rows have to be
-- accepted one at a time is a second, parallel notion of "a transaction that
-- isn't a transaction yet" living beside pending captures. Export stays —
-- taking your data out is not the same feature as putting a bank's file in.
--
-- **`transaction_source`'s `csv_import` label stays.** Not an oversight: any
-- transaction a user already accepted from an import carries it, and those are
-- real money records. Dropping the label would mean either destroying them or
-- rewriting their provenance to something that never happened. Nothing can
-- produce a new one after this migration; the label is a historical fact about
-- rows that exist, which is exactly what a source column is for.

-- ============================================================================
-- needs_review — three branches now, not four.
--
-- `create or replace` rather than drop/recreate: only a `union all` arm goes,
-- so the column list is unchanged and every dependent grant survives.
-- ============================================================================

create or replace view needs_review
with (security_invoker = true) as
select
  'sync_conflict'::text as kind,
  sc.id as item_id,
  case sc.table_name
    when 'accounts' then sc.row_id
    when 'transactions' then (select t.account_id from transactions t where t.id = sc.row_id)
    else null::uuid
  end as account_id,
  sc.created_at as occurred_at,
  'Sync conflict — ' || sc.table_name as title,
  'your version ' || sc.client_version || ' vs. the saved version ' || sc.server_version as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from sync_conflicts sc
where sc.resolved_at is null
union all
select
  'pending_capture'::text as kind,
  t.id as item_id,
  t.account_id,
  t.occurred_at,
  'Review capture — ' || coalesce(t.merchant_raw, 'Unknown merchant') as title,
  case when c.is_default then 'Other' else 'Suggested: ' || c.name end as subtitle,
  t.amount_e4,
  t.currency
from transactions t
join categories c on c.id = t.category_id
where t.source = 'capture' and t.status = 'pending' and t.deleted_at is null
union all
select
  'ambiguous_card'::text as kind,
  cm.id as item_id,
  null::uuid as account_id,
  cm.created_at as occurred_at,
  'Unmapped card'::text as title,
  cm.card_identifier as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from card_mappings cm
where cm.account_id is null
  and cm.deleted_at is null
  and not exists (
    select 1 from transactions t2
    where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
      and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
  );

grant select on needs_review to authenticated, service_role;

-- ============================================================================
-- The two household functions that carried import rows across a fork.
--
-- Restated in full rather than patched: a plpgsql body is stored as text and
-- has no dependency on the tables it names, so dropping the tables would have
-- left both of these compiling fine and failing at the first call that
-- reached the dead statement.
-- ============================================================================

create or replace function fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_household_id uuid;
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  select ha.household_id into v_household_id
  from public.household_accounts ha
  where ha.account_id = p_old_account_id and ha.deleted_at is null;

  if v_household_id is null then
    raise exception 'account not found or not shared with a household';
  end if;

  if not exists (
    select 1 from public.household_members hm
    where hm.household_id = v_household_id and hm.user_id = (select auth.uid()) and hm.deleted_at is null
  ) then
    raise exception 'caller is not a member of this account''s household';
  end if;

  if (
    select count(*) from public.household_members hm
    where hm.household_id = v_household_id and hm.deleted_at is null
      and hm.user_id in (p_member_a, p_member_b)
  ) <> 2 or p_member_a = p_member_b then
    raise exception 'p_member_a and p_member_b must be the two distinct members of this household';
  end if;

  insert into public.accounts (
    owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_a, p_member_a, kind, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_a;

  insert into public.accounts (
    owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_b, p_member_b, kind, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_b;

  insert into public.transactions (
    owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status
  )
  select
    fork.fork_owner, t.created_by, fork.fork_account_id,
    case
      when t.transfer_group_id is not null then (
        select id from public.categories
        where owner_id = fork.fork_owner
          and kind = case when t.amount_e4 < 0 then 'expense'::public.category_kind else 'income'::public.category_kind end
          and is_default and deleted_at is null
      )
      else public.fork_category_id(fork.fork_owner, t.category_id)
    end,
    t.amount_e4, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
    case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
    t.status
  from public.transactions t
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where t.account_id = p_old_account_id and t.deleted_at is null;

  insert into public.recurring_rules (created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at, active)
  select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
         rr.amount_e4, rr.currency, rr.frequency, rr.next_due_at, rr.active
  from public.recurring_rules rr
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where rr.account_id = p_old_account_id;

  update public.card_mappings
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  delete from public.net_worth_daily where account_id = p_old_account_id;
  update public.household_accounts set deleted_at = now()
  where account_id = p_old_account_id and deleted_at is null;
  update public.accounts set archived_at = coalesce(archived_at, now()) where id = p_old_account_id;
end;
$$;

revoke all on function fork_one_account(uuid, uuid, uuid) from public;

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

revoke all on function erase_own_account() from public;
-- `authenticated` only, matching the grant this function already carries;
-- `create or replace` preserves an ACL, so this is here to state it, not to
-- widen it.
grant execute on function erase_own_account() to authenticated;

-- ============================================================================
-- The feature itself
-- ============================================================================

drop function if exists import_csv_rows(uuid, text, jsonb);
drop function if exists accept_import_candidate(uuid);
drop function if exists reject_import_candidate(uuid);

-- Children first, and `cascade` only for the policies and grants that hang
-- off each table — nothing else references them (they were never synced, so
-- `pull_changes` says nothing about either).
drop table if exists csv_import_candidates cascade;
drop table if exists csv_import_batches cascade;

drop type if exists import_candidate_status;
