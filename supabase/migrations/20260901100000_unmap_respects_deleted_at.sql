-- Two related card_mappings defects found in device testing (2026-08).
--
-- A. Unmapping a card didn't actually stop it routing. `unmap_card` soft-
--    deletes correctly, and every *display* read filters `deleted_at is
--    null` — but the one read that decides where a new charge lands,
--    capture_transaction's own card lookup, never did. So a card the user
--    had explicitly unmapped kept auto-filing new purchases into the old
--    account, while the Mapped Cards list showed it as gone: exactly the
--    "the account is still remembering a card I removed" symptom, and a
--    real divergence between what the app showed and what the DB resolved.
--    (`CaptureLocalWrite`'s local mirror of this lookup had the identical
--    gap and is fixed alongside.)
--
-- B. Deleting an unreviewed capture left its placeholder card_mappings row
--    behind (account_id null), which then surfaced on its own as an
--    ambiguous_card "Unmapped card" item with no transaction left to
--    explain it. capture_transaction creates that placeholder for every
--    capture on an unknown card, so the only thing that had ever kept it
--    off the Needs Review list was the pending_capture row now being
--    deleted. Deleting the purchase is a clear signal the user doesn't
--    want the card filed either — the placeholder goes with it. Only ever
--    a placeholder (`account_id is null`): a card genuinely mapped to an
--    account is a deliberate user choice and is never touched here, and
--    the row is kept if any *other* live pending capture still needs it.

-- ============================================================================
-- A. capture_transaction — the card lookup now respects deleted_at.
-- Body otherwise identical to 20260829100000_drop_capture_return_columns.sql.
-- ============================================================================

create or replace function public.capture_transaction(
  p_id uuid, p_card_identifier text, p_merchant_raw text, p_merchant_normalized text, p_amount_e4 bigint,
  p_occurred_at timestamptz, p_external_id text, p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
begin
  if not public.ops_check_own_rate_limit('capture_transaction', 20, 60) then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  -- `deleted_at is null` (fix A): an unmapped card must resolve to no
  -- account at all, landing the capture as an ordinary unresolved pending
  -- review, not silently back into the account it was unmapped from.
  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier and cm.deleted_at is null;

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
end;
$$;

revoke all on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) from public;
grant execute on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text)
  to authenticated;

-- ============================================================================
-- B. delete_transaction — takes the orphaned placeholder mapping with it.
-- Body otherwise identical to 20260822100000_unmapped_capture_lands_locally.sql.
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
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);
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

revoke all on function public.delete_transaction(uuid, integer) from public;
grant execute on function public.delete_transaction(uuid, integer) to authenticated;

-- One-time backfill: clean up placeholder mappings already orphaned by a
-- capture deleted before this fix existed — B's fix only stops new ones.
-- Safe unconditionally: `account_id is null` only ever happens via
-- capture_transaction's own placeholder insert (map_card/
-- link_card_to_account always set a real account), so every row this
-- touches was born from a capture attempt, by construction.
update public.card_mappings cm
set deleted_at = now()
where cm.account_id is null and cm.deleted_at is null
  and not exists (
    select 1 from public.transactions t2
    where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
      and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
  );
