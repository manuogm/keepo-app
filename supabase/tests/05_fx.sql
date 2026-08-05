-- fx_rate_on / fx_convert / upsert_fx_rate / account_balances_base.
-- Fixture A (base EUR) = 11111111-..., fixture B (base USD) = 22222222-...

\ir _helpers.psql

begin;
select plan(12);

-- upsert_fx_rate is service_role-only.
set local role authenticated;
select throws_ok(
  $$ select upsert_fx_rate('USD', current_date, 0.9) $$,
  null::char(5), null,
  'authenticated cannot execute upsert_fx_rate'
);

reset role;

-- Cleared first, deliberately, as postgres — fx_rates has no DELETE grant
-- to any role, service_role included (writes go only through
-- upsert_fx_rate), so this maintenance cleanup can't run as service_role
-- either. This test file shares the persistent local database with
-- supabase/seed.sql (which seeds its own USD rates for the last several
-- days), and the "carries forward over a gap" assertion below needs a
-- genuine, deterministic gap regardless of whatever seed/manual data
-- happens to already be sitting in fx_rates — confirmed the hard way, the
-- first version of this test silently resolved to seed data's rate instead
-- of exercising the carry-forward path at all. Safe: this file's own
-- ROLLBACK undoes the delete along with everything else.
delete from fx_rates where currency = 'USD';

set local role service_role;

select upsert_fx_rate('USD', current_date - 10, 0.90, 'ecb', now());

-- fx_rate_on: EUR has a structural rate of 1 with zero rows.
select is(fx_rate_on('EUR', current_date), 1::numeric, 'EUR has an implicit rate of 1 with zero fx_rates rows');

-- fx_rate_on: carries forward over a gap (no rate exists for current_date,
-- only for current_date - 10; must resolve to the most recent at-or-before).
select is(
  fx_rate_on('USD', current_date),
  0.90::numeric,
  'fx_rate_on carries the last available rate forward over a weekend/holiday gap'
);

-- fx_rate_on: no rate at all for a date before any row exists.
select is(
  fx_rate_on('USD', current_date - 20),
  null::numeric,
  'fx_rate_on returns null, not 0 or an error, when no rate exists at or before the date'
);

-- fx_convert: round-trip within rounding, and null propagation.
select is(
  round(fx_convert(100, 'EUR', 'USD', current_date) , 4),
  round(100 / fx_rate_on('EUR', current_date) * fx_rate_on('USD', current_date), 4),
  'fx_convert matches amount / rate_from * rate_to exactly'
);

select is(
  fx_convert(100, 'EUR', 'USD', current_date - 20),
  null::numeric,
  'fx_convert returns null, never 0, when the target rate is missing'
);

-- upsert_fx_rate: "later fetched_at wins," both directions.
select upsert_fx_rate('USD', current_date, 0.91, 'ecb', now());
select is(
  (select rate_to_eur from fx_rates where currency = 'USD' and rate_date = current_date),
  0.9100,
  'a later fetched_at overwrites an earlier one for the same (currency, rate_date)'
);

-- An earlier fetched_at than what's stored is a no-op, not "last call wins."
select upsert_fx_rate('USD', current_date, 0.50, 'ecb', now() - interval '1 hour');
select is(
  (select rate_to_eur from fx_rates where currency = 'USD' and rate_date = current_date),
  0.9100,
  'an earlier fetched_at than what''s already stored is a silent no-op'
);

reset role;

-- account_balances_base: has_missing_rate distinguishes "rate missing" from
-- "balance missing" (an unsnapshotted valuation account), and correctly
-- converts for two viewers with different base currencies.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'USD Checking', 'USD', 200);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'valuation', 'investment', 'Brokerage', 'EUR', 0);

-- Compared against fx_convert directly, unrounded — money rule 2 rounds
-- only for display, never for storage or intermediate computation, and
-- account_balances_base's balance_base is exactly fx_convert's raw output
-- with no rounding applied anywhere in the view.
select is(
  (select balance_base from account_balances_base where account_id = 'a0000000-0000-0000-0000-000000000001'),
  fx_convert(200, 'USD', 'EUR', current_date),
  'account_balances_base converts a USD account into fixture A''s EUR base currency'
);

select is(
  (select has_missing_rate from account_balances_base where account_id = 'a0000000-0000-0000-0000-000000000002'),
  false,
  'has_missing_rate is false, not true, when the balance itself is null (unsnapshotted valuation)'
);

-- Not-yet-onboarded (null base_currency) flows through as null, never
-- filters the row out of the join — the exact case the Phase 4 log says
-- was tested for the profiles inner join, re-confirmed here.
reset role;
update profiles set base_currency = null, onboarded_at = null where id = '11111111-1111-1111-1111-111111111111';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select balance_base from account_balances_base where account_id = 'a0000000-0000-0000-0000-000000000001'),
  null::numeric,
  'a not-yet-onboarded null base_currency renders balance_base as null, not a missing row'
);

select ok(
  (select count(*) from account_balances_base where account_id = 'a0000000-0000-0000-0000-000000000001') = 1,
  'the account row itself still appears even though base_currency is null'
);

select * from finish();
rollback;
