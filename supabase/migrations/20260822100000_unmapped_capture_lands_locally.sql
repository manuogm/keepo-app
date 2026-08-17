-- Capture on an unmapped card must land locally exactly like a mapped one —
-- the only real difference is that the account is missing, not that the
-- purchase itself is dropped or forced onto a network-only path. Today
-- `capture_transaction` refuses to insert anything at all when the card
-- isn't mapped, which is what pushed the client's local-first fast path
-- (`CaptureLocalWrite`) to skip straight to a synchronous RPC call whenever
-- it couldn't resolve an account — exactly the network-dependent path the
-- whole local-first design exists to avoid.
--
-- `account_id`/`currency` become nullable on `transactions`, but ONLY ever
-- null for `status = 'pending', source = 'capture'` rows — a `confirmed`
-- row can never have either null, enforced below by two CHECK constraints,
-- not just app-level convention. Every existing money-aggregating query
-- (`account_balances`, `spending_by_category`, `income_expense_series`,
-- `budget_progress`, the FI savings calc) already filters
-- `status = 'confirmed'` before touching `amount_e4`/`account_id`/
-- `currency` — verified by reading each one — so none of them needed to
-- change; the CHECK constraints are what makes that safe by construction
-- rather than by accident.

alter table transactions alter column account_id drop not null;
alter table transactions alter column currency drop not null;

-- Always stored by capture_transaction (not just for the unmapped case —
-- keeping the insert unconditional is simpler than a conditional column),
-- used only to auto-link card_mappings once an account is finally assigned
-- via update_transaction below.
alter table transactions add column card_identifier text;

alter table transactions add constraint confirmed_requires_account
  check (status <> 'confirmed' or account_id is not null);
alter table transactions add constraint confirmed_requires_currency
  check (status <> 'confirmed' or currency is not null);
alter table transactions add constraint account_currency_together
  check ((account_id is null) = (currency is null));

