-- Unify account kinds: the ledger/valuation behavioral split is eliminated.
-- Every account now takes income/expense/transfer transactions and can have
-- cards mapped to it; balance for every account becomes the single formula
-- opening_balance_e4 + SUM(amount_e4). account_kind stays as a column
-- (renamed ledger->regular, valuation->investment) but becomes purely
-- presentational — it only drives whether the UI shows an "Investment"
-- badge, nothing else. account_subtype is removed entirely: nothing
-- branches on it once icon selection is defaulted by kind independently.
--
-- Pre-launch (no App Store users), but the hosted dev project does carry
-- real test accounts with real balance_snapshots-backed balances — this is
-- NOT a no-data forward-only change. Step 1.5 below is the data-preserving
-- part: it folds each account's current computed balance into
-- opening_balance_e4 before the formula unification and the
-- balance_snapshots drop, so no account's displayed balance moves.
--
-- Statement ordering in this single file (verified against a local
-- `supabase db reset` — ALTER TYPE ... RENAME VALUE is a catalog-only
-- rename of an existing pg_enum row, not ADD VALUE, so it carries none of
-- ADD VALUE's "unsafe use of new value in the same transaction" restriction
-- and the renamed labels are usable immediately afterward in this same
-- migration):
--   1. Drop the view/constraints/functions that must change shape first.
--   1.5. Fold every account's current balance into opening_balance_e4,
--        using the still-live (not yet redefined) account_balance_on.
--   2. Rename the two account_kind enum values.
--   3. Drop transactions.account_kind (composite FK + CHECK + column),
--      re-add a plain single-column FK on account_id.
--   4. Drop accounts.subtype (CHECK + column) and the account_subtype enum.
--   5. Redefine account_balance_on / set_account_balance to the single
--      ledger-shaped formula.
--   6. Redefine update_account, link_card_to_account, fork_one_account,
--      pull_changes, restamp_account_for_sync to drop every dead
--      subtype/balance_snapshots reference.
--   7. Drop balance_snapshots entirely (cascades its own RLS/grants/index/
--      trigger), and its fork_handled_tables registry row.
--   8. Recreate the three balance views without `subtype`.

-- ============================================================================
-- 1. Drop objects that reference accounts.subtype or transactions.account_kind
--    and must be rebuilt with a different shape.
-- ============================================================================

drop view if exists public.accounts_with_balances;
drop view if exists public.account_balances_base;
drop view if exists public.account_balances;

alter table public.transactions drop constraint valuation_transfers_only;
alter table public.transactions drop constraint transactions_account_id_account_kind_fkey;

-- ============================================================================
-- 1.5. Fold each account's balance, as computed by today's still-live (not
--      yet redefined) account_balance_on, into opening_balance_e4 — so the
--      upcoming single-formula redefinition (opening_balance + SUM(amount))
--      reproduces the exact same number afterward. A no-op for a ledger
--      account (its old formula already was opening_balance + SUM(amount)).
--      Load-bearing for a valuation account: its balance today includes a
--      balance_snapshots value that's about to be dropped along with the
--      table, and without this step that value would simply vanish from
--      the account's balance instead of being preserved.
-- ============================================================================

update public.accounts a
set opening_balance_e4 = coalesce(public.account_balance_on(a.id, current_date), 0) - coalesce((
  select sum(t.amount_e4) from public.transactions t
  where t.account_id = a.id and t.deleted_at is null and t.status = 'confirmed'
), 0)
where a.deleted_at is null;

-- ============================================================================
-- 2. Rename account_kind's two values. Every function body below that still
--    said 'ledger'/'valuation' is redefined in the same migration to say
--    'regular'/'investment' instead — never left half-renamed.
-- ============================================================================

alter type public.account_kind rename value 'ledger' to 'regular';
alter type public.account_kind rename value 'valuation' to 'investment';

