-- A conflict remembers what was attempted.
--
-- `sync_conflicts` has stored two version numbers and nothing else since
-- Phase 3. The rejected write itself was discarded the instant its version
-- check failed, so "Keep mine" in Needs Review rebuilt "mine" from whatever
-- the local mirror still held — and for a transfer it could not rebuild
-- anything at all: it required a category, a transfer has none, so it did
-- nothing and then marked the conflict resolved, silently keeping the
-- server's version. The Phase 11 walkthrough logged this as required
-- follow-up ("sync_conflicts.attempted_payload jsonb, populated by every
-- versioned write RPC"); this is it, for every RPC that writes a
-- transaction.
--
-- `attempted_payload` holds the rejected call as `{"rpc": <name>, ...its
-- arguments}` — enough for the client to replay it through the same RPC with
-- fresh versions, whatever kind of write it was. It syncs like every other
-- column (`pull_changes` is `to_jsonb(row)`), so the device that resolves
-- the conflict need not be the one that caused it.
--
-- `record_transaction_conflict` is now the one way these RPCs record a
-- conflict. A transfer records **one** row, on its sending leg, rather than
-- one per mismatched leg: one edit is one thing to review, and the reviewer
-- acts on the transfer, not on a half of it.
--
-- Each function is restated from its last definition with only its conflict
-- insert changed:
--   update_transaction, review_capture_transaction  20261005100000
--   confirm_capture_transaction                     20260826100000
--   delete_transaction                              20260901100000
--   update_transfer                                 20261006100000
--   delete_transfer                                 20260815100000
-- ============================================================================

alter table public.sync_conflicts add column attempted_payload jsonb;

comment on column public.sync_conflicts.attempted_payload is
  'The rejected write, as {"rpc": <name>, ...arguments}, so "Keep mine" can replay it. Null for conflicts recorded before 20261008100000 and for account writes.';

create function public.record_transaction_conflict(
  p_row_id uuid, p_client_version integer, p_server_version integer, p_attempted jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version, attempted_payload)
  values ('transactions', p_row_id, (select auth.uid()), p_client_version, p_server_version, p_attempted);
$$;

revoke all on function public.record_transaction_conflict(uuid, integer, integer, jsonb)
  from public, anon, authenticated;

-- ============================================================================
-- update_transaction
-- ============================================================================

create or replace function public.update_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null,
  p_original_amount_e4 bigint default null, p_original_currency text default null, p_title text default null
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
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
  v_title text := nullif(btrim(p_title), '');
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

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    title = v_title,
    original_amount_e4 = v_original_amount,
    original_currency = v_original_currency
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    perform public.record_transaction_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'update_transaction', 'account_id', p_account_id, 'category_id', p_category_id,
      'amount_e4', p_amount_e4, 'currency', p_currency, 'occurred_at', p_occurred_at,
      'merchant_raw', p_merchant_raw, 'notes', p_notes, 'original_amount_e4', v_original_amount,
      'original_currency', v_original_currency, 'title', v_title
    ));

    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.source = 'capture' and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  return query select false, v_result;
end;
$$;

-- ============================================================================
-- review_capture_transaction
-- ============================================================================

create or replace function public.review_capture_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null,
  p_original_amount_e4 bigint default null, p_original_currency text default null, p_title text default null
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
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
  v_title text := nullif(btrim(p_title), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, status, card_identifier,
         merchant_normalized
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.source <> 'capture' or v_current.status <> 'pending' then
    raise exception 'transaction % is not a pending capture — use update_transaction', p_id;
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

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    title = v_title,
    status = 'confirmed',
    original_amount_e4 = v_original_amount,
    original_currency = v_original_currency
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    perform public.record_transaction_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'review_capture_transaction', 'account_id', p_account_id, 'category_id', p_category_id,
      'amount_e4', p_amount_e4, 'currency', p_currency, 'occurred_at', p_occurred_at,
      'merchant_raw', p_merchant_raw, 'notes', p_notes, 'original_amount_e4', v_original_amount,
      'original_currency', v_original_currency, 'title', v_title
    ));
    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  if v_current.merchant_normalized is not null then
    insert into public.merchant_category_map (owner_id, merchant_pattern, category_id)
    values (v_owner, v_current.merchant_normalized, p_category_id)
    on conflict (owner_id, merchant_pattern) do update set category_id = excluded.category_id, updated_at = now();
  end if;

  return query select false, v_result;
end;
$$;

