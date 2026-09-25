-- Sharing an account again replaces the old copy.
--
-- User's decision, 2026-09-24, after Phase 4 of the "Transfers & household
-- sharing" workstream (keepo-v1-master-plan.md): when an owner shares an
-- account again, the partner is not asked anything — Keepo finds the copy
-- they were handed when the account last left them and replaces it. The
-- partner only ever sees the latest version of that account.
--
-- Without this, the partner held the copy from the unshare and the shared
-- account side by side, and their Total counted both.
--
-- ============================================================================
-- 1. A copy remembers where it came from
-- ============================================================================
--
-- `accounts.copied_from` is set by `fork_accounts` on every copy it makes.
-- Provenance only: no foreign key, because the account it names belongs to
-- someone else, may be deleted with its owner's Keepo account, and is never
-- read through it. Copies made before this migration have none, so they
-- cannot be told apart from an account the member created, and are left
-- alone.
--
-- ============================================================================
-- 2. Sharing retires the copy
-- ============================================================================
--
-- `share_into_household` — the one way into a household, for
-- `share_account` and both sides of `accept_invite` — deletes every live copy
-- of the account owned by a member of the household it joins, the way
-- `delete_account(p_cascade => true)` deletes an account. That cascade is now
-- `retire_account_contents`, called by both:
--
--   * the copy's transactions go, including anything the member added to it
--     after the unshare — it is the replaced version;
--   * a transfer half on it stays as an anchor while its other half is on a
--     live account (20261007100000), so no pair is broken;
--   * its recurring rules are paused.
--
-- Soft-deleted like any account, so the member's phone hears about it in the
-- ordinary pull.

alter table public.accounts add column copied_from uuid;

comment on column public.accounts.copied_from is
  'The account this one was copied from when a share ended (fork_accounts). Provenance only, never a foreign key; null for every account a person created.';

-- ============================================================================
-- What goes with a deleted account
-- ============================================================================

-- The cascade of `delete_account` (20261007100000), extracted unchanged.
create function public.retire_account_contents(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Everything that is not half of a transfer goes with the account.
  update public.transactions
  set deleted_at = now()
  where account_id = p_id and deleted_at is null and transfer_group_id is null;

  -- A transfer whose other half is on an account that is ALSO deleted has
  -- nothing left to anchor: both halves go, together. Every other transfer
  -- half stays on this account as an anchor — see 20261007100000.
  update public.transactions
  set deleted_at = now()
  where deleted_at is null
    and transfer_group_id in (
      select mine.transfer_group_id
      from public.transactions mine
      join public.transactions other
        on other.transfer_group_id = mine.transfer_group_id
       and other.id <> mine.id
       and other.deleted_at is null
      join public.accounts other_account on other_account.id = other.account_id
      where mine.account_id = p_id
        and mine.deleted_at is null
        and mine.transfer_group_id is not null
        and other_account.deleted_at is not null
    );

  update public.recurring_rules
  set active = false
  where (account_id = p_id or to_account_id = p_id) and active;
end;
$$;

revoke all on function public.retire_account_contents(uuid) from public, anon, authenticated;

-- Restated from 20261007100000 on top of `retire_account_contents`.
create or replace function public.delete_account(
  p_id uuid,
  p_expected_version integer,
  p_cascade boolean default false
)
returns table (conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_updated integer;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true;
    return;
  end if;

  if not p_cascade and exists (
    select 1 from public.transactions where account_id = p_id and deleted_at is null
  ) then
    raise exception 'This account still has transactions, so it cannot be deleted on its own.';
  end if;

  perform public.retire_account_contents(p_id);

  return query select false;
end;
$$;

-- ============================================================================
-- Sharing retires the copy
-- ============================================================================

-- Restated from 20261013100000 with the copy's retirement.
create or replace function public.share_into_household(p_household_id uuid, p_account_id uuid, p_full_history boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_copy uuid;
begin
  insert into public.household_accounts as existing (household_id, account_id, history_from)
  select p_household_id, a.id, case when p_full_history then null else public.share_start(a.owner_id) end
  from public.accounts a
  where a.id = p_account_id
  on conflict (household_id, account_id) do update
  set deleted_at = null,
      shared_at = now(),
      -- An ended share starts afresh; a live one never narrows.
      history_from = case
        when existing.deleted_at is not null then excluded.history_from
        when existing.history_from is null or excluded.history_from is null then null
        else least(existing.history_from, excluded.history_from)
      end;

  perform public.restamp_account_for_sync(p_account_id);

  -- The account is back, so a copy a member was handed when it last left
  -- them goes, the way a deleted account goes. See the header.
  for v_copy in
    update public.accounts c set deleted_at = now()
    from public.household_members hm
    where c.copied_from = p_account_id and c.deleted_at is null
      and hm.household_id = p_household_id and hm.user_id = c.owner_id and hm.deleted_at is null
    returning c.id
  loop
    perform public.retire_account_contents(v_copy);
  end loop;
end;
$$;

-- ============================================================================
-- A copy remembers where it came from
-- ============================================================================

-- Restated from 20261012100000 with `copied_from`.
create or replace function public.fork_accounts(p_account_ids uuid[])
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
    opening_balance_e4, opening_balance_at, include_in_total, archived_at, icon, color, copied_from
  )
  select public.fork_copy_id(v_fork, a.id), r.member_id, r.member_id, a.kind, a.name, a.currency,
         o.opening_balance_e4, o.opening_balance_at, a.include_in_total, a.archived_at, a.icon, a.color, a.id
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
