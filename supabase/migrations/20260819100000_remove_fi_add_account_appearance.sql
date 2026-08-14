-- Deliberate pre-launch feature removal, not a bug fix: Insights and
-- Financial Independence are being pulled before shipping (the screen and
-- the underlying RPCs), and `counts_toward_fi` goes with it since it was
-- FI's own column with no other consumer. Budgets is untouched — it was
-- always a separate feature that happened to share one migration file
-- with fi_settings (20260808150000_budgets_fi.sql) back when both landed
-- together; nothing budgets-related is touched here.
--
-- Combined with, in the same migration, the accounts equivalent of
-- categories.icon/categories.color (20260813100000_category_appearance.sql)
-- — same pattern, same reasoning (icon/color are UI concerns, plain text,
-- no new enum).

-- ============================================================================
-- Drop Insights RPCs (20260808130000_insights.sql)
-- ============================================================================
drop function if exists spending_by_category(account_scope, date, date);
drop function if exists income_expense_series(account_scope, date, date, text);
drop function if exists savings_rate(account_scope, date, date);
drop function if exists unrealized_gain(uuid);

-- ============================================================================
-- Drop FI metrics + settings (20260808150000_budgets_fi.sql)
-- ============================================================================
drop function if exists fi_metrics(account_scope);

-- pull_changes hardcodes fi_settings in both its payload and its cursor
-- computation — redefined here with those two references removed. Every
-- other table/branch is unchanged from the current definition.
create or replace function pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'balance_snapshots', coalesce((select jsonb_agg(to_jsonb(bs)) from public.balance_snapshots bs where bs.sync_seq > p_cursor), '[]'::jsonb),
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
    union all select max(sync_seq) from public.balance_snapshots where sync_seq > p_cursor
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

-- Cascade drops fi_settings' own sync_seq trigger, RLS policies, and grants
-- along with it — nothing else references the table.
drop table if exists fi_settings cascade;

-- Re-seed without the fi_settings row each of these used to insert.
-- Everything else in both functions is unchanged.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);

  insert into public.categories (owner_id, kind, name, is_default)
  values (new.id, 'expense', 'Other', true), (new.id, 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  return new;
end;
$$;

create or replace function ensure_user_bootstrap()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (auth.uid())
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (auth.uid(), 'expense', 'Other', true), (auth.uid(), 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;
end;
$$;

-- ============================================================================
-- accounts.counts_toward_fi drop + accounts.icon/accounts.color add — done
-- together since three other objects touch counts_toward_fi by name and
-- must be redefined in the same breath: update_account (a parameter),
-- accounts_with_balances (a select-list column), and fork_one_account
-- (two explicit insert column lists, used by leave-household). All three
-- also gain icon/color where relevant, same reasoning as
-- 20260813100000_category_appearance.sql for categories: plain text, no
-- new enum, freely editable.
-- ============================================================================

-- Columns added before anything is dropped: accounts_with_balances gets
-- rebuilt below referencing icon/color, and PostgreSQL only allows
-- `CREATE OR REPLACE VIEW` to add trailing columns, never remove one from
-- the middle of the list — the view has to be dropped and recreated fresh
-- to lose counts_toward_fi from its output, which in turn requires
-- counts_toward_fi to still exist on the table until that DROP VIEW runs.
alter table accounts add column icon text not null default 'banknote';
alter table accounts add column color text not null default '#8E8E93';

drop view if exists accounts_with_balances;

-- update_account's parameter list changes (drop p_counts_toward_fi, add
-- p_icon/p_color) — CREATE OR REPLACE can't change a function's parameter
-- list, so the old signature is dropped first.
drop function if exists update_account(uuid, integer, text, account_subtype, bigint, boolean, boolean);

alter table accounts drop column if exists counts_toward_fi;

-- Backfill deliberately runs after every ALTER TABLE on accounts in this
-- migration, never before: an UPDATE queues accounts' sync_seq-stamping
-- trigger's event for end-of-transaction, and Postgres refuses any
-- subsequent ALTER TABLE on that same table while a trigger event is still
-- pending (error 55006, confirmed against hosted) — found the hard way,
-- since a fresh `db reset` never exercises "several statements in one
-- transaction" the way pushing a single multi-statement migration does.
--
-- Sensible kind-based default rather than a name-keyword heuristic (there is
-- no CategoryKind-style axis on an account to key one off) — everyday
-- (ledger) accounts default to a plain banknote, investment (valuation)
-- accounts to a trend-line icon, both then freely editable in the form
-- exactly like a category's icon/color already is.
update accounts set icon = 'chart.line.uptrend.xyaxis' where kind = 'valuation';
update accounts
set color = '#' || substr(md5(id::text || clock_timestamp()::text), 1, 6)
where true;

create function update_account(
  p_id uuid, p_expected_version integer, p_name text, p_subtype account_subtype,
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
    subtype = p_subtype,
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

revoke all on function update_account(uuid, integer, text, account_subtype, bigint, boolean, text, text) from public;
grant execute on function update_account(uuid, integer, text, account_subtype, bigint, boolean, text, text)
  to authenticated, service_role;

-- accounts_with_balances: drop counts_toward_fi, add icon/color to the
-- select list — every other column and join is unchanged.
create view accounts_with_balances as
select
  a.id as account_id, a.name, a.kind, a.subtype, a.currency, c.minor_unit,
  a.include_in_total, a.icon, a.color, a.archived_at,
  ab.balance_e4, abb.base_currency, bc.minor_unit as base_minor_unit,
  abb.balance_base_e4, abb.has_missing_rate, a.version,
  exists (select 1 from household_accounts ha where ha.account_id = a.id) as is_shared
from accounts a
  join account_balances ab on ab.account_id = a.id
  join currencies c on c.code = a.currency
  join account_balances_base abb on abb.account_id = a.id
  left join currencies bc on bc.code = abb.base_currency;

grant select on accounts_with_balances to authenticated;

-- fork_one_account (leave-household): both insert column lists drop
-- counts_toward_fi and carry icon/color across to the forked replica —
-- an account's appearance is exactly as much "its own" as its name.
create or replace function fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  insert into public.accounts (
    owner_id, created_by, kind, subtype, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_a, p_member_a, kind, subtype, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_a;

  insert into public.accounts (
    owner_id, created_by, kind, subtype, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_b, p_member_b, kind, subtype, name, currency,
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

  insert into public.balance_snapshots (account_id, currency, as_of, value_e4, created_by)
  select fork.fork_account_id, bs.currency, bs.as_of, bs.value_e4, bs.created_by
  from public.balance_snapshots bs
  cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
  where bs.account_id = p_old_account_id;

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
