-- "caller is not a member of this account's household" — leaving a household
-- could fail, and the raise took the whole leave down with it.
--
-- ============================================================================
-- The defect
-- ============================================================================
--
-- `fork_one_account` opened by re-deriving the household from the account:
--
--     select ha.household_id into v_household_id
--     from public.household_accounts ha
--     where ha.account_id = p_old_account_id and ha.deleted_at is null;
--
-- and then asserted the caller is a member of whatever came back. Two things
-- are wrong, and they compound:
--
--   1. **It re-derives what its caller already knew.**
--      `fork_household_accounts` selected this very account *from* a named
--      household and threw that name away. `unshare_account`, the other
--      caller, gets it right — it joins `household_members` and uses
--      `limit 1` — then hands off here, where the good answer is discarded
--      and a worse one computed.
--   2. **Neither side of the lookup is single-valued.**
--      `household_accounts` is keyed `(household_id, account_id)` and
--      `household_members` is keyed `(household_id, user_id)`, so nothing has
--      ever stopped one account from living in two households, or one user
--      from belonging to two. `select ... into` over several rows does not
--      raise in plpgsql: it takes an arbitrary one. Pick the wrong household
--      and the membership check fails on a caller who *is* a member of the
--      household actually being forked — and the user is told they are not a
--      member of their own household and cannot leave it.
--
-- ============================================================================
-- Why indexes and not just a scoped lookup
-- ============================================================================
--
-- Both invariants are already relied on everywhere. `my_household_id()` takes
-- one row with no ordering, and `create_household`/`accept_invite` both guard
-- on it being null — so "a user is in at most one household" is assumed by
-- every door into the feature. An account has one owner and can only be
-- shared into that owner's household, so "an account is in at most one
-- household" is assumed by `can_read_account`, `unshare_account` and the fork.
--
-- Neither was ever written down, so the schema permitted a state that every
-- reader of it would misinterpret. Writing them down makes the failure
-- impossible rather than merely handled; the scoped lookup below then stops
-- the function guessing at all.

-- ============================================================================
-- 1. Retire duplicates, then forbid them
--
-- Newest wins: the later row is the one the user last asked for. Soft
-- deletes, not hard — both tables sync, and a hard delete never reaches the
-- other device.
-- ============================================================================

with ranked as (
  select household_id, user_id,
         row_number() over (partition by user_id order by joined_at desc, household_id) as position
  from household_members
  where deleted_at is null
)
update household_members hm
set deleted_at = now()
from ranked r
where hm.household_id = r.household_id and hm.user_id = r.user_id and r.position > 1;

with ranked as (
  select household_id, account_id,
         row_number() over (partition by account_id order by shared_at desc, household_id) as position
  from household_accounts
  where deleted_at is null
)
update household_accounts ha
set deleted_at = now()
from ranked r
where ha.household_id = r.household_id and ha.account_id = r.account_id and r.position > 1;

create unique index household_members_one_household_per_user
  on household_members (user_id)
  where deleted_at is null;

create unique index household_accounts_one_household_per_account
  on household_accounts (account_id)
  where deleted_at is null;

comment on index household_members_one_household_per_user is
  'A user belongs to at most one household. Assumed by my_household_id(), create_household and accept_invite; unenforced until 20260914100000.';

comment on index household_accounts_one_household_per_account is
  'An account is shared into at most one household. Assumed by can_read_account, unshare_account and the fork; unenforced until 20260914100000.';

-- ============================================================================
-- 2. Stop the fork guessing which household it is in
--
-- Restated from `pg_get_functiondef` with **only** the opening lookup
-- changed — 20260911100000's lesson, and it earned its keep here: a
-- from-memory restatement of this body dropped the `recurring_rules` fork and
-- the `net_worth_daily` cleanup, and invented a category resolution that is
-- not what `fork_category_id` does.
--
-- The two checks that follow the lookup are now structurally redundant. They
-- stay: they cost nothing, and a SECURITY DEFINER function that writes
-- accounts should state its own preconditions rather than inherit them from
-- whoever calls it.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid;
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  -- The household is the one containing **both** members being split, which
  -- is what this function is about and what both callers already knew.
  -- Deriving it from the account alone was the bug: nothing constrained that
  -- lookup to one row, and `select ... into` over several does not raise in
  -- plpgsql — it takes an arbitrary one. Picking the wrong household made the
  -- membership check below fail on a caller who *was* a member of the
  -- household actually being forked, and the raise took the whole
  -- `leave_household` transaction down with it.
  select ha.household_id into v_household_id
  from public.household_accounts ha
  join public.household_members hm_a
    on hm_a.household_id = ha.household_id
   and hm_a.user_id = p_member_a
   and hm_a.deleted_at is null
  join public.household_members hm_b
    on hm_b.household_id = ha.household_id
   and hm_b.user_id = p_member_b
   and hm_b.deleted_at is null
  where ha.account_id = p_old_account_id and ha.deleted_at is null
  limit 1;

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
$function$;

revoke all on function fork_one_account(uuid, uuid, uuid) from public;