-- ============================================================================
-- 3. transactions.account_kind: drop the mirror column entirely (it only
--    ever existed to let the composite FK + valuation_transfers_only CHECK
--    declaratively enforce "valuation accounts take transfers only" — both
--    already dropped above). Re-add a plain FK so account_id keeps a
--    referential-integrity guarantee on its own; the composite
--    (account_id, currency)/(account_id, owner_id) FKs are untouched.
-- ============================================================================

alter table public.transactions drop column account_kind;

alter table public.transactions
  add constraint transactions_account_id_fkey
  foreign key (account_id) references public.accounts (id) deferrable initially deferred;

-- set_transaction_derived_columns: stop populating account_kind: still
-- populates category_kind exactly as before.
create or replace function public.set_transaction_derived_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.category_id is not null then
    select kind into new.category_kind from public.categories where id = new.category_id;
  else
    new.category_kind := null;
  end if;

  return new;
end;
$$;

-- ============================================================================
-- 4. accounts.subtype: drop the CHECK, the column, then the now-unused
--    enum type. accounts_id_kind_key (UNIQUE (id, kind)) only ever existed
--    to let the composite FK from transactions.account_kind reference it —
--    that FK is gone, so the unique constraint is dead weight too.
-- ============================================================================

alter table public.accounts drop constraint subtype_matches_kind;
alter table public.accounts drop constraint accounts_id_kind_key;
alter table public.accounts drop column subtype;

-- account_subtype itself can't be dropped yet — update_account's current
-- signature still takes a p_subtype account_subtype parameter. Dropped
-- below, once step 7 drops that old signature.

-- ============================================================================
-- 5. account_balance_on: single formula, no more CASE on kind, no more
--    balance_snapshots lookup or fallback. Signature, STABLE marker, and
--    search_path unchanged; SECURITY (invoker, the default — this function
--    has never carried SECURITY DEFINER) unchanged too.
-- ============================================================================

create or replace function public.account_balance_on(p_account_id uuid, p_date date)
returns bigint
language sql
stable
set search_path = ''
as $$
  select a.opening_balance_e4 + coalesce((
    select sum(t.amount_e4)
    from public.transactions t
    where t.account_id = a.id
      and t.deleted_at is null
      and t.status = 'confirmed'
      and t.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
  ), 0)
  from public.accounts a
  where a.id = p_account_id;
$$;

revoke all on function public.account_balance_on(uuid, date) from public;
grant execute on function public.account_balance_on(uuid, date) to authenticated, service_role;

-- ============================================================================
-- 6. set_account_balance: collapse to the single (former-ledger) path —
--    every account now computes the gap against account_balance_on and
--    files an adjustment transaction. Idempotency pre-check and the
--    version-check-after-idempotency ordering are both preserved exactly;
--    only the kind branch and the balance_snapshots else-branch are gone.
-- ============================================================================

create or replace function public.set_account_balance(
  p_account_id uuid, p_new_balance_e4 bigint, p_expected_version integer, p_id uuid default null
)
returns table(transaction_id uuid, snapshot_id uuid, conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_account record;
  v_current bigint;
  v_gap bigint;
  v_category_id uuid;
  v_id uuid := coalesce(p_id, gen_random_uuid());
  v_txn_id uuid;
  v_owner uuid := (select auth.uid());
begin
  select id, currency, owner_id, version into v_account
  from public.accounts
  where id = p_account_id and deleted_at is null;

  if v_account.id is null or not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  -- Idempotency is checked BEFORE the version check, not after: a queued
  -- outbox write retried after a dropped ack must succeed silently even
  -- though the account's version has already moved past what the retry
  -- still claims to expect — it is not a concurrent edit, it is the same
  -- edit arriving twice. Only a v_id genuinely new to this account is
  -- subject to the version check at all.
  select id into v_txn_id from public.transactions where id = v_id;
  if v_txn_id is not null then
    return query select v_txn_id, null::uuid, false;
    return;
  end if;

  if v_account.version <> p_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_account_id, v_owner, p_expected_version, v_account.version);
    return query select null::uuid, null::uuid, true;
    return;
  end if;

  v_current := public.account_balance_on(p_account_id, current_date);
  v_gap := p_new_balance_e4 - v_current;

  if v_gap = 0 then
    return query select null::uuid, null::uuid, false;
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
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source, status
  )
  values (
    v_id, v_account.owner_id, v_owner, p_account_id, v_category_id, v_gap, v_account.currency,
    now(), 'adjustment', 'confirmed'
  )
  returning id into v_txn_id;

  update public.accounts set updated_at = now() where id = p_account_id;

  return query select v_txn_id, null::uuid, false;
