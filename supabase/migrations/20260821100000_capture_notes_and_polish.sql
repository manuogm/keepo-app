-- Phase 12 follow-up: a freeform `notes` column, plus two small capture
-- fixes found while wiring the Wallet automation end to end.
--
-- 1. `notes` — a user-editable freeform field on every transaction.
--    Auto-captures fill it with "Captured automatically — {merchant}" so a
--    capture that falls back to the "Other" category (no learned merchant
--    match yet) still carries the raw merchant name somewhere the user can
--    see it, without a second lookup.
-- 2. `needs_review`'s `pending_capture` subtitle still said "Uncategorized"
--    for the `is_default`-category case — a leftover from the system_key
--    era (20260814100100 renamed the actual fallback category to "Other"
--    but missed this string).

alter table transactions add column notes text;

-- `notes` is appended as the view's LAST column, not alongside the other
-- merchant_raw/merchant_normalized fields it's conceptually grouped with —
-- `create or replace view` only allows adding trailing columns, never
-- inserting one mid-list (Postgres treats that as renaming every column
-- after it). Every consumer already decodes this view by column name, not
-- position, so the reordering is invisible to them.
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
join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
join currencies cur on cur.code = t.currency
left join profiles p on p.id = (select auth.uid())
left join currencies bc on bc.code = p.base_currency
where t.deleted_at is null;

grant select on transactions_with_details to authenticated, service_role;

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

-- update_transaction: adds p_notes (trailing, defaulted — every existing
-- caller keeps working; the client always sends its own current value,
-- same as merchant_raw already does, so "not editing notes" and "clearing
-- notes" are indistinguishable here on purpose, matching merchant_raw's
-- own whole-row-replace contract).

drop function if exists public.update_transaction(uuid, integer, uuid, uuid, bigint, text, timestamptz, text);

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
  select id, version, account_id, transfer_group_id, deleted_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(v_current.account_id) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
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

  return query select false, v_result;
end;
$$;

revoke all on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) from public;
grant execute on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) to authenticated;

-- capture_transaction: adds p_notes, written straight onto the pending row
-- (never a second lookup — the client computes it once, same pattern as
-- external_id/merchant_normalized already use).

drop function if exists public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text);

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

  if v_account_id is null then
    return query select false, null::uuid;
    return;
  end if;

  select a.currency into v_currency from public.accounts a where a.id = v_account_id;

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense');

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, notes, source, status, external_id
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, -abs(p_amount_e4), v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, p_notes, 'capture', 'pending', p_external_id
  );

  return query select true, v_account_id;
end;
$$;

revoke all on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) from public;
grant execute on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) to authenticated;
