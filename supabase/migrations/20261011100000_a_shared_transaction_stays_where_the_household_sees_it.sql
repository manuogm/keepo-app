-- A shared transaction stays where the household sees it.
--
-- The "rows that leave a partner's view" decision of the "Transfers &
-- household sharing" workstream (keepo-v1-master-plan.md): the user chose to
-- refuse the move rather than track departures (2026-09-24).
--
-- A device learns about a row only from `pull_changes`, which runs as the
-- caller, so RLS decides what it sends. An edit that takes a live row out of a
-- household's view hides it from the very pull that should report the change:
-- the partner's device keeps its stale copy forever. Two edits do it:
--
--   * moving a shared transaction to an account the household cannot see
--     (possible before this workstream, start date or not);
--   * re-dating one to before its account's start date, which is worse — the
--     carried opening re-sent by 20261010100000 already includes the row, so
--     the partner's device counts it twice.
--
-- Both are now refused, with a sentence saying what to do instead: delete the
-- row and add it again. A deletion stays inside the view, so the tombstone
-- reaches the partner, and the new row lands wherever the owner wants it.
--
-- The rest stays free: a row that was never in the view (private, or before
-- the start date) moves anywhere; one in the view moves anywhere else inside
-- the same household's view; unsharing an account takes it out of the view
-- as a whole, which the device handles separately (its sync epoch).
--
-- A trigger rather than a check per RPC, so every write path — the three
-- RPCs that move a row, a privileged write, and anything written
-- later — meets the same rule. The partner's own re-date before the start
-- date is refused earlier, by `assert_transaction_date_visible` in the RPC.
--
-- `realign_recurring_occurrences` shifts old recurring rows by under a day and
-- could in principle cross a start date. It cannot in practice: it touches
-- rows written under a convention retired before any share could carry a
-- start date, and a start date is always the day a share begins.

create function public.keep_shared_transaction_in_view()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household uuid;
  v_noun text := case when new.transfer_group_id is null then 'transaction' else 'transfer' end;
begin
  if old.deleted_at is not null then
    return new;
  end if;

  v_household := public.transaction_shared_into(old.account_id, old.occurred_at);

  if v_household is null
     or public.transaction_shared_into(new.account_id, new.occurred_at) is not distinct from v_household then
    return new;
  end if;

  if new.account_id is distinct from old.account_id
     and public.transaction_shared_into(new.account_id, now()) is distinct from v_household then
    raise exception 'This % is shared with your household, so it can''t be moved to an account they can''t see. Delete it and add it again on that account.', v_noun;
  end if;

  raise exception 'Your household sees this account''s transactions from the day you shared it, so this % can''t be moved before that date. Delete it and add it again with the earlier date.', v_noun;
end;
$$;

revoke all on function public.keep_shared_transaction_in_view() from public, anon, authenticated;

create trigger transactions_keep_shared_in_view
  before update of account_id, occurred_at on public.transactions
  for each row
  when (old.account_id is distinct from new.account_id or old.occurred_at is distinct from new.occurred_at)
  execute function public.keep_shared_transaction_in_view();
