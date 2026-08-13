-- account_balance_on / account_balances (H11 refactor) / net_worth_daily /
-- refresh_net_worth_daily / net_worth_series / fx_convert's same-currency
-- short-circuit (H15). Migration 20260806140000_home_net_worth.sql.
-- Fixture A = 11111111-... (base EUR).
--
-- Money is bigint at fixed scale 4 (L1) — 1000.00 is written as 10000000.

\ir _helpers.psql

begin;
select plan(17);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('e8000000-0000-0000-0000-00000000e001', auth.uid(), auth.uid(), 'ledger', 'checking', 'Ledger', 'EUR', 10000000);
insert into categories (id, owner_id, kind, name)
values ('c8000000-0000-0000-0000-00000000c001', auth.uid(), 'expense', 'Test Expense');

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'e8000000-0000-0000-0000-00000000e001', 'c8000000-0000-0000-0000-00000000c001', -1000000, 'EUR', now() - interval '5 days');
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'e8000000-0000-0000-0000-00000000e001', 'c8000000-0000-0000-0000-00000000c001', -500000, 'EUR', now());

-- ----------------------------------------------------------------------------
-- account_balance_on: the extracted function reproduces the historical
-- series correctly, and its today-value matches account_balances exactly.
-- ----------------------------------------------------------------------------

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e001', (current_date - 6)),
  10000000::bigint,
  'account_balance_on before any transaction is exactly opening_balance_e4'
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e001', (current_date - 5)),
  9000000::bigint,
  'account_balance_on includes a transaction dated exactly that day'
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e001', (current_date - 1)),
  9000000::bigint,
  'account_balance_on the day before today does not yet include today''s transaction'
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e001', current_date),
  8500000::bigint,
  'account_balance_on today includes today''s transaction'
);

-- H11: account_balances is a thin wrapper — byte-identical to calling the
-- function directly at current_date, not a second, divergent formula.
select is(
  (select balance_e4 from account_balances where account_id = 'e8000000-0000-0000-0000-00000000e001'),
  account_balance_on('e8000000-0000-0000-0000-00000000e001', current_date),
  'account_balances is byte-identical to account_balance_on(id, current_date)'
);

-- A future-dated transaction must never move today's balance — and asking
-- account_balance_on about a future date can't see beyond now() either,
-- for exactly the same reason (least(p_date + 1 day, now()) caps at now()
-- regardless of how far in the future p_date is).
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'e8000000-0000-0000-0000-00000000e001', 'c8000000-0000-0000-0000-00000000c001', -99990000, 'EUR', now() + interval '1 day');

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e001', current_date),
  8500000::bigint,
  'a future-dated transaction never moves today''s account_balance_on'
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e001', (current_date + 1)),
  8500000::bigint,
  'account_balance_on for tomorrow still can''t see beyond right now'
);

-- ----------------------------------------------------------------------------
-- net_worth_daily / refresh_net_worth_daily
-- ----------------------------------------------------------------------------

select refresh_net_worth_daily(auth.uid(), (current_date - 5), current_date);

select is(
  (select balance_e4 from net_worth_daily
    where account_id = 'e8000000-0000-0000-0000-00000000e001' and as_of = current_date),
  8500000::bigint,
  'refresh_net_worth_daily materializes today''s balance correctly'
);

select is(
  (select count(*) from net_worth_daily where account_id = 'e8000000-0000-0000-0000-00000000e001'),
  6::bigint,
  'refresh_net_worth_daily populates exactly one row per day in the requested range'
);

-- ----------------------------------------------------------------------------
-- net_worth_series: scopes. Sharing the only account moves it out of 'me'
-- and into 'household' — 'total' always includes it either way.
-- ----------------------------------------------------------------------------

select create_household();
select share_account('e8000000-0000-0000-0000-00000000e001');

select is(
  (select count(*) from net_worth_series('me', current_date, current_date)),
  0::bigint,
  'net_worth_series(''me'') has no rows once the only account is shared'
);

select is(
  (select total_e4 from net_worth_series('household', current_date, current_date)),
  8500000::bigint,
  'net_worth_series(''household'') totals the shared account correctly'
);

select is(
  (select total_e4 from net_worth_series('total', current_date, current_date)),
  8500000::bigint,
  'net_worth_series(''total'') includes the account regardless of scope partition'
);

-- ----------------------------------------------------------------------------
-- H15: fx_convert's same-currency short-circuit — works with ZERO fx_rates
-- rows, unlike resolving the same non-EUR currency's rate twice would.
-- ----------------------------------------------------------------------------

-- Cleared first, as postgres — fx_rates has no DELETE grant to authenticated
-- (same precedent as 05_fx.sql), and supabase/seed.sql pre-populates 6 days
-- of USD rates for Studio exploration, which would otherwise mask both the
-- short-circuit test below and the missing-rate test that follows it.
reset role;
delete from fx_rates where currency = 'USD';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from fx_rates where currency = 'USD'),
  0::bigint,
  'sanity check: no USD fx_rates rows exist yet for the short-circuit test'
);

select is(
  fx_convert(1000000, 'USD', 'USD', current_date),
  1000000::bigint,
  'fx_convert short-circuits same-currency conversion with zero fx_rates rows'
);

-- A private USD account with no resolvable rate renders the day as NULL in
-- net_worth_series('me'), never a silently-partial sum (money rule 5).
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('e8000000-0000-0000-0000-00000000e002', auth.uid(), auth.uid(), 'ledger', 'checking', 'USD Ledger', 'USD', 5000000);

select refresh_net_worth_daily(auth.uid(), current_date, current_date);

select is(
  (select total_e4 from net_worth_series('me', current_date, current_date)),
  null::bigint,
  'a day with an unconvertible account renders NULL in net_worth_series(''me''), not a partial sum'
);

-- A rate gap carries forward across the whole series — seeding one USD
-- rate 10 days back must resolve every day in an 8-day range that follows.
reset role;
select upsert_fx_rate('USD', (current_date - 10), 0.9, 'ecb', now());
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select refresh_net_worth_daily(auth.uid(), (current_date - 8), (current_date - 1));

select is(
  (select count(*) from net_worth_series('me', (current_date - 8), (current_date - 1))),
  8::bigint,
  'net_worth_series returns every day in range once the account has data'
);

select is(
  (select count(*) from net_worth_series('me', (current_date - 8), (current_date - 1)) where total_e4 is null),
  0::bigint,
  'a fx_rates gap carries forward across the whole series — no day renders NULL'
);

select * from finish();
rollback;
