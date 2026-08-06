-- Budgets & FI (migration 20260808150000_budgets_fi.sql): budget
-- uniqueness, budget_progress's transfer exclusion and null-propagation,
-- period_month normalization, fi_metrics' math and counts_toward_fi
-- filtering, and RLS. Fixture A = 11111111-... (base EUR).

\ir _helpers.psql

begin;
select plan(20);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. fi_settings already exists (seeded by handle_new_user() at signup,
-- via _helpers.psql's fixture creation) with the documented defaults.
select is(
  (select withdrawal_rate from fi_settings where owner_id = auth.uid()),
  0.04::numeric,
  'fi_settings is seeded automatically with the default withdrawal_rate'
);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance, counts_toward_fi)
values ('a6000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 10000, true);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance, counts_toward_fi)
values ('a6000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'A House', 'EUR', 300000, false);
insert into categories (id, owner_id, kind, name)
values
  ('c6000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Groceries'),
  ('c6000000-0000-0000-0000-000000000002', auth.uid(), 'income', 'Salary');

-- 2. A budget's period_month is normalized to the first of its month.
insert into budgets (id, owner_id, category_id, period_month, amount, currency)
values (
  'b6000000-0000-0000-0000-000000000001', auth.uid(), 'c6000000-0000-0000-0000-000000000001',
  current_date, 300, 'EUR'
);

select is(
  (select period_month from budgets where id = 'b6000000-0000-0000-0000-000000000001'),
  date_trunc('month', current_date)::date,
  'period_month is normalized to the first of the month regardless of the date supplied'
);

-- 3. A second category budget for the same category+month is refused.
select throws_ok(
  $$
    insert into budgets (owner_id, category_id, period_month, amount, currency)
    values ('11111111-1111-1111-1111-111111111111', 'c6000000-0000-0000-0000-000000000001', current_date, 999, 'EUR')
  $$,
  '23505', null,
  'a second budget for the same category and month is refused'
);

-- 4. An overall (category_id null) budget for the same month.
insert into budgets (id, owner_id, category_id, period_month, amount, currency)
values ('b6000000-0000-0000-0000-000000000002', auth.uid(), null, current_date, 1000, 'EUR');

-- 5. A second overall budget for the same month is refused — NULL doesn't
-- silently dodge the uniqueness rule.
select throws_ok(
  $$
    insert into budgets (owner_id, category_id, period_month, amount, currency)
    values ('11111111-1111-1111-1111-111111111111', null, current_date, 999, 'EUR')
  $$,
  '23505', null,
  'a second overall budget for the same month is refused'
);

insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000001', -120, 'EUR', now());
insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000002', 4000, 'EUR', now() - interval '10 days');

-- 6-7. budget_progress reports both the category-specific and the overall
-- budget correctly, and excludes income entirely (the overall budget is a
-- spending cap, not a net figure).
select is(
  (select spent from budget_progress(current_date) where category_id = 'c6000000-0000-0000-0000-000000000001'),
  120.0000::numeric,
  'budget_progress reports actual spend for a category-specific budget'
);

select is(
  (select spent from budget_progress(current_date) where category_id is null),
  120.0000::numeric,
  'the overall budget''s spend is total expense activity, excluding income'
);

-- 8. A transfer never counts toward any budget's spend.
select create_transfer('a6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000002', 500);

select is(
  (select spent from budget_progress(current_date) where category_id is null),
  120.0000::numeric,
  'a transfer never counts toward budget_progress''s spend'
);

-- 9. A missing FX rate on a contributing transaction propagates to null,
-- distinguished from "no spend yet" (money rule 5).
insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000001', -30, 'GBP', now());

select is(
  (select spent from budget_progress(current_date) where category_id = 'c6000000-0000-0000-0000-000000000001'),
  null::numeric,
  'a category budget''s spend renders null when any contributing transaction can''t be converted'
);

select is(
  (select count(*) from budget_progress((current_date + interval '2 months')::date)),
  0::bigint,
  'a month with no budget rows at all returns no rows from budget_progress'
);

-- ----------------------------------------------------------------------------
-- 10-15. fi_metrics: math correctness, one visible/editable assumption
-- set, and counts_toward_fi filtering. target_annual_spend is fixed
-- explicitly throughout so the math is exact and doesn't depend on this
-- file's own trailing-12mo transaction fixtures.
-- ----------------------------------------------------------------------------

update fi_settings
set target_annual_spend = 40000, withdrawal_rate = 0.04, real_return_rate = 0.05
where owner_id = auth.uid();

-- current_net_worth must exclude the House account (counts_toward_fi =
-- false) — only the Checking account's 10000 + income - expense - transfer
-- activity above counts.
select is(
  (select current_net_worth from fi_metrics('total')),
  (10000 + 4000 - 120 - 30 - 500)::numeric,
  'fi_metrics'' current_net_worth excludes an account with counts_toward_fi = false'
);

select is(
  (select fi_number from fi_metrics('total')),
  1000000.0000::numeric,
  'fi_number = target_annual_spend / withdrawal_rate'
);

-- 12-13. Changing withdrawal_rate moves fi_number (and therefore years-to-
-- FI) immediately — the spec's own explicit requirement for a live
-- assumption set, never a cached/hidden constant.
update fi_settings set withdrawal_rate = 0.05 where owner_id = auth.uid();

select is(
  (select fi_number from fi_metrics('total')),
  800000.0000::numeric,
  'lowering withdrawal_rate to 0.05 immediately drops fi_number to 800000'
);

update fi_settings set withdrawal_rate = 0.04 where owner_id = auth.uid();

-- 14. percent_progress = current_net_worth / fi_number.
select is(
  (select percent_progress from fi_metrics('total')),
  ((10000 + 4000 - 120 - 30 - 500)::numeric / 1000000),
  'percent_progress is current_net_worth divided by fi_number'
);

-- 15. Net dissaving (target_annual_spend far exceeds real income) makes
-- years_to_fi null, never a negative or nonsensical number.
select is(
  (select years_to_fi from fi_metrics('total')),
  null::numeric,
  'years_to_fi is null when annual_savings is negative (spending faster than earning)'
);

-- 16. Already-FI (net worth at or above fi_number) reports years_to_fi = 0
-- and coast_fi_number = fi_number (power(1+r, 0) = 1).
update fi_settings set target_annual_spend = 1 where owner_id = auth.uid();

select is(
  (select years_to_fi from fi_metrics('total')),
  0::numeric,
  'years_to_fi is 0 once current_net_worth already meets fi_number'
);

select is(
  (select coast_fi_number = fi_number from fi_metrics('total')),
  true,
  'coast_fi_number equals fi_number exactly when years_to_fi is 0'
);

-- ----------------------------------------------------------------------------
-- 17-20. RLS: fixture B sees none of fixture A's budgets, and reads its
-- own independently-seeded fi_settings, not A's.
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

select isnt(
  (select target_annual_spend from fi_settings where owner_id = auth.uid()),
  1::numeric,
  'fixture B has its own independent fi_settings row, not fixture A''s edited one'
);

-- RLS filters the row out of UPDATE's own visible set rather than raising
-- (confirmed empirically in Phase 14's suite) — the update matches zero
-- rows, verified as postgres afterward that it's genuinely untouched.
update budgets set amount = 1 where id = 'b6000000-0000-0000-0000-000000000001';

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select amount from budgets where id = 'b6000000-0000-0000-0000-000000000001'),
  300.0000::numeric,
  'fixture B''s update matched zero rows — fixture A''s budget is untouched'
);

select * from finish();
rollback;
