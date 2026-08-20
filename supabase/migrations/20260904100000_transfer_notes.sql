-- A transfer can carry a note, like every other transaction.
--
-- `transactions.notes` has always existed; the two transfer RPCs simply never
-- accepted one, so the field was hidden on the transfer tab of the entry form
-- while expense and income both had it. There is no data-model reason for
-- that gap — a transfer is two ordinary `transactions` rows.
--
-- The note is written to BOTH legs, deliberately. A transfer is one act by
-- the user; storing their sentence on only the outgoing leg would make it
-- vanish when the destination account's history is read on its own, and
-- there is no third row representing "the transfer itself" to hang it off.
-- Both legs already duplicate `occurred_at` for exactly this reason.
--
-- Both bodies below are the current definitions from 20260815100000 restated
-- in full with the parameter threaded through — re-read end to end rather
-- than patched from an excerpt, per version-logs/lessons-learned.md.

-- ============================================================================
-- create_transfer
-- ============================================================================

drop function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid);

create function public.create_transfer(
  p_from_account_id uuid, p_to_account_id uuid, p_from_amount_e4 bigint, p_to_amount_e4 bigint default null,
  p_occurred_at timestamptz default now(), p_from_id uuid default null, p_to_id uuid default null,
  p_notes text default null
)
returns setof transactions
language plpgsql
set search_path = ''
as $$
declare
  v_from_owner uuid;
  v_from_currency text;
  v_to_owner uuid;
  v_to_currency text;
  v_to_amount_e4 bigint;
  v_group uuid := gen_random_uuid();
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 then
    raise exception 'from_amount must be a positive magnitude';
  end if;

  select owner_id, currency into v_from_owner, v_from_currency
  from public.accounts where id = p_from_account_id;
  select owner_id, currency into v_to_owner, v_to_currency
  from public.accounts where id = p_to_account_id;

  if v_from_currency is null or v_to_currency is null then
    raise exception 'one or both accounts were not found or are not accessible';
  end if;

  v_to_amount_e4 := coalesce(
    p_to_amount_e4,
    case when v_from_currency = v_to_currency then p_from_amount_e4 end
  );
  if v_to_amount_e4 is null or v_to_amount_e4 <= 0 then
    raise exception 'to_amount is required for cross-currency transfers and must be a positive magnitude';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id, source, notes
  )
  values
    (
      coalesce(p_from_id, gen_random_uuid()), v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount_e4, v_from_currency, p_occurred_at, v_group, 'manual', p_notes
    ),
    (
      coalesce(p_to_id, gen_random_uuid()), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount_e4, v_to_currency, p_occurred_at, v_group, 'manual', p_notes
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;

revoke all on function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid, text) from public;
grant execute on function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid, text)
  to authenticated;

-- ============================================================================
-- update_transfer
-- ============================================================================

drop function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz);

create function public.update_transfer(
  p_transfer_group_id uuid, p_from_expected_version integer, p_to_expected_version integer,
  p_from_amount_e4 bigint, p_to_amount_e4 bigint, p_occurred_at timestamptz, p_notes text default null
)
returns table(conflict boolean, transaction transactions)
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
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 or p_to_amount_e4 is null or p_to_amount_e4 <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

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

  update public.transactions set amount_e4 = -p_from_amount_e4, occurred_at = p_occurred_at, notes = p_notes
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set amount_e4 = p_to_amount_e4, occurred_at = p_occurred_at, notes = p_notes
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

revoke all on function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz, text)
  from public;
grant execute on function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz, text)
  to authenticated;
