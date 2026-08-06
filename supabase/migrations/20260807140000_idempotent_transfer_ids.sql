-- Phase 11: create_transfer's two legs get gen_random_uuid()'d inside the
-- function body — the ONE write path in this codebase where the client
-- never supplies its own id (every single-transaction insert already does,
-- which is what makes THOSE retries "idempotent for free," per this
-- phase's own design note). An offline-outbox retry of a createTransfer
-- call that actually succeeded server-side, but whose response the client
-- never saw (killed mid-drain, connection dropped after commit), would
-- silently create a SECOND transfer with new random ids. Closing this
-- before the outbox exists to expose it, not after.
--
-- p_from_id/p_to_id are optional and default null → gen_random_uuid(),
-- so every existing caller (online, no outbox) is unaffected. The outbox
-- generates and persists both ids once, alongside the rest of the queued
-- payload, and passes them on every attempt including retries — a retry
-- against an already-applied transfer now hits transactions' PK unique
-- violation (23505) instead of duplicating the transfer; the client maps
-- that specific error to "already applied," not a real failure.

create or replace function create_transfer(
  p_from_account_id uuid,
  p_to_account_id uuid,
  p_from_amount numeric,
  p_to_amount numeric default null,
  p_occurred_at timestamptz default now(),
  p_from_id uuid default null,
  p_to_id uuid default null
)
returns setof transactions
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_from_owner uuid;
  v_from_currency text;
  v_to_owner uuid;
  v_to_currency text;
  v_to_amount numeric(20, 4);
  v_group uuid := gen_random_uuid();
begin
  if p_from_amount is null or p_from_amount <= 0 then
    raise exception 'from_amount must be a positive magnitude';
  end if;

  select owner_id, currency into v_from_owner, v_from_currency
  from public.accounts where id = p_from_account_id;
  select owner_id, currency into v_to_owner, v_to_currency
  from public.accounts where id = p_to_account_id;

  if v_from_currency is null or v_to_currency is null then
    raise exception 'one or both accounts were not found or are not accessible';
  end if;

  v_to_amount := coalesce(
    p_to_amount,
    case when v_from_currency = v_to_currency then p_from_amount end
  );
  if v_to_amount is null or v_to_amount <= 0 then
    raise exception 'to_amount is required for cross-currency transfers and must be a positive magnitude';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, amount, currency, occurred_at, transfer_group_id, source
  )
  values
    (
      coalesce(p_from_id, gen_random_uuid()), v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount, v_from_currency, p_occurred_at, v_group, 'manual'
    ),
    (
      coalesce(p_to_id, gen_random_uuid()), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount, v_to_currency, p_occurred_at, v_group, 'manual'
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;

grant execute on function create_transfer(uuid, uuid, numeric, numeric, timestamptz, uuid, uuid) to authenticated;

-- The 5-arg overload from migration 002 is now shadowed by the 7-arg
-- version's defaults but still resolves ambiguously at the SQL level
-- once two overloads exist with compatible defaults — drop it explicitly
-- rather than leave two functions doing the same job.
drop function if exists create_transfer(uuid, uuid, numeric, numeric, timestamptz);
