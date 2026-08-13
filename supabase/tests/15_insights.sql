-- Insights & savings rate (migration 20260808130000_insights.sql):
-- transfer/valuation-change exclusion, null-propagation on a missing FX
-- rate, scope filtering, and unrealized_gain. Fixture A = 11111111-...
-- (base EUR), fixture B = 22222222-... (base USD).

\ir _helpers.psql

begin;
select plan(16);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a5000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 10000000);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a5000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Savings', 'EUR', 0);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a5000000-0000-0000-0000-000000000003', auth.uid(), auth.uid(), 'valuation', 'investment', 'A Brokerage', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values
  ('c5000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Groceries'),
  ('c5000000-0000-0000-0000-000000000002', auth.uid(), 'income', 'Salary');

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a5000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001', -600000, 'EUR', now() - interval '3 days');
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a5000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001', -400000, 'EUR', now() - interval '2 days');
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a5000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000002', 10000000, 'EUR', now() - interval '2 days');

-- 1. spending_by_category sums two expenses in the same category.
select is(
  (select total_e4 from spending_by_category('total', current_date - 10, current_date)
   where category_id = 'c5000000-0000-0000-0000-000000000001'),
  1000000::bigint,
  'spending_by_category sums multiple expenses in the same category'
);

-- 2-3. Scope filtering: sharing the checking account makes its spending
-- show up under 'household' but drop out of 'me', for the same owner. Done
-- here, before the GBP row below makes the category's total null for
-- every scope — a null-propagation test and a scope-filtering test would
-- otherwise interfere with each other.
select share_account('a5000000-0000-0000-0000-000000000001');

select is(
  (select count(*) from spending_by_category('me', current_date - 10, current_date)
   where category_id = 'c5000000-0000-0000-0000-000000000001'),
  0::bigint,
  'a shared account''s spending drops out of the ''me'' scope'
);

select is(
  (select total_e4 from spending_by_category('household', current_date - 10, current_date)
   where category_id = 'c5000000-0000-0000-0000-000000000001'),
  1000000::bigint,
  'a shared account''s spending appears under the ''household'' scope'
);

-- 4. A transfer between two of A's own accounts never appears — it has no
-- category_id at all (the CHECK constraint's own guarantee).
select create_transfer('a5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', 2000000);

select is(
  (select count(*) from spending_by_category('total', current_date - 10, current_date)
   where category_name in ('A Savings', 'A Checking')),
  0::bigint,
  'a transfer never appears in spending_by_category (transfers have no category)'
);

-- 3. income_expense_series buckets correctly and a transfer contributes to
-- neither income nor expense.
select is(
  (select sum(income_e4) from income_expense_series('total', current_date - 10, current_date, 'weekly')),
  10000000::numeric,
  'income_expense_series totals income across buckets, excluding the transfer'
);

select is(
  (select sum(expense_e4) from income_expense_series('total', current_date - 10, current_date, 'weekly')),
  1000000::numeric,
  'income_expense_series totals expense across buckets, excluding the transfer'
);

-- 4. savings_rate = (income - expense) / income, unaffected by the transfer.
select is(
  savings_rate('total', current_date - 10, current_date),
  0.9::numeric,
  'savings_rate is (income - expense) / income, excluding the transfer'
);

-- 5. Zero income in the window renders null, never a divide-by-zero.
select is(
  savings_rate('total', current_date + 1, current_date + 30),
  null::numeric,
  'savings_rate is null (not 0, not an error) when there is no income in the window'
);

-- 6. A missing FX rate propagates to null for the whole category, never a
-- silently-partial sum — money rule 5. GBP has no fx_rates row anywhere in
-- this suite's fixtures.
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a5000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001', -300000, 'GBP', now());

select is(
  (select total_e4 from spending_by_category('total', current_date - 10, current_date)
   where category_id = 'c5000000-0000-0000-0000-000000000001'),
  null::bigint,
  'a category with any unconvertible transaction renders null, not a partial sum'
);

select is(
  savings_rate('total', current_date - 10, current_date),
  null::numeric,
  'savings_rate is null when any contributing amount cannot be converted'
);

-- 7-8. unrealized_gain: latest valuation minus every transfer ever.
select create_transfer('a5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000003', 5000000);

select is(
  unrealized_gain('a5000000-0000-0000-0000-000000000003'),
  null::bigint,
  'unrealized_gain is null before any balance_snapshot exists'
);

insert into balance_snapshots (account_id, as_of, value_e4, currency, created_by)
values ('a5000000-0000-0000-0000-000000000003', current_date, 6000000, 'EUR', auth.uid());

select is(
  unrealized_gain('a5000000-0000-0000-0000-000000000003'),
  1000000::bigint,
  'unrealized_gain is the latest valuation minus every transfer ever (600 - 500)'
);

-- ----------------------------------------------------------------------------
-- 11-14. RLS: fixture B sees none of fixture A's insights, and the RPCs
-- are ordinary `authenticated`-callable functions, unlike Phase 13/14's
-- `service_role`-only ops surface — these ARE meant to be called by the app.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from spending_by_category('total', current_date - 10, current_date)),
  0::bigint,
  'fixture B sees none of fixture A''s categories in spending_by_category'
);

select is(
  (select count(*) from income_expense_series('total', current_date - 10, current_date, 'weekly')),
  0::bigint,
  'fixture B sees none of fixture A''s activity in income_expense_series'
);

select is(
  savings_rate('total', current_date - 10, current_date),
  null::numeric,
  'fixture B''s savings_rate over fixture A''s window is null (no income, no expense)'
);

select is(
  unrealized_gain('a5000000-0000-0000-0000-000000000003'),
  null::bigint,
  'fixture B cannot read fixture A''s balance_snapshots via unrealized_gain'
);

select * from finish();
rollback;
