-- A transfer is found where the phone left it, and can be moved.
--
-- ============================================================================
-- 1. create_transfer — the group id is the sending leg's own id
-- ============================================================================
--
-- `create_transfer` minted the pair's `transfer_group_id` with
-- `gen_random_uuid()` inside its body. The phone cannot know that value until
-- its next pull, so its optimistic write-through (`OutboxLocalWrite
-- .createTransfer`) stored a placeholder instead: the sending leg's id. Two
-- things then went wrong, both reproduced against the local stack:
--
--   * Edited or deleted before the next pull, a fresh transfer was addressed
--     by the placeholder. `update_transfer`/`delete_transfer` found no such
--     group and raised "not found or not accessible", which the outbox
--     retried forever — and the next pull restored the original, so the edit
--     was simply lost.
--   * Offline, the create was queued under the sending leg's id and the edit
--     under the group id — the same placeholder — so the edit OVERWROTE the
--     queued create. The transfer never reached the server at all.
--
-- The lessons-learned rule "a write path that generates its own id
-- server-side is the one thing standing between idempotent-for-free and a
-- silent bug" was applied to the two leg ids in 20260807140000 and missed
-- the third id the same call mints. The fix is to stop minting it: **the
-- group id is the sending leg's id**, which the client already chooses and
-- already uses as its placeholder. Nothing on the phone changes, the build
-- already on a phone is fixed by this migration alone, and a retried create
-- still hits `transactions_pkey` (23505) exactly as before. A caller that
-- sends no leg ids (none does) still gets a random group.
--
-- A group id and a transaction id are separate columns with no constraint
-- between them, and nothing reads one as the other (checked across every
-- migration and the app before writing this), so the two being equal on a
-- sending leg is safe.
--
-- Same signature, so `create or replace` keeps the grants.
--
-- ============================================================================
-- 2. update_transfer — the two accounts can change
-- ============================================================================
--
-- The edit form has always offered both account pickers, and the RPC has
-- never taken an account. A changed account was silently dropped — and when
-- the change altered which currencies the pair spanned, the form's received
-- amount landed on the OLD leg: a EUR leg stored "+100" meant as dollars
-- (cross → same currency), or a same-currency pair that no longer netted to
-- zero and failed the integrity trigger at commit (same → cross).
--
-- `p_from_account_id`/`p_to_account_id` (defaulted to "unchanged", so the
-- build already on a phone keeps binding). Each leg's currency is taken from
-- its new account — `(account_id, currency) → accounts (id, currency)` makes
-- that the only value it can hold. A leg may only move to an account with the
-- **same owner**: `transactions_prevent_owner_id_change` forbids rewriting
-- `owner_id`, and the composite FK forces `owner_id` to be the account's
-- owner, so a move across owners is a new transfer, not an edit. A deleted
-- account is refused as a target. `check_transfer_integrity` remains the
-- backstop for distinct accounts, one owner or one household, and
-- same-currency legs netting to zero.
--
-- Restated from 20261005100000, the last definition, with only the account
-- handling added.
-- ============================================================================

create or replace function public.create_transfer(
  p_from_account_id uuid, p_to_account_id uuid, p_from_amount_e4 bigint, p_to_amount_e4 bigint default null,
  p_occurred_at timestamptz default now(), p_from_id uuid default null, p_to_id uuid default null,
  p_notes text default null, p_title text default null
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
  v_from_id uuid := coalesce(p_from_id, gen_random_uuid());
  -- The sending leg's own id. See the header: this is the value the phone
  -- already wrote as its placeholder, so the two can never disagree.
  v_group uuid := v_from_id;
  v_title text := nullif(btrim(p_title), '');
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
    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id, source, notes, title
  )
  values
    (
      v_from_id, v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount_e4, v_from_currency, p_occurred_at, v_group, 'manual', p_notes, v_title
    ),
    (
      coalesce(p_to_id, gen_random_uuid()), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount_e4, v_to_currency, p_occurred_at, v_group, 'manual', p_notes, v_title
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;

drop function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz, text, text);

create function public.update_transfer(
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
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_from_account uuid;
  v_to_account uuid;
  v_from_currency text;
  v_to_currency text;
  v_conflict boolean := false;
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

  update public.transactions set account_id = v_from_account, currency = v_from_currency,
    amount_e4 = -p_from_amount_e4, occurred_at = p_occurred_at, notes = p_notes, title = v_title
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set account_id = v_to_account, currency = v_to_currency,
    amount_e4 = p_to_amount_e4, occurred_at = p_occurred_at, notes = p_notes, title = v_title
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

revoke all on function public.update_transfer(
  uuid, integer, integer, bigint, bigint, timestamptz, text, text, uuid, uuid
) from public;
grant execute on function public.update_transfer(
  uuid, integer, integer, bigint, bigint, timestamptz, text, text, uuid, uuid
) to authenticated;

-- ============================================================================
-- transfer_leg_target_currency — may this leg move onto that account?
--
-- The currency the leg must carry there, or a raise that says why not. Kept
-- apart from `update_transfer` so the two legs ask the identical question,
-- and so the rule has one statement: the target is a live account the caller
-- can write, owned by whoever already owns the leg.
-- ============================================================================

create function public.transfer_leg_target_currency(p_account_id uuid, p_leg_owner uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account record;
begin
  select owner_id, currency, deleted_at into v_account from public.accounts where id = p_account_id;

  if v_account.currency is null or v_account.deleted_at is not null
     or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  if v_account.owner_id <> p_leg_owner then
    raise exception 'A transfer can only be moved to another account belonging to the same person.';
  end if;

  return v_account.currency;
end;
$$;

revoke all on function public.transfer_leg_target_currency(uuid, uuid) from public, anon, authenticated;
