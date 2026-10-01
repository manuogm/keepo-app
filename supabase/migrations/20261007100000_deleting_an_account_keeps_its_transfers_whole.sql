-- Deleting an account keeps its transfers whole.
--
-- ============================================================================
-- 1. delete_account — a transfer half whose partner is live stays, as an anchor
-- ============================================================================
--
-- `delete_account(p_cascade => true)` tombstoned every transaction on the
-- account, transfer halves included, while deliberately leaving the partner
-- half in the other account alone — "money that left this account genuinely
-- arrived in the other", as its own header put it (20260917100000). But a
-- transfer group with one live leg is exactly what `check_transfer_integrity`
-- exists to refuse, so the delete raised at COMMIT ("transfer <uuid> must
-- have exactly 2 legs, found 1") and the user read that sentence, UUID and
-- all, for any archived account that had ever moved money to a live one.
-- The pgTAP case covering it (43 #18) passed only because a deferred trigger
-- never fires inside a test file that rolls back.
--
-- The intent was right and the mechanism contradicted the schema. Rather
-- than turning the survivor into "Other" income or expense — which would
-- retroactively change past months' Cashflow for money that only ever moved
-- between the user's own accounts — the half on the deleted account now
-- **stays**, as an anchor:
--
--   * the pair keeps both legs, so the invariant holds;
--   * every balance and list already ignores rows on a deleted account, so
--     the anchor moves no figure anywhere;
--   * the live account's history keeps reading as a transfer from (or to)
--     the account that was deleted, which is what happened.
--
-- A pair whose accounts are BOTH deleted has nothing left to anchor and is
-- tombstoned whole — both legs, so it goes from two to zero.
--
-- ============================================================================
-- 2. check_transfer_integrity — its own SQLSTATE
-- ============================================================================
--
-- Every RPC here raises a sentence meant for a person with the default
-- SQLSTATE, P0001, and `UserFacingError` shows exactly those verbatim. The
-- integrity trigger used P0001 too, so an invariant violation — a bug, never
-- a user's mistake — reached the screen as raw text with a UUID in it. It now
-- raises `check_violation` (23514), the code a declarative CHECK would have
-- used: the client shows its generic message and logs the real one, and a
-- deterministic refusal is still recognisably one.
--
-- Both functions restated from their last definitions (20260815100000 and
-- 20260927100000), with only the changes above.
-- ============================================================================

create or replace function public.check_transfer_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_leg_count integer;
  v_distinct_accounts integer;
  v_distinct_owners integer;
  v_distinct_currencies integer;
  v_sum bigint;
  v_account_ids uuid[];
begin
  v_group := coalesce(new.transfer_group_id, old.transfer_group_id);
  if v_group is null then
    return null;
  end if;

  select
    count(*), count(distinct account_id), count(distinct owner_id), count(distinct currency), sum(amount_e4),
    array_agg(distinct account_id)
  into v_leg_count, v_distinct_accounts, v_distinct_owners, v_distinct_currencies, v_sum, v_account_ids
  from public.transactions
  where transfer_group_id = v_group and deleted_at is null;

  if v_leg_count not in (0, 2) then
    raise exception 'transfer % must have exactly 2 legs, found %', v_group, v_leg_count
      using errcode = 'check_violation';
  end if;

  if v_leg_count = 2 then
    if v_distinct_accounts <> 2 then
      raise exception 'transfer % legs must reference distinct accounts', v_group
        using errcode = 'check_violation';
    end if;

    if v_distinct_owners <> 1 then
      if not exists (
        select 1
        from public.household_accounts ha1
        join public.household_accounts ha2 on ha1.household_id = ha2.household_id
        where ha1.account_id = v_account_ids[1] and ha2.account_id = v_account_ids[2]
      ) then
        raise exception 'transfer % legs must share one owner or one household', v_group
          using errcode = 'check_violation';
      end if;
    end if;

    if v_distinct_currencies = 1 and v_sum <> 0 then
      raise exception 'transfer % same-currency legs must net to zero', v_group
        using errcode = 'check_violation';
    end if;
  end if;

  return null;
end;
$$;

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

  if exists (select 1 from public.transactions where account_id = p_id and deleted_at is null) then
    if not p_cascade then
      raise exception 'This account still has transactions, so it cannot be deleted on its own.';
    end if;

    -- Everything that is not half of a transfer goes with the account.
    update public.transactions
    set deleted_at = now()
    where account_id = p_id and deleted_at is null and transfer_group_id is null;

    -- A transfer whose other half is on an account that is ALSO deleted has
    -- nothing left to anchor: both halves go, together. Every other transfer
    -- half stays on this account as an anchor — see the header.
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
  end if;

  update public.recurring_rules
  set active = false
  where (account_id = p_id or to_account_id = p_id) and active;

  return query select false;
end;
$$;