end;
$$;

revoke all on function public.set_account_balance(uuid, bigint, integer, uuid) from public;
grant execute on function public.set_account_balance(uuid, bigint, integer, uuid) to authenticated;

-- ============================================================================
-- 7. update_account: drop p_subtype. Every account is now spendable, so the
--    "currency and kind are immutable" reasoning gains a second line: kind
--    was already immutable because it decided which balance formula
--    applied — that reason is gone now that there's only one formula, but
--    it stays immutable regardless, since it is still a real (presentational)
--    fact about the account that changing it out from under existing data
--    would be surprising, not because anything downstream depends on it for
--    correctness anymore. subtype is simply gone, not "still immutable" —
--    there is no column left to omit.
-- ============================================================================

drop function public.update_account(uuid, integer, text, public.account_subtype, bigint, boolean, text, text);

-- Now safe: nothing left references account_subtype.
drop type public.account_subtype;

create function public.update_account(
  p_id uuid, p_expected_version integer, p_name text,
  p_opening_balance_e4 bigint, p_include_in_total boolean, p_icon text, p_color text
)
returns table (conflict boolean, account accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set
    name = p_name,
    opening_balance_e4 = p_opening_balance_e4,
    include_in_total = p_include_in_total,
    icon = p_icon,
    color = p_color
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.update_account(uuid, integer, text, bigint, boolean, text, text) from public;
grant execute on function public.update_account(uuid, integer, text, bigint, boolean, text, text)
  to authenticated, service_role;

-- ============================================================================
-- 8. link_card_to_account: drop the "spendable (ledger) account" guard —
--    every account can now have a card mapped to it.
-- ============================================================================

create or replace function public.link_card_to_account(p_owner uuid, p_card_identifier text, p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = p_owner
      and deleted_at is null and archived_at is null
  ) then
    raise exception 'account not found, not accessible, or archived';
  end if;

  insert into public.card_mappings (owner_id, card_identifier, account_id)
  values (p_owner, p_card_identifier, p_account_id)
  on conflict (owner_id, card_identifier)
  do update set account_id = excluded.account_id, deleted_at = null, updated_at = now();
end;
$$;

revoke all on function public.link_card_to_account(uuid, text, uuid) from public;

-- ============================================================================
-- 9. fork_one_account: drop subtype from both insert column lists, drop the
--    balance_snapshots duplication block entirely (table is dropped below).
-- ============================================================================

create or replace function public.fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  select ha.household_id into v_household_id
  from public.household_accounts ha
  where ha.account_id = p_old_account_id and ha.deleted_at is null;

  if v_household_id is null then
    raise exception 'account not found or not shared with a household';
  end if;

  if not exists (
    select 1 from public.household_members hm
    where hm.household_id = v_household_id and hm.user_id = (select auth.uid()) and hm.deleted_at is null
  ) then
    raise exception 'caller is not a member of this account''s household';
  end if;

  if (
    select count(*) from public.household_members hm
    where hm.household_id = v_household_id and hm.deleted_at is null
      and hm.user_id in (p_member_a, p_member_b)
  ) <> 2 or p_member_a = p_member_b then
    raise exception 'p_member_a and p_member_b must be the two distinct members of this household';
  end if;

  insert into public.accounts (
    owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_a, p_member_a, kind, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_a;

  insert into public.accounts (
    owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_b, p_member_b, kind, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_b;

  insert into public.transactions (
    owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status
  )
  select
    fork.fork_owner, t.created_by, fork.fork_account_id,
    case
      when t.transfer_group_id is not null then (
        select id from public.categories
        where owner_id = fork.fork_owner
          and kind = case when t.amount_e4 < 0 then 'expense'::public.category_kind else 'income'::public.category_kind end
          and is_default and deleted_at is null
      )
      else public.fork_category_id(fork.fork_owner, t.category_id)
    end,
    t.amount_e4, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
    case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
    t.status
  from public.transactions t
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where t.account_id = p_old_account_id and t.deleted_at is null;

  insert into public.recurring_rules (created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at, active)
  select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
         rr.amount_e4, rr.currency, rr.frequency, rr.next_due_at, rr.active
  from public.recurring_rules rr
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where rr.account_id = p_old_account_id;

  update public.card_mappings
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  update public.csv_import_batches
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  update public.csv_import_candidates
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  delete from public.net_worth_daily where account_id = p_old_account_id;
  update public.household_accounts set deleted_at = now()
  where account_id = p_old_account_id and deleted_at is null;
  update public.accounts set archived_at = coalesce(archived_at, now()) where id = p_old_account_id;
end;
$$;

-- CREATE OR REPLACE FUNCTION preserves the existing ACL — reasserted
-- explicitly anyway, matching this repo's own precedent of never leaving a
-- security-relevant grant implicit.
revoke all on function public.fork_one_account(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.fork_one_account(uuid, uuid, uuid) to postgres;

-- ============================================================================
-- 10. restamp_account_for_sync: drop the balance_snapshots restamp line.
-- ============================================================================

create or replace function public.restamp_account_for_sync(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('keepo.restamp_only', 'true', true);
  update public.accounts set id = id where id = p_account_id;
  update public.transactions set id = id where account_id = p_account_id and deleted_at is null;
  update public.recurring_rules set id = id where account_id = p_account_id;
  perform set_config('keepo.restamp_only', 'false', true);
end;
$$;

revoke all on function public.restamp_account_for_sync(uuid) from public, anon, authenticated;
grant execute on function public.restamp_account_for_sync(uuid) to postgres;

-- ============================================================================
-- 11. pull_changes: drop balance_snapshots from both the payload and the
--     cursor computation. Body otherwise byte-identical to
--     20260828100000_generalize_rate_limiting.sql's definition.
-- ============================================================================

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  if not public.ops_check_own_rate_limit('pull_changes', 30, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('rate_to_eur', fr.rate_to_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(bud)) from public.budgets bud where bud.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rules', coalesce((select jsonb_agg(to_jsonb(rr)) from public.recurring_rules rr where rr.sync_seq > p_cursor), '[]'::jsonb),
    'card_mappings', coalesce((select jsonb_agg(to_jsonb(cm)) from public.card_mappings cm where cm.sync_seq > p_cursor), '[]'::jsonb),
    'merchant_category_map', coalesce((select jsonb_agg(to_jsonb(mcm)) from public.merchant_category_map mcm where mcm.sync_seq > p_cursor), '[]'::jsonb),
    'sync_conflicts', coalesce((select jsonb_agg(to_jsonb(sc)) from public.sync_conflicts sc where sc.sync_seq > p_cursor), '[]'::jsonb),
    'households', coalesce((select jsonb_agg(to_jsonb(h)) from public.households h where h.sync_seq > p_cursor), '[]'::jsonb),
    'household_members', coalesce((select jsonb_agg(to_jsonb(hm)) from public.household_members hm where hm.sync_seq > p_cursor), '[]'::jsonb),
    'household_accounts', coalesce((select jsonb_agg(to_jsonb(ha)) from public.household_accounts ha where ha.sync_seq > p_cursor), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(to_jsonb(p)) from public.profiles p where p.sync_seq > p_cursor), '[]'::jsonb)
  ) into v_payload;

  select coalesce(max(m), p_cursor) into v_next_cursor from (
    select max(sync_seq) as m from public.accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.transactions where sync_seq > p_cursor
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.budgets where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rules where sync_seq > p_cursor
    union all select max(sync_seq) from public.card_mappings where sync_seq > p_cursor
    union all select max(sync_seq) from public.merchant_category_map where sync_seq > p_cursor
    union all select max(sync_seq) from public.sync_conflicts where sync_seq > p_cursor
    union all select max(sync_seq) from public.households where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_members where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.profiles where sync_seq > p_cursor
  ) s;

  select coalesce(max(m), p_global_cursor) into v_next_global_cursor from (
    select max(sync_seq) as m from public.currencies where sync_seq > p_global_cursor
    union all select max(sync_seq) from public.fx_rates where sync_seq > p_global_cursor
  ) g;

  return query select v_payload, v_next_cursor, v_next_global_cursor, v_epoch;
end;
$$;

revoke all on function public.pull_changes(bigint, bigint) from public, anon;
grant execute on function public.pull_changes(bigint, bigint) to authenticated;

-- ============================================================================
-- 12. Drop balance_snapshots entirely — cascades its own RLS policies,
--     grants, index, and stamp_sync_seq trigger (all belong to the table).
--     Its fork_handled_tables registry row goes with it: with no
--     balance_snapshots table left, fork_one_account's own
--     information_schema guard (in the caller, fork_household_accounts)
--     would otherwise flag a phantom "unregistered account_id-bearing
--     table" that no longer exists.
-- ============================================================================

delete from public.fork_handled_tables where table_name = 'balance_snapshots';

drop table public.balance_snapshots;

-- ============================================================================
-- 13. Views: account_balances / account_balances_base / accounts_with_balances
--     recreated without `subtype`. account_balances/account_balances_base
--     otherwise byte-identical to 20260820100000's definitions (no CASE on
--     kind, no balance_snapshots reference, already true before this
--     migration). accounts_with_balances drops `a.subtype` from its select
--     list; every other column, join, and the security_invoker clause are
--     unchanged from 20260830100000's definition.
-- ============================================================================

create view public.account_balances
with (security_invoker = true) as
select id as account_id, currency, public.account_balance_on(id, current_date) as balance_e4
from public.accounts
where deleted_at is null;

create view public.account_balances_base
with (security_invoker = true) as
select
  ab.account_id,
  ab.currency,
  ab.balance_e4,
  a.owner_id,
  p.base_currency,
  public.fx_convert(ab.balance_e4, ab.currency, p.base_currency, current_date) as balance_base_e4,
  ab.balance_e4 is not null
    and public.fx_convert(ab.balance_e4, ab.currency, p.base_currency, current_date) is null as has_missing_rate,
  a.archived_at
from public.account_balances ab
join public.accounts a on a.id = ab.account_id
left join public.profiles p on p.id = (select auth.uid());

create view public.accounts_with_balances
with (security_invoker = true) as
select
  a.id as account_id, a.name, a.kind, a.currency, c.minor_unit,
  a.include_in_total, a.icon, a.color, a.archived_at,
  ab.balance_e4, abb.base_currency, bc.minor_unit as base_minor_unit,
  abb.balance_base_e4, abb.has_missing_rate, a.version,
  exists (select 1 from public.household_accounts ha where ha.account_id = a.id) as is_shared
from public.accounts a
  join public.account_balances ab on ab.account_id = a.id
  join public.currencies c on c.code = a.currency
  join public.account_balances_base abb on abb.account_id = a.id
  left join public.currencies bc on bc.code = abb.base_currency;

grant select on public.account_balances to authenticated;
grant select on public.account_balances_base to authenticated;
grant select on public.accounts_with_balances to authenticated, service_role;
