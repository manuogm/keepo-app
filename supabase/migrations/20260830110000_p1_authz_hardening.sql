-- Wave 2 of the Supabase Advisor remediation (see keepo-security-remediation-plan.md).
-- Defence-in-depth for fork_one_account, plus the four P1 findings: three
-- internal helpers that were reachable by the public despite having no
-- legitimate external caller, and one that takes a caller-supplied owner
-- id with no check it matches the caller.

-- ----------------------------------------------------------------------------
-- fork_one_account: Wave 1 already closed the public's access to this
-- function. This adds the ownership check that should have been in the
-- body from the start, so the function is safe even if some future
-- migration ever re-grants it by accident. Every legitimate call site
-- (unshare_account, fork_household_accounts <- leave_household) already
-- guarantees p_old_account_id is shared within the caller's own household
-- and {p_member_a, p_member_b} is exactly {caller, the other member} — this
-- guard asserts precisely that invariant instead of trusting callers to
-- keep upholding it. Body below is otherwise byte-identical to
-- 20260819100000's definition.
-- ----------------------------------------------------------------------------

create or replace function public.fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
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
    owner_id, created_by, kind, subtype, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_a, p_member_a, kind, subtype, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_a;

  insert into public.accounts (
    owner_id, created_by, kind, subtype, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_b, p_member_b, kind, subtype, name, currency,
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

  insert into public.balance_snapshots (account_id, currency, as_of, value_e4, created_by)
  select fork.fork_account_id, bs.currency, bs.as_of, bs.value_e4, bs.created_by
  from public.balance_snapshots bs
  cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
  where bs.account_id = p_old_account_id;

  insert into public.recurring_rules (created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at, active)
  select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
         rr.amount_e4, rr.currency, rr.frequency, rr.next_due_at, rr.active
  from public.recurring_rules rr
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where rr.account_id = p_old_account_id;

  update public.card_mappings
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  update public.csv_import_batches
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  update public.csv_import_candidates
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  delete from public.net_worth_daily where account_id = p_old_account_id;
  update public.household_accounts set deleted_at = now()
  where account_id = p_old_account_id and deleted_at is null;
  update public.accounts set archived_at = coalesce(archived_at, now()) where id = p_old_account_id;
end;
$$;

-- CREATE OR REPLACE FUNCTION preserves the existing ACL, so Wave 1's revoke
-- survives this replace — reasserted explicitly anyway, matching this
-- repo's own precedent (20260823100000_reassert_card_mapping_grants.sql)
-- of never leaving a security-relevant grant implicit.
revoke all on function public.fork_one_account(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.fork_one_account(uuid, uuid, uuid) to postgres;

-- ----------------------------------------------------------------------------
-- restamp_account_for_sync / next_ticket / sync_domain_id: three internal
-- primitives, each called only by SECURITY DEFINER trigger functions
-- (stamp_sync_seq_*) that run as the database owner regardless of who
-- holds EXECUTE — so revoking the public's access here changes nothing
-- for any real write path, confirmed against every stamp_sync_seq_*
-- definition in 20260816100000_sync_primitives.sql (all six are
-- `security definer`). The app never calls any of the three directly
-- (grepped every `.rpc(...)` call site in App/ and Packages/).
--
-- restamp_account_for_sync(uuid): forces a sync-seq bump across an
-- arbitrary account's rows — public access lets anyone force wasted sync
-- churn on someone else's device.
-- next_ticket(uuid): hands out the ordering counter sync correctness
-- depends on — public access lets anyone corrupt another domain's sync
-- order.
-- sync_domain_id(uuid): discloses whether an arbitrary user id is in a
-- household, and which one — public access is an information leak on its
-- own even before considering the two functions above.
-- ----------------------------------------------------------------------------

revoke all on function public.restamp_account_for_sync(uuid) from public, anon, authenticated;
revoke all on function public.next_ticket(uuid) from public, anon, authenticated;
revoke all on function public.sync_domain_id(uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- resolve_category_for_merchant: unlike the three above, this DOES have a
-- legitimate authenticated caller that runs as the invoker —
-- accept_import_candidate is SECURITY INVOKER and is called directly by
-- the app (CsvImportRepository). A first draft of this guard checked
-- `p_owner = auth.uid()` and would have shipped broken: csv_import_
-- candidates' own RLS policy is `can_write_account(account_id)`, not
-- `owner_id = auth.uid()`, so a household member legitimately accepts an
-- import candidate against an account THE OTHER MEMBER owns — confirmed
-- against the live database (can_write_account returns true for a second
-- household member on the first member's shared account). p_owner =
-- v_candidate.owner_id in that call is genuinely not the caller.
--
-- The guard below instead mirrors can_read_account's own sharing rule,
-- generalized from "one account" to "does the caller share ANY account
-- with p_owner": true when p_owner is the caller, or when the caller is a
-- member of a household that has one of p_owner's accounts shared into
-- it. Both real callers satisfy this — capture_transaction passes
-- auth.uid() directly (the p_owner = caller branch); accept_import_
-- candidate passes the candidate's owner_id, which can_write_account
-- already required to be either the caller or share an account with the
-- caller before this function is ever reached. Anyone probing an
-- unrelated owner_id now gets an unconditional NULL. Select body
-- otherwise byte-identical to 20260814100100's definition (confirmed
-- against the live function via pg_get_functiondef).
-- ----------------------------------------------------------------------------

create or replace function public.resolve_category_for_merchant(p_owner uuid, p_merchant_normalized text, p_kind category_kind)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when
    p_owner = (select auth.uid())
    or exists (
      select 1
      from public.accounts a
      join public.household_accounts ha on ha.account_id = a.id and ha.deleted_at is null
      join public.household_members hm on hm.household_id = ha.household_id
        and hm.user_id = (select auth.uid()) and hm.deleted_at is null
      where a.owner_id = p_owner
    )
  then coalesce(
    (
      select m.category_id
      from public.merchant_category_map m
      join public.categories c on c.id = m.category_id
      where m.owner_id = p_owner and m.merchant_pattern = p_merchant_normalized and c.kind = p_kind
    ),
    (
      select id from public.categories
      where owner_id = p_owner and kind = p_kind and is_default and deleted_at is null
      limit 1
    )
  ) end;
$$;

revoke all on function public.resolve_category_for_merchant(uuid, text, category_kind) from public;
grant execute on function public.resolve_category_for_merchant(uuid, text, category_kind) to authenticated;