-- The three composite FKs on account_id (accounts(id, owner_id),
-- (id, currency), (id, kind)) are MATCH SIMPLE (default) — already
-- null-safe, trivially satisfied when account_id is null, no change
-- needed. valuation_transfers_only's `account_kind = 'ledger' or
-- transfer_group_id is not null` evaluates to SQL NULL when account_kind
-- is null (set_transaction_derived_columns leaves it null when
-- account_id is null), and a CHECK treats NULL as passing. Both verified
-- by reading the live DDL, not just assumed.

-- transactions_select RLS: can_read_account(null) is false (its body is
-- `exists(select 1 from accounts where id = p_account_id ...)`), which
-- would make a null-account row invisible to its own owner via
-- pull_changes (SECURITY INVOKER) and every security_invoker view. The
-- owner still needs to see their own unresolved capture.
drop policy transactions_select on transactions;
create policy transactions_select on transactions
  for select to authenticated
  using (
    (account_id is not null and can_read_account(account_id))
    or (account_id is null and owner_id = (select auth.uid()))
  );

-- ============================================================================
-- link_card_to_account — the account-validation + card_mappings upsert
-- map_card already did, extracted so update_transaction can reuse the
-- identical guarantee (ledger-kind, active, owned) when a capture review
-- assigns an account to a previously-unmapped card. Not granted to
-- `authenticated` directly — only ever called from other SECURITY DEFINER
-- functions.
-- ============================================================================

create function public.link_card_to_account(p_owner uuid, p_card_identifier text, p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = p_owner and kind = 'ledger'
      and deleted_at is null and archived_at is null
  ) then
    raise exception 'account not found, not accessible, archived, or not a spendable (ledger) account';
  end if;

  insert into public.card_mappings (owner_id, card_identifier, account_id)
  values (p_owner, p_card_identifier, p_account_id)
  on conflict (owner_id, card_identifier) do update set account_id = excluded.account_id, updated_at = now();
end;
$$;

revoke all on function public.link_card_to_account(uuid, text, uuid) from public;

create or replace function public.map_card(p_card_identifier text, p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.link_card_to_account((select auth.uid()), p_card_identifier, p_account_id);
end;
$$;

-- ============================================================================
-- capture_transaction — always inserts now, account_id/currency simply
-- carry whatever the card lookup produced (possibly null). Category
-- resolution never depended on the account, unchanged. Still upserts the
-- card_mappings placeholder — kept for the historical/legacy
-- ambiguous_card path, no longer the primary "did we capture it" signal.
-- ============================================================================

drop function if exists public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text);

create function public.capture_transaction(
  p_id uuid, p_card_identifier text, p_merchant_raw text, p_merchant_normalized text, p_amount_e4 bigint,
  p_occurred_at timestamptz, p_external_id text, p_notes text default null
)
returns table(mapped boolean, account_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
  v_recent_count int;
begin
  select count(*) into v_recent_count
  from public.transactions
  where owner_id = v_owner
    and source = 'capture'
    and created_at > now() - interval '1 minute';

  if v_recent_count >= 20 then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier;

  if v_account_id is not null then
    select a.currency into v_currency from public.accounts a where a.id = v_account_id;
  end if;

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense');

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, notes, source, status, external_id, card_identifier
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, -abs(p_amount_e4), v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, p_notes, 'capture', 'pending', p_external_id, p_card_identifier
  );

  return query select (v_account_id is not null), v_account_id;
end;
$$;

revoke all on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) from public;
grant execute on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) to authenticated;

-- ============================================================================
-- update_transaction — ownership check special-cases a still-null
-- account_id (verified via the row's own owner_id, the same fallback the
-- RLS policy above uses); on a successful edit, auto-links the card the
-- exact moment a previously-unresolved capture finally gets an account.
-- ============================================================================

drop function if exists public.update_transaction(uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text);

create function public.update_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.account_id is not null then
    if not public.can_write_account(v_current.account_id) then
      raise exception 'transaction not found or not accessible';
    end if;
  elsif v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.source = 'capture' and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) from public;
grant execute on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) to authenticated;

-- ============================================================================
-- confirm_capture_transaction — belt-and-suspenders on top of the CHECK
-- constraints above: a clear error instead of a raw constraint-violation
-- message when someone tries to confirm a still-unresolved capture.
-- ============================================================================

create or replace function public.confirm_capture_transaction(p_id uuid, p_expected_version int)
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
  select id, version, owner_id, account_id into v_current from public.transactions where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.account_id is null then
    raise exception 'assign an account to this transaction before confirming it';
  end if;

  update public.transactions
  set status = 'confirmed'
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

revoke all on function public.confirm_capture_transaction(uuid, int) from public;
grant execute on function public.confirm_capture_transaction(uuid, int) to authenticated;

-- ============================================================================
-- rename_card_mapping / unmap_card — the Account edit sheet's new "manage
-- mapped cards" affordance. unmap_card soft-deletes (deleted_at), never a
-- hard delete (no tombstone for pull_changes to ever communicate to an
-- already-synced client) and never an account_id=null reset (that would
-- immediately resurrect the mapping as an ambiguous_card Needs Review item
-- — exactly the nagging "remove" is meant to dismiss).
-- ============================================================================

create function public.rename_card_mapping(p_id uuid, p_card_identifier text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.card_mappings
  set card_identifier = p_card_identifier, updated_at = now()
  where id = p_id and owner_id = (select auth.uid()) and deleted_at is null;

  if not found then
    raise exception 'card mapping not found or not accessible';
  end if;
end;
$$;

revoke all on function public.rename_card_mapping(uuid, text) from public;
grant execute on function public.rename_card_mapping(uuid, text) to authenticated;

create function public.unmap_card(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.card_mappings
  set deleted_at = now()
  where id = p_id and owner_id = (select auth.uid()) and deleted_at is null;

  if not found then
    raise exception 'card mapping not found or not accessible';
  end if;
end;
$$;

revoke all on function public.unmap_card(uuid) from public;
grant execute on function public.unmap_card(uuid) to authenticated;

-- ============================================================================
-- transactions_with_details — join accounts/currencies become LEFT JOIN so
-- a null-account pending capture still appears (account_name/currency
-- render null; fx_convert is already null-safe on a null currency — its
-- body is a plain SQL CASE with no STRICT, verified against the live
-- function, so no extra guard is needed here). notes stays the LAST
-- column — Postgres forbids inserting a view column mid-list via
-- `create or replace view` (it reads that as renaming every column after
-- it), a lesson from the previous migration this session.
-- ============================================================================

create or replace view transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount_e4,
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
    when t.amount_e4 < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version,
  p.base_currency,
  bc.minor_unit as base_minor_unit,
  fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) as amount_base_e4,
  (fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) is null) as has_missing_rate,
  t.recurring_rule_id,
  t.notes
from transactions t
left join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
left join currencies cur on cur.code = t.currency
left join profiles p on p.id = (select auth.uid())
left join currencies bc on bc.code = p.base_currency
where t.deleted_at is null;

grant select on transactions_with_details to authenticated, service_role;

-- needs_review: ambiguous_card gains two guards — deleted_at is null (a
-- soft-deleted/unmapped card_mappings row must never resurface, a
-- currently-dormant gap since nothing set deleted_at on this table until
-- unmap_card above existed) and a NOT EXISTS against any pending capture
-- already covering the same card (without it, every future unmapped
-- capture would produce two redundant Needs Review entries for one event
-- — an ambiguous_card AND a pending_capture — inflating the badge count).
-- Historical pre-migration ambiguous_card rows with no matching
-- transaction are unaffected and still surface normally.

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
  'Unmapped card — ' || cm.card_identifier as title,
  null::text as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from card_mappings cm
where cm.account_id is null
  and cm.deleted_at is null
  and not exists (
    select 1 from transactions t2
    where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
      and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
  )
union all
select
  'csv_import_candidate'::text as kind,
  ic.id as item_id,
  ic.account_id,
  ic.occurred_at,
  'Import row — ' || coalesce(ic.merchant_raw, 'no description') as title,
  case when ic.matched_transaction_id is not null then 'Possible duplicate of an existing transaction' else null end
    as subtitle,
  ic.amount_e4,
  ic.currency
from csv_import_candidates ic
where ic.status = 'pending';

grant select on needs_review to authenticated, service_role;

-- ============================================================================
-- delete_transaction — same ownership-check gap update_transaction had:
-- can_write_account(null) is false, which would refuse to delete a
-- still-unresolved capture (a real thing a user might want to do instead
-- of ever assigning it an account). Found by the pgTAP suite itself
-- attempting exactly this.
-- ============================================================================

create or replace function public.delete_transaction(p_id uuid, p_expected_version integer)
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
  select id, version, account_id, transfer_group_id, deleted_at, owner_id
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.account_id is not null then
    if not public.can_write_account(v_current.account_id) then
      raise exception 'transaction not found or not accessible';
    end if;
  elsif v_current.owner_id <> v_owner then
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

revoke all on function public.delete_transaction(uuid, integer) from public;
grant execute on function public.delete_transaction(uuid, integer) to authenticated;
