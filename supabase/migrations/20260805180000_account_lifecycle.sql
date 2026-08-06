-- Phase 6: account lifecycle. Accounts got `version` + a bump trigger back
-- in Phase 2 (retrofitted onto accounts alongside transactions) but nothing
-- has ever read or checked it on write — the exact gap transactions closed
-- in Phase 3 ("RLS can't restrict which columns an UPDATE touches") was
-- never closed for accounts. This migration is where that happens: every
-- account edit, archive, and delete now goes through a vetted SECURITY
-- DEFINER RPC instead of a raw client PATCH, and the raw UPDATE grant is
-- revoked, mirroring migration 003's design exactly.

-- ============================================================================
-- Close the RLS gap: revoke the raw UPDATE grant on accounts. From here on,
-- every account mutation (edit, archive/unarchive, or soft-delete) must go
-- through one of the three SECURITY DEFINER functions below, which own
-- exactly which columns can change and enforce the version check a raw
-- PATCH could otherwise bypass. accounts_update's USING/WITH CHECK is left
-- in place (harmless once the grant is gone) rather than dropped, so a
-- future GRANT back to authenticated doesn't silently reopen unrestricted
-- column access — same reasoning as transactions_update in migration 003.
-- ============================================================================

revoke update on accounts from authenticated;

-- ============================================================================
-- update_account — name, subtype, opening_balance, include_in_total,
-- counts_toward_fi. Deliberately NOT editable, by omission from the
-- parameter list rather than a runtime check: currency (the composite FKs
-- from transactions lock a transaction's currency to its account's — an
-- account whose currency moved out from under existing transactions would
-- desync every one of them) and kind (changes which of the two balance
-- formulas applies; subtype's own subtype_matches_kind CHECK already keeps
-- a client from smuggling a kind change in through subtype). No parameter
-- here can be nil from the client, so no `default null` is needed anywhere
-- (Phase 3's PGRST202 lesson doesn't apply — there's nothing optional).
-- ============================================================================

create function update_account(
  p_id uuid,
  p_expected_version integer,
  p_name text,
  p_subtype account_subtype,
  p_opening_balance numeric,
  p_include_in_total boolean,
  p_counts_toward_fi boolean
)
returns table (conflict boolean, account public.accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, owner_id, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner or v_current.deleted_at is not null then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set
    name = p_name,
    subtype = p_subtype,
    opening_balance = p_opening_balance,
    include_in_total = p_include_in_total,
    counts_toward_fi = p_counts_toward_fi
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function update_account(uuid, integer, text, account_subtype, numeric, boolean, boolean) from public;
grant execute on function update_account(uuid, integer, text, account_subtype, numeric, boolean, boolean)
  to authenticated;

-- ============================================================================
-- archive_account — one RPC handles both directions (p_archived = true to
-- archive, false to unarchive), version-checked like every other write RPC
-- in this codebase. Archiving never touches opening_balance or any
-- transaction — an archived account keeps its real balance, it just drops
-- out of default list views and net-worth totals (a later phase's job, via
-- include_in_total/archived_at — this RPC only sets the timestamp).
-- ============================================================================

create function archive_account(p_id uuid, p_expected_version integer, p_archived boolean)
returns table (conflict boolean, account public.accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, owner_id, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner or v_current.deleted_at is not null then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set archived_at = case when p_archived then now() else null end
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function archive_account(uuid, integer, boolean) from public;
grant execute on function archive_account(uuid, integer, boolean) to authenticated;

-- ============================================================================
-- delete_account — refuses (raises, nothing to audit) when non-deleted
-- transactions still reference the account. This is the account-side
-- half of "archive vs. delete": an account with real history is archived,
-- never deleted, so its transactions' account_id never dangles. Same
-- version-checked soft-delete shape as delete_transaction.
-- ============================================================================

create function delete_account(p_id uuid, p_expected_version integer)
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
  select id, version, owner_id, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner or v_current.deleted_at is not null then
    raise exception 'account not found or not accessible';
  end if;

  if exists (select 1 from public.transactions where account_id = p_id and deleted_at is null) then
    raise exception 'account % has existing transactions — archive it instead of deleting', p_id;
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

  return query select false;
end;
$$;

revoke all on function delete_account(uuid, integer) from public;
grant execute on function delete_account(uuid, integer) to authenticated;

-- ============================================================================
-- accounts_with_balances: append version, needed by the client to send
-- p_expected_version back on edit/archive/delete. Appended at the end —
-- CREATE OR REPLACE VIEW can't reorder or insert columns mid-list (Phase 3's
-- finding). Everything else unchanged.
-- ============================================================================

create or replace view accounts_with_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.name,
  a.kind,
  a.subtype,
  a.currency,
  c.minor_unit,
  a.include_in_total,
  a.counts_toward_fi,
  a.archived_at,
  ab.balance,
  abb.base_currency,
  bc.minor_unit as base_minor_unit,
  abb.balance_base,
  abb.has_missing_rate,
  a.version
from accounts a
join account_balances ab on ab.account_id = a.id
join currencies c on c.code = a.currency
join account_balances_base abb on abb.account_id = a.id
left join currencies bc on bc.code = abb.base_currency;

grant select on accounts_with_balances to authenticated, service_role;
