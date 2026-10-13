-- A conflict asks only when there is a choice.
--
-- Reproduced end to end on 2026-10-13 (every case in the Sync Conflict sheet,
-- on the Simulator against the local stack). Three things put a conflict in
-- front of the user that offered no real decision:
--
-- 1. A conflict outlived the thing it was about. Delete the account or the
--    transaction, and its open conflict stayed in the inbox with nothing left
--    to keep. All five conflicts ever recorded on the hosted project were
--    exactly this. A trigger now closes a row's open conflicts the moment the
--    row is deleted, and the ones already orphaned are closed here.
--
-- 2. An account conflict kept no record of what was attempted. The sheet had
--    nothing to compare, said "nothing looks different", and "Keep My Change"
--    could only re-send the archived flag — a rename, a new balance, a type
--    change or a delete was silently lost. Every account write now records
--    its rejected call (`attempted_payload`), as the transaction writes have
--    since 20261008100000, through one helper, `record_account_conflict`.
--    And, as 20261017100000 did for transactions, a write that asks for what
--    the account already holds is that write's success, never a conflict.
--
-- 3. Setting a balance bumped the account's version. set_account_balance
--    touched `accounts.updated_at` after filing its adjustment, which fires
--    bump_version; the phone's write-through files the adjustment and leaves
--    the account alone. So the phone sat one version behind, and the next
--    thing done to that account — rename, archive, delete — conflicted with
--    the user's own previous save. That is the "your version 2 vs. the saved
--    version 3" every hosted conflict showed, seconds before a delete. The
--    balance is computed from transactions and the adjustment syncs on its
--    own; nothing about the account row changes, so nothing is written to it.
--
-- The inbox row (`needs_review`) also stops saying "Sync conflict —
-- transactions / your version 1 vs. the saved version 2": it names the thing
-- and what to do, through `sync_conflict_subject`, which the phone's local
-- query mirrors.

-- ============================================================================
-- 1. A deleted row closes its conflicts
-- ============================================================================

create function public.close_conflicts_of_deleted_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.deleted_at is null and new.deleted_at is not null then
    update public.sync_conflicts
    set resolved_at = now()
    where table_name = tg_table_name and row_id = new.id and resolved_at is null;
  end if;
  return null;
end;
$$;
revoke all on function public.close_conflicts_of_deleted_row() from public, anon, authenticated;

create trigger transactions_close_conflicts_when_deleted
after update of deleted_at on public.transactions
for each row execute function public.close_conflicts_of_deleted_row();

create trigger accounts_close_conflicts_when_deleted
after update of deleted_at on public.accounts
for each row execute function public.close_conflicts_of_deleted_row();

update public.sync_conflicts sc
set resolved_at = now()
where sc.resolved_at is null
  and (
    (sc.table_name = 'transactions'
     and not exists (select 1 from public.transactions t where t.id = sc.row_id and t.deleted_at is null))
    or (sc.table_name = 'accounts'
     and not exists (select 1 from public.accounts a where a.id = sc.row_id and a.deleted_at is null))
  );

-- ============================================================================
-- 2. record_account_conflict
-- ============================================================================

-- The account twin of record_transaction_conflict.
create function public.record_account_conflict(
  p_row_id uuid, p_client_version integer, p_server_version integer, p_attempted jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version, attempted_payload)
  values ('accounts', p_row_id, (select auth.uid()), p_client_version, p_server_version, p_attempted);
$$;
revoke all on function public.record_account_conflict(uuid, integer, integer, jsonb)
  from public, anon, authenticated;

-- ============================================================================
-- update_account
-- ============================================================================

create or replace function public.update_account(
  p_id uuid, p_expected_version integer, p_name text, p_opening_balance_e4 bigint, p_include_in_total boolean,
  p_icon text, p_color text
)
returns table(conflict boolean, account accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.accounts;
  v_result public.accounts;
begin
  select * into v_current from public.accounts where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  -- `p_opening_balance_e4` is ignored: see 20261009100000's header, section 4.
  update public.accounts
  set
    name = p_name,
    include_in_total = p_include_in_total,
    icon = p_icon,
    color = p_color
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    if v_current.name = p_name and v_current.include_in_total = p_include_in_total
       and v_current.icon is not distinct from p_icon and v_current.color is not distinct from p_color then
      return query select false, v_current;
      return;
    end if;

    perform public.record_account_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'update_account', 'name', p_name, 'include_in_total', p_include_in_total,
      'icon', p_icon, 'color', p_color
    ));
    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

-- ============================================================================
-- archive_account
-- ============================================================================

create or replace function public.archive_account(p_id uuid, p_expected_version integer, p_archived boolean)
returns table(conflict boolean, account accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.accounts;
  v_result public.accounts;
begin
  select * into v_current from public.accounts where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set archived_at = case when p_archived then now() else null end
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    if (v_current.archived_at is not null) = p_archived then
      return query select false, v_current;
      return;
    end if;

    perform public.record_account_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'archive_account', 'archived', p_archived
    ));
    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

-- ============================================================================
-- set_account_kind
-- ============================================================================

