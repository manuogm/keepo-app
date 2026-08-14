-- Budgets (migration 20260808150000_budgets_fi.sql): uniqueness,
-- budget_progress's transfer exclusion and null-propagation, period_month
-- normalization, and RLS. Fixture A = 11111111-... (base EUR).
--
-- FI's own assertions (fi_settings/fi_metrics) were removed alongside FI
-- itself (20260819100000_remove_fi_add_account_appearance.sql) — Budgets
-- was always a separate feature that happened to share this migration
-- file, and stays.

\ir _helpers.psql

begin;
select plan(11);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a6000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 100000000);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a6000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'A House', 'EUR', 3000000000);
insert into categories (id, owner_id, kind, name)
values
  ('c6000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Groceries'),
  ('c6000000-0000-0000-0000-000000000002', auth.uid(), 'income', 'Salary');

-- 1. A budget's period_month is normalized to the first of its month.
insert into budgets (id, owner_id, category_id, period_month, amount_e4, currency)
values (
  'b6000000-0000-0000-0000-000000000001', auth.uid(), 'c6000000-0000-0000-0000-000000000001',
  current_date, 3000000, 'EUR'
);

select is(
  (select period_month from budgets where id = 'b6000000-0000-0000-0000-000000000001'),
  date_trunc('month', current_date)::date,
  'period_month is normalized to the first of the month regardless of the date supplied'
);

-- 2. A second category budget for the same category+month is refused.
select throws_ok(
  $$
    insert into budgets (owner_id, category_id, period_month, amount_e4, currency)
    values ('11111111-1111-1111-1111-111111111111', 'c6000000-0000-0000-0000-000000000001', current_date, 9990000, 'EUR')
  $$,
  '23505', null,
  'a second budget for the same category and month is refused'
);

-- 3. An overall (category_id null) budget for the same month.
insert into budgets (id, owner_id, category_id, period_month, amount_e4, currency)
values ('b6000000-0000-0000-0000-000000000002', auth.uid(), null, current_date, 10000000, 'EUR');

-- 4. A second overall budget for the same month is refused — NULL doesn't
-- silently dodge the uniqueness rule.
select throws_ok(
  $$
    insert into budgets (owner_id, category_id, period_month, amount_e4, currency)
    values ('11111111-1111-1111-1111-111111111111', null, current_date, 9990000, 'EUR')
  $$,
  '23505', null,
  'a second overall budget for the same month is refused'
);

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000001', -1200000, 'EUR', now());
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000002', 40000000, 'EUR', now() - interval '10 days');

-- 5-6. budget_progress reports both the category-specific and the overall
-- budget correctly, and excludes income entirely (the overall budget is a
-- spending cap, not a net figure).
select is(
  (select spent_e4 from budget_progress(current_date) where category_id = 'c6000000-0000-0000-0000-000000000001'),
  1200000::bigint,
  'budget_progress reports actual spend for a category-specific budget'
);

select is(
  (select spent_e4 from budget_progress(current_date) where category_id is null),
  1200000::bigint,
  'the overall budget''s spend is total expense activity, excluding income'
);

-- 7. A transfer never counts toward any budget's spend.
select create_transfer('a6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000002', 5000000);

select is(
  (select spent_e4 from budget_progress(current_date) where category_id is null),
  1200000::bigint,
  'a transfer never counts toward budget_progress''s spend'
);

-- 8. A missing FX rate on a contributing transaction propagates to null,
-- distinguished from "no spend yet" (money rule 5).
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000001', -300000, 'GBP', now());

select is(
  (select spent_e4 from budget_progress(current_date) where category_id = 'c6000000-0000-0000-0000-000000000001'),
  null::bigint,
  'a category budget''s spend renders null when any contributing transaction can''t be converted'
);

select is(
  (select count(*) from budget_progress((current_date + interval '2 months')::date)),
  0::bigint,
  'a month with no budget rows at all returns no rows from budget_progress'
);

-- ----------------------------------------------------------------------------
-- 9-11. RLS: fixture B sees none of fixture A's budgets.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from budgets),
  0::bigint,
  'fixture B sees none of fixture A''s budgets'
);

select is(
  (select count(*) from budget_progress(current_date)),
  0::bigint,
  'fixture B''s budget_progress is empty for fixture A''s month'
);

-- RLS filters the row out of UPDATE's own visible set rather than raising
-- (confirmed empirically in Phase 14's suite) — the update matches zero
-- rows, verified as postgres afterward that it's genuinely untouched.
update budgets set amount_e4 = 10000 where id = 'b6000000-0000-0000-0000-000000000001';

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select amount_e4 from budgets where id = 'b6000000-0000-0000-0000-000000000001'),
  3000000::bigint,
  'fixture B''s update matched zero rows — fixture A''s budget is untouched'
);

select * from finish();
rollback;
