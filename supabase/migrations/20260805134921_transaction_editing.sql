-- Phase 3: transaction editing with optimistic concurrency. Deferred from
-- Phase 2, whose own migration comment named this moment: the `version`
-- columns and bump_version() trigger have existed since Phase 2 but nothing
-- has ever read or checked them on write. This migration is where that
-- machinery gets used, and where the RLS gap the Phase 2 comment flagged
-- gets closed: "RLS can't restrict which columns an UPDATE touches" — so
-- every transaction write (edit AND delete) now goes through a vetted
-- SECURITY DEFINER RPC instead of a raw client PATCH, and the raw UPDATE
-- grant is revoked.

-- ============================================================================
-- sync_conflicts — populated by the RPCs below whenever a client's expected
-- version doesn't match the row's current version. Per app-architecture.md
-- §3; built now because this phase is what actually writes to it. Nothing
-- reads it yet (needs_review lands with capture/household work), but it's
-- the record of "what happened," independent of whether anything surfaces
-- it in the UI today.
-- ============================================================================

create table sync_conflicts (
  id uuid primary key default gen_random_uuid(),
  table_name text not null,
  row_id uuid not null,
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  client_version integer not null,
  server_version integer not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

alter table sync_conflicts enable row level security;

create policy sync_conflicts_select on sync_conflicts
  for select to authenticated
  using (owner_id = (select auth.uid()));

-- No insert/update grant to authenticated — rows are written only by the
-- SECURITY DEFINER functions below, running as postgres.
grant select on sync_conflicts to authenticated, service_role;

-- ============================================================================
-- Close the RLS gap: revoke the raw UPDATE grant on transactions. From here
-- on, every transaction mutation (edit or soft-delete) must go through one
-- of the four SECURITY DEFINER functions below, which own exactly which
-- columns can change and enforce the version check a raw PATCH could
-- otherwise bypass. transactions_update's USING/WITH CHECK is left in place
-- (harmless once the grant is gone) rather than dropped, so a future GRANT
-- back to authenticated — should one ever be needed — doesn't silently
-- reopen unrestricted column access.
-- ============================================================================

revoke update on transactions from authenticated;

-- ============================================================================
-- Conflicts are reported as data, not exceptions. The first version of this
-- migration logged a sync_conflicts row and then RAISE EXCEPTIONed — found
-- wrong while writing the SQL tests below: a raised exception aborts the
-- entire statement, and an RPC call from the client *is* one top-level
-- statement, so the "audit" insert was rolled back along with everything
-- else every single time, without dblink/pg_background-style autonomous
-- transactions (not used anywhere else in this codebase, not worth
-- introducing for this). A conflict is an expected, structured outcome —
-- not an error — so every write RPC below returns a `conflict` flag in its
-- result instead of throwing, and the sync_conflicts insert commits as part
-- of the same successful, non-erroring transaction. Real errors (not
-- found, not accessible, wrong leg type) still raise — there is nothing to
-- audit for those.
-- ============================================================================

-- ============================================================================
-- update_transaction — ledger-only (expense/income). A transfer's kind is
-- locked once it exists (app-architecture.md §2: changing kind is
-- delete-and-recreate, not an in-place mutation), and a transfer's two legs
-- must move together, so transfers go through update_transfer below
-- instead. SECURITY DEFINER so it can own field whitelisting independent of
-- the (now grant-less) transactions_update RLS policy; re-implements the
-- ownership check can_write_account would do, since DEFINER bypasses RLS.
-- ============================================================================

create function update_transaction(
  p_id uuid,
  p_expected_version integer,
  p_account_id uuid,
  p_category_id uuid,
  p_amount numeric,
  p_currency text,
  p_occurred_at timestamptz,
  p_merchant_raw text default null
)
returns table (conflict boolean, transaction public.transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
begin
  select id, version, owner_id, transfer_group_id, deleted_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if not exists (
    select 1 from public.accounts where id = p_account_id and owner_id = v_owner and deleted_at is null
  ) then
    raise exception 'account not found or not accessible';
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount = p_amount,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.transactions;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function update_transaction(uuid, integer, uuid, uuid, numeric, text, timestamptz, text) from public;
grant execute on function update_transaction(uuid, integer, uuid, uuid, numeric, text, timestamptz, text) to authenticated;

-- ============================================================================
-- update_transfer — updates both legs' amount/occurred_at atomically (one
-- function call is one transaction), each guarded by its own expected
-- version. Account and currency are not editable here: a transfer's legs
-- and their accounts are locked, same as kind (app-architecture.md §2) —
-- only amount and date can change. Signs follow create_transfer's
-- convention: the "from" leg stays negative, the "to" leg stays positive.
-- If either leg's version is stale, no update is applied to either leg —
-- both are logged to sync_conflicts and one conflict=true row is returned,
-- so the caller can't end up with one leg updated and the other not.
-- ============================================================================

create function update_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer,
  p_from_amount numeric,
  p_to_amount numeric,
  p_occurred_at timestamptz
)
returns table (conflict boolean, transaction public.transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
begin
  if p_from_amount is null or p_from_amount <= 0 or p_to_amount is null or p_to_amount <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

  select id, version, owner_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount < 0;

  select id, version, owner_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount > 0;

  if v_from.id is null or v_to.id is null or v_from.owner_id <> v_owner or v_to.owner_id <> v_owner then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true, null::public.transactions;
    return;
  end if;

  update public.transactions set amount = -p_from_amount, occurred_at = p_occurred_at
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set amount = p_to_amount, occurred_at = p_occurred_at
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

revoke all on function update_transfer(uuid, integer, integer, numeric, numeric, timestamptz) from public;
grant execute on function update_transfer(uuid, integer, integer, numeric, numeric, timestamptz) to authenticated;

-- ============================================================================
-- delete_transaction — version-checked soft delete, ledger-only (the raw
-- UPDATE grant this used to run through is gone; a transfer must delete both
-- legs together, see delete_transfer, or check_transfer_integrity's "0 or 2
-- legs" rule rejects the resulting 1-leg group at end of statement).
-- ============================================================================

create function delete_transaction(p_id uuid, p_expected_version integer)
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
  select id, version, owner_id, transfer_group_id, deleted_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use delete_transfer', p_id;
  end if;

  update public.transactions
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true;
    return;
  end if;

  return query select false;
end;
$$;

revoke all on function delete_transaction(uuid, integer) from public;
grant execute on function delete_transaction(uuid, integer) to authenticated;

-- ============================================================================
-- delete_transfer — soft-deletes both legs atomically, version-checked on
-- each. Replaces the old single-row softDelete for transfers, which would
-- otherwise leave a 1-leg group and trip check_transfer_integrity.
-- ============================================================================

create function delete_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer
)
returns table (conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
begin
  select id, version, owner_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount < 0;

  select id, version, owner_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount > 0;

  if v_from.id is null or v_to.id is null or v_from.owner_id <> v_owner or v_to.owner_id <> v_owner then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true;
    return;
  end if;

  update public.transactions set deleted_at = now()
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set deleted_at = now()
  where id = v_to.id and version = p_to_expected_version;

  return query select false;
end;
$$;

revoke all on function delete_transfer(uuid, integer, integer) from public;
grant execute on function delete_transfer(uuid, integer, integer) to authenticated;

-- ============================================================================
-- transactions_with_details: add version, needed by the client to send
-- p_expected_version back on edit/delete. Everything else is unchanged.
-- ============================================================================

create or replace view transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount,
  t.currency,
  cur.minor_unit,
  t.occurred_at,
  t.merchant_raw,
  t.merchant_normalized,
  t.transfer_group_id,
  t.source,
  t.status,
  case
    when t.transfer_group_id is not null then 'transfer'
    when t.amount < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version
from transactions t
join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
join currencies cur on cur.code = t.currency
where t.deleted_at is null;

grant select on transactions_with_details to authenticated, service_role;
