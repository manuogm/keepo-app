-- ============================================================================
-- delete_account: let the caller take the transactions with it.
--
-- Deleting an archived account used to be refusable and nothing more. The
-- function raised `account <uuid> has existing transactions — archive it
-- instead of deleting`, that P0001 message reached the user verbatim
-- (P0001 is how every RPC here writes a sentence *meant* for an end user,
-- so `UserFacingError` passes it straight through), and they read a raw
-- UUID mid-sentence with no way forward: the account was already archived,
-- so "archive it instead" was advice they had taken.
--
-- Two changes, both here rather than in the client. The refusal is now
-- written for a person, and `p_cascade` gives the caller a second, explicit
-- answer: take the transactions too. It defaults to false so a caller that
-- does not pass it keeps the old meaning — deleting an account's whole
-- history is never something to fall into.
--
-- **Order matters.** The account's own version is claimed *first*, and a
-- lost race returns `conflict` before a single transaction is touched. A
-- refusal (transactions present, no cascade) raises, which aborts the
-- function's transaction and rolls the account delete back with it. So the
-- three outcomes are: nothing changed, nothing changed, or all of it.
--
-- **Transfers.** A cascade soft-deletes only the legs belonging to *this*
-- account, never the paired leg in another one. Money that left this
-- account genuinely arrived in the other, and deleting the receiving leg
-- would silently change a live account's balance as a side effect of
-- deleting a different account — the one outcome that is never acceptable
-- here. The surviving leg renders as an ordinary row: `TransactionEntry
-- .collapsingTransfers` folds only *complete* pairs and passes a lone leg
-- through as-is.
--
-- **Recurring rules** on the account are retired (`active = false`, the way
-- this schema retires a rule — see 20260913100000 and 20260916100000; the
-- table has no `deleted_at`). Without it `materialize_due_recurring_rules`,
-- which selects on `active and next_due_at <= …` and never asks whether the
-- account still exists, would keep minting transactions onto a deleted
-- account — quietly undoing the delete the user just confirmed.
--
-- The 2-argument signature is dropped rather than left beside a 3-argument
-- one with a default: two overloads where one is reachable by defaulting is
-- how a call site silently binds to the wrong function.
-- ============================================================================

drop function if exists delete_account(uuid, integer);

create function delete_account(
  p_id uuid,
  p_expected_version integer,
  p_cascade boolean default false
)
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
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true;
    return;
  end if;

  if exists (select 1 from public.transactions where account_id = p_id and deleted_at is null) then
    if not p_cascade then
      raise exception 'This account still has transactions, so it cannot be deleted on its own.';
    end if;

    -- No version check on the transactions themselves. The account's
    -- version is the thing being raced for and it is claimed above; making
    -- every transaction agree as well would mean a delete that fails
    -- whenever any single row in a long history had moved, with nothing the
    -- user could do about it. `transactions_bump_version` still carries
    -- version and sync_seq for each updated row, so every one of these
    -- reaches the other devices as an ordinary tombstone.
    update public.transactions
    set deleted_at = now()
    where account_id = p_id and deleted_at is null;
  end if;

  update public.recurring_rules
  set active = false
  where account_id = p_id and active;

  return query select false;
end;
$$;

revoke all on function delete_account(uuid, integer, boolean) from public;
grant execute on function delete_account(uuid, integer, boolean) to authenticated;
