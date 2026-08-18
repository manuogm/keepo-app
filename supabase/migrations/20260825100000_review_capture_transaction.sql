-- Collapses the Needs Review "review, then confirm" flow from two writes
-- into one. The client used to call update_transaction (the edit) and
-- confirm_capture_transaction (the status flip) as two separate,
-- independently-queued outbox writes sharing one row and one version
-- counter — correct only if they arrive in that order, which nothing
-- guaranteed. When the confirm won the race, it sent
-- expectedVersion + 1 against a row the edit hadn't touched yet, the
-- server logged a real sync_conflicts row, and the outbox treated that as
-- "delivered" (conflict-as-data, exactly like every other version-checked
-- write) — so the edit's own queued item, now version-mismatched too, was
-- never retried. Worse offline: the outbox's own collapse-by-row-id rule
-- (Outbox.enqueue) let the confirm silently overwrite the still-undelivered
-- edit outright, discarding the user's account/category/amount choice
-- entirely.
--
-- One statement, one version bump, removes the race and the collapse
-- hazard by construction: there is only ever one queued item for a review.
--
-- Also folds in merchant learning (a gap that meant Needs Review's category
-- suggestion never actually improved): every review upserts
-- merchant_category_map for the transaction's own merchant_normalized, so
-- the next capture from the same merchant resolves to the category the
-- user actually chose, not just the owner's default fallback.
--
-- confirm_capture_transaction stays — it's still the right call for the
-- Transactions/Needs Review swipe-to-confirm action, which makes no edit at
-- all and has nothing to review.

create function public.review_capture_transaction(
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

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    status = 'confirmed'
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);
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

revoke all on function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) from public;
grant execute on function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) to authenticated;
