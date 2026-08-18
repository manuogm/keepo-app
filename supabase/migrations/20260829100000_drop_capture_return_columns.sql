-- X-05 (Wave 4 cleanup): capture_transaction has returned table(mapped
-- boolean, account_id uuid) since it was first written, but migration
-- 20260822100000 made the transaction insert unconditional — the row lands
-- either way — so `mapped` stopped distinguishing "captured" from "not
-- captured" the moment that shipped. CaptureRepository.capture() has never
-- decoded the return value (its own comment already says so); this just
-- makes the function's own signature match what it's actually used for.
--
-- Body is otherwise byte-identical to 20260828100000_generalize_rate_
-- limiting.sql's redefinition — only the `returns table(...)` clause and
-- the trailing `return query select ...` change.

-- Postgres refuses to `create or replace` a function across a return-type
-- change (table(...) -> void) — drop first, same as any other signature
-- change to an existing function.
drop function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text);

create function public.capture_transaction(
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
end;
$$;

revoke all on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) from public;
grant execute on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) to authenticated;
