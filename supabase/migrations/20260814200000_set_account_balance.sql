-- set_account_balance — lets the user tell Keepo "this account is worth X
-- right now" at any time, for either account kind, closing the gap left
-- when Sync Ritual was removed: a valuation account had no way left to
-- record a new value (its balance is defined as "latest snapshot + SUM of
-- transfers after it", and nothing wrote a new snapshot once reconcile_
-- valuation_account was dropped).
--
-- Ledger: the gap between the entered value and the account's own
-- computed balance becomes a single adjustment transaction, filed under
-- the owner's default "Other" category of the matching sign — exactly
-- what a manual adjustment always was, just without the "Sync Ritual"
-- framing around it. Computing account_balance_on(id, current_date)
-- *inside* the RPC, not trusting a client-supplied "current balance", is
-- what makes this correct even when the write was queued offline and
-- replays later against however the balance actually stands by then.
--
-- Valuation: a plain new balance_snapshots row, current_date, no
-- transaction — never has been (a valuation change is a market move, not
-- income or expense; money rule 1).
--
-- Idempotent via a client-supplied id (same pattern as create_transfer's
-- idempotent leg ids): a queued write replayed twice must not create two
-- adjustment transactions or two snapshots.

create function set_account_balance(
  p_account_id uuid,
  p_new_balance numeric,
  p_id uuid default null
)
returns table (transaction_id uuid, snapshot_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account record;
  v_current numeric(20, 4);
  v_gap numeric(20, 4);
  v_category_id uuid;
  v_id uuid := coalesce(p_id, gen_random_uuid());
  v_txn_id uuid;
  v_snapshot_id uuid;
begin
  select id, kind, currency, owner_id into v_account
  from public.accounts
  where id = p_account_id and deleted_at is null;

  if v_account.id is null or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  if v_account.kind = 'ledger' then
    v_current := public.account_balance_on(p_account_id, current_date);
    v_gap := p_new_balance - v_current;

    if v_gap = 0 then
      return query select null::uuid, null::uuid;
      return;
    end if;

    select id into v_category_id
    from public.categories
    where owner_id = v_account.owner_id
      and kind = case when v_gap > 0 then 'income'::public.category_kind else 'expense'::public.category_kind end
      and is_default and deleted_at is null;

    if v_category_id is null then
      raise exception 'no default category found to file the adjustment under';
    end if;

    insert into public.transactions (
      id, owner_id, created_by, account_id, category_id, amount, currency, occurred_at, source, status
    )
    values (
      v_id, v_account.owner_id, (select auth.uid()), p_account_id, v_category_id, v_gap, v_account.currency,
      now(), 'adjustment', 'confirmed'
    )
    on conflict (id) do nothing
    returning id into v_txn_id;

    return query select coalesce(v_txn_id, v_id), null::uuid;
  else
    insert into public.balance_snapshots (id, account_id, currency, as_of, value, created_by)
    values (v_id, p_account_id, v_account.currency, current_date, p_new_balance, (select auth.uid()))
    on conflict (id) do nothing
    returning id into v_snapshot_id;

    return query select null::uuid, coalesce(v_snapshot_id, v_id);
  end if;
end;
$$;

revoke all on function set_account_balance(uuid, numeric, uuid) from public;
grant execute on function set_account_balance(uuid, numeric, uuid) to authenticated;

-- ============================================================================
-- account_balance_on: close a tie-break gap this migration makes easier to
-- hit. The valuation branch picked the latest snapshot by `as_of desc`
-- alone, with no secondary sort — `unrealized_gain` already tiebreaks the
-- identical "latest snapshot" lookup with `as_of desc, created_at desc`,
-- and this RPC now makes two same-day snapshots (two balance edits in one
-- day) a realistic case rather than a theoretical one. Same fix, same
-- ordering, no signature change.
-- ============================================================================

create or replace function account_balance_on(p_account_id uuid, p_date date)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select
    case a.kind
      when 'ledger' then a.opening_balance + coalesce((
        select sum(t.amount)
        from public.transactions t
        where t.account_id = a.id
          and t.deleted_at is null
          and t.status = 'confirmed'
          and t.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
      ), 0)
      when 'valuation' then (
        select bs.value + coalesce((
          select sum(t2.amount)
          from public.transactions t2
          where t2.account_id = a.id
            and t2.deleted_at is null
            and t2.status = 'confirmed'
            and t2.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
            and t2.occurred_at > bs.created_at
        ), 0)
        from public.balance_snapshots bs
        where bs.account_id = a.id and bs.as_of <= p_date
        order by bs.as_of desc, bs.created_at desc
        limit 1
      )
    end
  from public.accounts a
  where a.id = p_account_id;
$$;

revoke all on function account_balance_on(uuid, date) from public;
grant execute on function account_balance_on(uuid, date) to authenticated, service_role;
