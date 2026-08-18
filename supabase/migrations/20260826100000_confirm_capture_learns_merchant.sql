-- C-01's merchant-learning upsert only shipped inside review_capture_transaction
-- (the edit-then-confirm path). The plain swipe-to-confirm path —
-- confirm_capture_transaction, which makes no edit at all — left the same gap
-- open: confirming a pending capture with the default "Other" category never
-- taught merchant_category_map anything, so the next capture from that
-- merchant still fell back to the default. Same upsert, same place it
-- happens in review_capture_transaction, just added to the other RPC that
-- can flip status to confirmed.

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
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);
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

revoke all on function public.confirm_capture_transaction(uuid, int) from public;
grant execute on function public.confirm_capture_transaction(uuid, int) to authenticated;