-- ============================================================================
-- confirm_capture_transaction
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
  select id, version, owner_id, account_id, category_id, merchant_normalized into v_current
  from public.transactions where id = p_id;

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
    perform public.record_transaction_conflict(
      p_id, p_expected_version, v_current.version, jsonb_build_object('rpc', 'confirm_capture_transaction')
    );
    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.merchant_normalized is not null then
    insert into public.merchant_category_map (owner_id, merchant_pattern, category_id)
    values (v_owner, v_current.merchant_normalized, v_current.category_id)
    on conflict (owner_id, merchant_pattern) do update set category_id = excluded.category_id, updated_at = now();
  end if;

  return query select false, v_result;
end;
$$;

-- ============================================================================
-- delete_transaction
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
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier
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
    perform public.record_transaction_conflict(
      p_id, p_expected_version, v_current.version, jsonb_build_object('rpc', 'delete_transaction')
    );
    return query select true;
    return;
  end if;

  -- Fix B: the placeholder mapping this capture created has nothing left
  -- to justify it — retire it with the purchase instead of leaving a bare
  -- "Unmapped card" item behind. Placeholders only (`account_id is null`),
  -- and only once no other live pending capture still needs it.
  if v_current.source = 'capture' and v_current.card_identifier is not null then
    update public.card_mappings cm
    set deleted_at = now()
    where cm.owner_id = v_current.owner_id and cm.card_identifier = v_current.card_identifier
      and cm.account_id is null and cm.deleted_at is null
      and not exists (
        select 1 from public.transactions t2
        where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
          and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
      );
  end if;

  return query select false;
end;
$$;

-- ============================================================================
-- update_transfer — one conflict, on the sending leg
-- ============================================================================

create or replace function public.update_transfer(
  p_transfer_group_id uuid, p_from_expected_version integer, p_to_expected_version integer,
  p_from_amount_e4 bigint, p_to_amount_e4 bigint, p_occurred_at timestamptz, p_notes text default null,
  p_title text default null, p_from_account_id uuid default null, p_to_account_id uuid default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from record;
  v_to record;
  v_from_account uuid;
  v_to_account uuid;
  v_from_currency text;
  v_to_currency text;
  v_title text := nullif(btrim(p_title), '');
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 or p_to_amount_e4 is null or p_to_amount_e4 <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

  select id, version, account_id, owner_id, currency into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id, owner_id, currency into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  v_from_account := coalesce(p_from_account_id, v_from.account_id);
  v_to_account := coalesce(p_to_account_id, v_to.account_id);
  v_from_currency := v_from.currency;
  v_to_currency := v_to.currency;

  if v_from_account = v_to_account then
    raise exception 'A transfer needs two different accounts.';
  end if;

  if v_from_account <> v_from.account_id then
    v_from_currency := public.transfer_leg_target_currency(v_from_account, v_from.owner_id);
  end if;
  if v_to_account <> v_to.account_id then
    v_to_currency := public.transfer_leg_target_currency(v_to_account, v_to.owner_id);
  end if;

  if v_from.version <> p_from_expected_version or v_to.version <> p_to_expected_version then
    -- The versions of whichever leg moved on, so the review reads as a real
    -- disagreement rather than "your version 3 vs. the saved version 3".
    perform public.record_transaction_conflict(
      v_from.id,
      case when v_from.version <> p_from_expected_version then p_from_expected_version else p_to_expected_version end,
      case when v_from.version <> p_from_expected_version then v_from.version else v_to.version end,
      jsonb_build_object(
        'rpc', 'update_transfer', 'transfer_group_id', p_transfer_group_id,
        'from_amount_e4', p_from_amount_e4, 'to_amount_e4', p_to_amount_e4, 'occurred_at', p_occurred_at,
        'notes', p_notes, 'title', v_title, 'from_account_id', v_from_account, 'to_account_id', v_to_account
      )
    );
    return query select true, null::public.transactions;
    return;
  end if;

  update public.transactions set account_id = v_from_account, currency = v_from_currency,
    amount_e4 = -p_from_amount_e4, occurred_at = p_occurred_at, notes = p_notes, title = v_title
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set account_id = v_to_account, currency = v_to_currency,
    amount_e4 = p_to_amount_e4, occurred_at = p_occurred_at, notes = p_notes, title = v_title
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

-- ============================================================================
-- delete_transfer — one conflict, on the sending leg
-- ============================================================================

create or replace function public.delete_transfer(
  p_transfer_group_id uuid, p_from_expected_version integer, p_to_expected_version integer
)
returns table(conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from record;
  v_to record;
begin
  select id, version, account_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version or v_to.version <> p_to_expected_version then
    perform public.record_transaction_conflict(
      v_from.id,
      case when v_from.version <> p_from_expected_version then p_from_expected_version else p_to_expected_version end,
      case when v_from.version <> p_from_expected_version then v_from.version else v_to.version end,
      jsonb_build_object('rpc', 'delete_transfer', 'transfer_group_id', p_transfer_group_id)
    );
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