create or replace function public.set_account_kind(p_id uuid, p_expected_version integer, p_kind public.account_kind)
returns table(conflict boolean, account accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current public.accounts;
  v_result public.accounts;
begin
  select * into v_current from public.accounts where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set kind = p_kind
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    if v_current.kind = p_kind then
      return query select false, v_current;
      return;
    end if;

    perform public.record_account_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'set_account_kind', 'kind', p_kind
    ));
    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

-- ============================================================================
-- delete_account
-- ============================================================================

create or replace function public.delete_account(p_id uuid, p_expected_version integer, p_cascade boolean default false)
returns table(conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_updated integer;
begin
  select id, version, deleted_at, owner_id
  into v_current
  from public.accounts
  where id = p_id;

  -- Already gone: what this delete asked for is true. Only for the owner —
  -- a deleted account is no longer shared, so nobody else can still write it.
  if v_current.id is not null and v_current.deleted_at is not null and v_current.owner_id = v_owner then
    return query select false;
    return;
  end if;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    perform public.record_account_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'delete_account', 'cascade', p_cascade
    ));
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
-- set_account_balance
-- ============================================================================

create or replace function public.set_account_balance(
  p_account_id uuid, p_new_balance_e4 bigint, p_expected_version integer, p_id uuid default null
)
returns table(transaction_id uuid, snapshot_id uuid, conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account record;
  v_current bigint;
  v_gap bigint;
  v_category_id uuid;
  v_id uuid := coalesce(p_id, gen_random_uuid());
  v_txn_id uuid;
  v_owner uuid := (select auth.uid());
begin
  select id, currency, owner_id, version into v_account
  from public.accounts
  where id = p_account_id and deleted_at is null;

  if v_account.id is null or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  -- Idempotency is checked BEFORE the version check, not after: a queued
  -- outbox write retried after a dropped ack must succeed silently even
  -- though the account's version has already moved past what the retry
  -- still claims to expect — it is not a concurrent edit, it is the same
  -- edit arriving twice. Only a v_id genuinely new to this account is
  -- subject to the version check at all.
  select id into v_txn_id from public.transactions where id = v_id;
  if v_txn_id is not null then
    return query select v_txn_id, null::uuid, false;
    return;
  end if;

  v_current := public.account_balance_on(p_account_id, current_date);
  v_gap := p_new_balance_e4 - v_current;

  -- The account already shows the balance asked for: nothing to file, and
  -- nothing to disagree about, whatever version the caller last saw.
  if v_gap = 0 then
    return query select null::uuid, null::uuid, false;
    return;
  end if;

  if v_account.version <> p_expected_version then
    perform public.record_account_conflict(p_account_id, p_expected_version, v_account.version, jsonb_build_object(
      'rpc', 'set_account_balance', 'new_balance_e4', p_new_balance_e4
    ));
    return query select null::uuid, null::uuid, true;
    return;
  end if;

  select id into v_category_id
  from public.categories
  where owner_id = v_account.owner_id
    and kind = case when v_gap > 0 then 'income'::public.category_kind else 'expense'::public.category_kind end
    and is_default and deleted_at is null;

  if v_category_id is null then
    raise exception 'no default category found to file the adjustment under';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source, status
  )
  values (
    v_id, v_account.owner_id, v_owner, p_account_id, v_category_id, v_gap, v_account.currency,
    now(), 'adjustment', 'confirmed'
  )
  returning id into v_txn_id;

  -- No write to the account row: see this migration's header, section 3.

  return query select v_txn_id, null::uuid, false;
end;
$$;

-- ============================================================================
-- The inbox row says what changed and what to do
-- ============================================================================

-- What a conflict is about, in the words the rest of the app uses for it: a
-- transaction's title, else its merchant, else its category, else "Transfer";
-- an account's name. Mirrored by `LocalMoneyQueries.needsReviewSyncConflicts`.
create function public.sync_conflict_subject(p_table_name text, p_row_id uuid)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select case p_table_name
    when 'accounts' then (select a.name from public.accounts a where a.id = p_row_id)
    when 'transactions' then (
      select coalesce(t.title, t.merchant_raw, c.name,
                      case when t.transfer_group_id is not null then 'Transfer' end)
      from public.transactions t
      left join public.categories c on c.id = t.category_id
      where t.id = p_row_id
    )
  end;
$$;
revoke all on function public.sync_conflict_subject(text, uuid) from public, anon;
grant execute on function public.sync_conflict_subject(text, uuid) to authenticated, service_role;

create or replace view public.needs_review
with (security_invoker = true) as
select
  'sync_conflict'::text as kind,
  sc.id as item_id,
  case sc.table_name
    when 'accounts' then sc.row_id
    when 'transactions' then (select t.account_id from public.transactions t where t.id = sc.row_id)
    else null::uuid
  end as account_id,
  sc.created_at as occurred_at,
  'Sync Conflict'::text as title,
  coalesce(public.sync_conflict_subject(sc.table_name, sc.row_id) || ' · ', '')
    || 'Choose which version to keep' as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from public.sync_conflicts sc
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
  coalesce(t.currency, t.original_currency) as currency
from public.transactions t
join public.categories c on c.id = t.category_id
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
from public.card_mappings cm
where cm.account_id is null and cm.deleted_at is null
  and not exists (
    select 1 from public.transactions t2
    where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
      and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
  );
