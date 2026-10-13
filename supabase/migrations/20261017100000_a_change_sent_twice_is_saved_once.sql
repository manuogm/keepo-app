-- A change sent twice is saved once.
--
-- Found on a real purchase (2026-10-12): an Apple Pay capture was confirmed,
-- the confirm landed, and the next launch raised "transaction … is not a
-- pending capture — use update_transaction" over the splash screen.
--
-- The outbox resends a write whenever its first attempt ends without an
-- answer — a timeout, a dropped connection, a process iOS suspended mid-
-- request. That first attempt can have landed. Creates were made safe
-- against this long ago (a client id, `23505` read as "already applied");
-- the version-checked writes never were, and each answered its own resend
-- wrongly:
--
--   review_capture_transaction  raised "not a pending capture" — the first
--                               attempt is what confirmed it. A raised
--                               sentence is a final refusal, so the phone
--                               dropped the write, re-synced, and showed the
--                               sentence to the user verbatim.
--   delete_transaction          raised "not found" — the first attempt is
--                               what deleted it. Same alert.
--   delete_transfer             raised "transfer <id> not found or not
--                               accessible" — an id, in a sentence shown to
--                               the user.
--   update_transaction,         logged a sync_conflicts row against the
--   update_transfer,            user's own change, which then asked them to
--   confirm_capture_transaction choose between two identical versions.
--
-- The lesson from set_account_balance (20260815100000) applies: check
-- "is this already applied?" before treating a version mismatch as a
-- conflict. A row that already holds exactly what the write asks for is the
-- write's success, not a conflict and not an error.
--
-- review_capture_transaction also stops refusing a capture that is already
-- confirmed. That refusal protected nothing — the write is version-checked
-- like every other edit — and it turned a phone whose copy still said
-- "pending" into a lost edit plus an alert, where a stale version should be
-- an ordinary conflict the user can resolve.
--
-- The guards that name another RPC ("use update_transfer") are messages for
-- a developer, and P0001 is this schema's code for a sentence meant for the
-- user (UserFacingError shows P0001 verbatim). They now raise 22023, which
-- the phone still treats as final but never shows. A transfer that cannot
-- be found says so in words, without its id.

-- ============================================================================
-- transaction_already_matches
-- ============================================================================

-- Whether a live row already holds every field a write asked for. A ledger
-- edit passes the same jsonb it records as `attempted_payload` (every key
-- present, null included), so the comparison and the conflict log cannot
-- drift apart; a transfer passes one leg's fields at a time. A field the
-- write does not name is not compared — a transfer never sets a category.
create function public.transaction_already_matches(p_id uuid, p_attempted jsonb)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.transactions t
    where t.id = p_id
      and t.deleted_at is null
      and (not p_attempted ? 'account_id' or t.account_id is not distinct from (p_attempted->>'account_id')::uuid)
      and (not p_attempted ? 'category_id'
           or t.category_id is not distinct from (p_attempted->>'category_id')::uuid)
      and (not p_attempted ? 'amount_e4' or t.amount_e4 = (p_attempted->>'amount_e4')::bigint)
      and (not p_attempted ? 'currency' or t.currency = p_attempted->>'currency')
      and (not p_attempted ? 'occurred_at' or t.occurred_at = (p_attempted->>'occurred_at')::timestamptz)
      and (not p_attempted ? 'merchant_raw' or t.merchant_raw is not distinct from p_attempted->>'merchant_raw')
      and (not p_attempted ? 'notes' or t.notes is not distinct from p_attempted->>'notes')
      and (not p_attempted ? 'title' or t.title is not distinct from p_attempted->>'title')
      and (not p_attempted ? 'original_amount_e4'
           or t.original_amount_e4 is not distinct from (p_attempted->>'original_amount_e4')::bigint)
      and (not p_attempted ? 'original_currency'
           or t.original_currency is not distinct from p_attempted->>'original_currency')
  );
$$;
revoke all on function public.transaction_already_matches(uuid, jsonb) from public, anon, authenticated;

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
  v_attempted jsonb;
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
  v_title text := nullif(btrim(p_title), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier, occurred_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null
     or not public.can_read_transaction(v_current.account_id, v_current.owner_id, v_current.occurred_at) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id using errcode = '22023';
  end if;

  perform public.assert_transaction_placeable(p_account_id, p_occurred_at);

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  v_attempted := jsonb_build_object(
    'rpc', 'update_transaction', 'account_id', p_account_id, 'category_id', p_category_id,
    'amount_e4', p_amount_e4, 'currency', p_currency, 'occurred_at', p_occurred_at,
    'merchant_raw', p_merchant_raw, 'notes', p_notes, 'original_amount_e4', v_original_amount,
    'original_currency', v_original_currency, 'title', v_title
  );

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
    if public.transaction_already_matches(p_id, v_attempted) then
      return query select false, t from public.transactions t where t.id = p_id;
      return;
    end if;

    perform public.record_transaction_conflict(p_id, p_expected_version, v_current.version, v_attempted);
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
  v_attempted jsonb;
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
  v_title text := nullif(btrim(p_title), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, status, card_identifier,
         merchant_normalized, occurred_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null
     or not public.can_read_transaction(v_current.account_id, v_current.owner_id, v_current.occurred_at) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id using errcode = '22023';
  end if;

  -- Whatever its status: a confirmed capture is reviewed as a
  -- version-checked edit like any other, and a resent review is caught below.
  if v_current.source <> 'capture' then
    raise exception 'transaction % is not a capture — use update_transaction', p_id using errcode = '22023';
  end if;

  perform public.assert_transaction_placeable(p_account_id, p_occurred_at);

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  v_attempted := jsonb_build_object(
    'rpc', 'review_capture_transaction', 'account_id', p_account_id, 'category_id', p_category_id,
    'amount_e4', p_amount_e4, 'currency', p_currency, 'occurred_at', p_occurred_at,
    'merchant_raw', p_merchant_raw, 'notes', p_notes, 'original_amount_e4', v_original_amount,
    'original_currency', v_original_currency, 'title', v_title
  );

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
    -- The review already landed: its first attempt confirmed the row and
    -- did the card link and the merchant learning below.
    if v_current.status = 'confirmed' and public.transaction_already_matches(p_id, v_attempted) then
      return query select false, t from public.transactions t where t.id = p_id;
      return;
    end if;

    perform public.record_transaction_conflict(p_id, p_expected_version, v_current.version, v_attempted);
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
  select id, version, owner_id, account_id, category_id, merchant_normalized, status into v_current
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
    -- A confirm asks for nothing but the status, so a row already confirmed
    -- is this confirm's success, whatever else has changed since.
    if v_current.status = 'confirmed' then
      return query select false, t from public.transactions t where t.id = p_id;
      return;
    end if;

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
returns table(conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current record;
  v_updated integer;
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier, occurred_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null
     or not public.can_read_transaction(v_current.account_id, v_current.owner_id, v_current.occurred_at) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use delete_transfer', p_id using errcode = '22023';
  end if;

  -- Already gone: what this delete asked for is true.
  if v_current.deleted_at is not null then
    return query select false;
    return;
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
-- update_transfer
-- ============================================================================

create or replace function public.update_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer,
  p_from_amount_e4 bigint,
  p_to_amount_e4 bigint,
  p_occurred_at timestamptz,
  p_notes text default null,
  p_title text default null,
  p_from_account_id uuid default null,
  p_to_account_id uuid default null
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

  select id, version, account_id, owner_id, currency, occurred_at into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id, owner_id, currency, occurred_at into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_read_transaction(v_from.account_id, v_from.owner_id, v_from.occurred_at)
     or not public.can_read_transaction(v_to.account_id, v_to.owner_id, v_to.occurred_at) then
    raise exception 'This transfer was deleted, or is no longer shared with you.';
  end if;

  v_from_account := coalesce(p_from_account_id, v_from.account_id);
  v_to_account := coalesce(p_to_account_id, v_to.account_id);
  v_from_currency := v_from.currency;
  v_to_currency := v_to.currency;

  if v_from_account = v_to_account then
    raise exception 'A transfer needs two different accounts.';
  end if;

  -- A leg that moves is placed afresh; a leg that stays only needs its new
  -- date to be one the caller can see. It may sit on a deleted account — a
  -- kept anchor (20261007100000) — and editing the live side must not
  -- depend on that.
  if v_from_account <> v_from.account_id then
    v_from_currency := public.transfer_leg_target_currency(v_from_account, v_from.owner_id, p_occurred_at);
  else
    perform public.assert_transaction_date_visible(v_from_account, p_occurred_at);
  end if;
  if v_to_account <> v_to.account_id then
    v_to_currency := public.transfer_leg_target_currency(v_to_account, v_to.owner_id, p_occurred_at);
  else
    perform public.assert_transaction_date_visible(v_to_account, p_occurred_at);
  end if;

  perform public.assert_transfer_seen_by_both(v_from_account, v_to_account, p_occurred_at);

  if v_from.version <> p_from_expected_version or v_to.version <> p_to_expected_version then
    -- The edit already landed: both legs hold what it asks for.
    if public.transaction_already_matches(v_from.id, jsonb_build_object(
         'account_id', v_from_account, 'currency', v_from_currency, 'amount_e4', -p_from_amount_e4,
         'occurred_at', p_occurred_at, 'notes', p_notes, 'title', v_title))
       and public.transaction_already_matches(v_to.id, jsonb_build_object(
         'account_id', v_to_account, 'currency', v_to_currency, 'amount_e4', p_to_amount_e4,
         'occurred_at', p_occurred_at, 'notes', p_notes, 'title', v_title)) then
      return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
      return;
    end if;

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
-- delete_transfer
-- ============================================================================

create or replace function public.delete_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer
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
  select id, version, account_id, owner_id, occurred_at into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id, owner_id, occurred_at into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  -- Already gone: what this delete asked for is true.
  if v_from.id is null and v_to.id is null and exists (
    select 1 from public.transactions t
    where t.transfer_group_id = p_transfer_group_id and t.deleted_at is not null
      and public.can_read_transaction(t.account_id, t.owner_id, t.occurred_at)
  ) then
    return query select false;
    return;
  end if;

  if v_from.id is null or v_to.id is null
     or not public.can_read_transaction(v_from.account_id, v_from.owner_id, v_from.occurred_at)
     or not public.can_read_transaction(v_to.account_id, v_to.owner_id, v_to.occurred_at) then
    raise exception 'This transfer was deleted, or is no longer shared with you.';
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
